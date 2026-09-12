#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Mullvad


section "Mullvad"


## Install

pac mullvad-vpn

run "enable daemon" $SUDO systemctl enable --now mullvad-daemon

wait_for 60 $SUDO mullvad status


## Login

logged_in() {
	local state
	state="$(capture $SUDO mullvad account get)"
	! contains "$state" "Not logged in"
}

if logged_in; then
	note "already logged in"
else
	attempt=1
	until logged_in; do
		if (( attempt > RETRY_LIMIT )); then
			printf 'Login failed %s times\n' "$RETRY_LIMIT" >&2
			exit 1
		fi
		action "Mullvad needs your account number."
		ACCT="$(secret 'Mullvad account number')"
		$SUDO mullvad account login "$ACCT" || printf '  rejected, try again\n' >&2
		unset ACCT
		attempt=$(( attempt + 1 ))
	done
fi


## Settings

####### local network sharing has to be on or the vm bridge, docker bridge
####### and tailscale all get cut off by the kill switch
run "allow local network" $SUDO mullvad lan set allow

run "auto connect on"     $SUDO mullvad auto-connect set on

####### lockdown mode is deliberately left until 50-bkp-net
####### turning it on here would cut Tailscale off before the exclusion that
####### lets it through has been set up, and remote access would never connect


## Blocking

####### every content blocker, this is the biggest privacy win for daily use
####### each one is soft on its own, so a flag that gets renamed upstream
####### shows up in the failure list instead of ending the stage
####### one call, not one per blocker
####### each dns set replaces the whole config, so chaining them was six
####### rewrites of the resolver settings for no benefit
if $SUDO mullvad dns set default \
	--block-ads --block-trackers --block-malware \
	--block-adult-content --block-gambling --block-social-media >&3 2>&1; then
	pass "all dns content blockers"
else
	flag "some blocker flags were rejected, falling back to the core three"
	soft "core dns blockers" $SUDO mullvad dns set default \
		--block-ads --block-trackers --block-malware
fi


## Tunnel

####### multihop is not a toggle, it is the entry location
####### setting one turns it on, setting none turns it off
####### the previous version never named a country, so it could not have
####### worked under any spelling
####### mullvad.net/en/help/cli-command-wg

ENTRY="${MULLVAD_ENTRY:-none}"

####### the daemon downloads the relay list after it starts, and a location
####### set before that arrives is rejected as invalid
####### that is why this failed on a first run and worked on the retry
relays_ready() {
	local list
	list="$(capture $SUDO mullvad relay list)"
	[[ ${#list} -gt 200 ]]
}

if [[ "$ENTRY" == none ]]; then
	note "multihop off, no entry location chosen"
else
	wait_for 60 relays_ready || flag "relay list never arrived, multihop may be rejected"

	####### deliberately unquoted, the location is one to three words
	####### country, or country and city, or country city and server
	if $SUDO mullvad relay set entry location $ENTRY >&3 2>&1; then
		pass "multihop entering via $ENTRY"
	else
		flag "multihop entry '$ENTRY' rejected, see valid codes: mullvad relay list"
	fi
fi


## Ipv6

####### in tunnel IPv6 with no IPv6 route is what killed DNS
####### the resolver tries v6 first and sits there until it times out, which
####### is the 10 second per mirror stall that looked like the internet dying
have_ipv6() {
	local addr route
	addr="$(capture ip -6 addr show scope global)"
	route="$(capture ip -6 route show default)"
	[[ -n "${addr//[[:space:]]/}" && -n "${route//[[:space:]]/}" ]]
}

if have_ipv6; then
	soft "in tunnel ipv6" $SUDO mullvad tunnel set ipv6 on
else
	note "no IPv6 route on this machine, leaving in tunnel IPv6 off"
	note "turning it on without one makes every DNS lookup time out"
	soft "ensure ipv6 off" $SUDO mullvad tunnel set ipv6 off
fi


## Autostart

####### auto-connect is the daemon, this is the app window itself
GUI=""
for d in mullvad-vpn.desktop mullvad-gui.desktop; do
	[[ -f "/usr/share/applications/$d" ]] && { GUI="$d"; break; }
done

if [[ -n "$GUI" ]]; then
	mkdir -p "$HOME/.config/autostart"
	cp "/usr/share/applications/$GUI" "$HOME/.config/autostart/$GUI"
	note "app will launch at login"
else
	flag "no Mullvad desktop file found, set launch on startup in the app"
fi


## Connect

connected() {
	local s
	s="$(capture $SUDO mullvad status)"
	contains "$s" "Connected"
}

if connected; then
	note "already connected"
else
	run "connect" $SUDO mullvad connect
	wait_for 120 connected || flag "did not report Connected within 120s"
fi


## Dns

####### everything after this point downloads something
####### a tunnel that is up but cannot resolve names looks exactly like a dead
####### internet three stages later, so it gets caught here instead

if wait_for 45 resolves; then
	note "DNS working through the tunnel"
else
	flag "DNS stopped working after connecting, backing IPv6 out"

	soft "disable in tunnel ipv6" $SUDO mullvad tunnel set ipv6 off
	soft "reconnect"              $SUDO mullvad reconnect

	if wait_for 60 resolves; then
		note "DNS recovered"
	else
		printf '\n  DNS is not working through the VPN.\n' >&2
		printf '  Nothing after this can download anything.\n\n' >&2
		printf '  Check:  mullvad status\n' >&2
		printf '          resolvectl status\n' >&2
		printf '          mullvad dns get\n\n' >&2
		exit 1
	fi
fi



#    Tailscale


section "Tailscale"


## Install

pac tailscale inotify-tools


## Exclude

####### tailscale traffic has to leave outside the mullvad tunnel or the
####### kill switch drops it, mullvad-exclude puts the daemon in a cgroup
####### that is marked to bypass the tunnel

TS_UNIT=/usr/lib/systemd/system/tailscaled.service
TS_DROP=/etc/systemd/system/tailscaled.service.d/mullvad-exclude.conf

if command -v mullvad-exclude > /dev/null; then

	TS_EXEC="$(sed -n 's/^ExecStart=//p' "$TS_UNIT" | sed -n 1p)"
	[[ -n "$TS_EXEC" ]] || { printf 'No ExecStart in %s\n' "$TS_UNIT" >&2; exit 1; }

	$SUDO mkdir -p "$(dirname "$TS_DROP")"

	$SUDO tee "$TS_DROP" > /dev/null << EOF
[Unit]
After=mullvad-daemon.service
Wants=mullvad-daemon.service

[Service]
ExecStart=
ExecStart=$(command -v mullvad-exclude) ${TS_EXEC}
EOF

	run "reload systemd" $SUDO systemctl daemon-reload
else
	flag "mullvad-exclude absent, tailscaled will run inside the tunnel"
fi


## Daemon

run "enable tailscaled"  $SUDO systemctl enable tailscaled.service
run "restart tailscaled" $SUDO systemctl restart tailscaled.service

wait_for 30 test -S /run/tailscale/tailscaled.sock


## Up

tailnet_up() {
	local s
	s="$(capture tailscale status)"
	! contains "$s" "Logged out" && ! contains "$s" "Tailscale is stopped"
}

####### accept-dns stays off, magicdns fights systemd-resolved and mullvad
if tailnet_up; then
	note "already logged in"
	soft "keep dns local" $SUDO tailscale set --accept-dns=false

else
	####### tailscale up blocks silently while it reaches the control server,
	####### and if it cannot get there you stare at a cursor until it times
	####### out with nothing on screen to explain why
	####### this runs it in the background, watches for the link, and shows
	####### the link the moment it exists plus a count while it waits

	TS_OUT="$(mktemp)"

	$SUDO tailscale up --accept-dns=false --timeout=180s > "$TS_OUT" 2>&1 &
	TS_PID=$!

	TS_URL=""
	TS_START=$SECONDS

	while kill -0 "$TS_PID" 2>/dev/null; do

		if [[ -z "$TS_URL" ]]; then
			TS_URL="$(grep -m1 -o 'https://login\.tailscale\.com[^[:space:]]*' "$TS_OUT" 2>/dev/null || true)"

			if [[ -n "$TS_URL" ]]; then
				printf '\r                                                  \r'
				action "Open this link and approve this machine:

  $TS_URL

Nothing else runs until you do."
			fi
		fi

		if [[ -n "$TS_URL" ]]; then
			printf '\r  waiting for you to approve it   %ss ' "$(( SECONDS - TS_START ))"
		else
			printf '\r  reaching the Tailscale control server   %ss ' "$(( SECONDS - TS_START ))"
		fi

		sleep 1
	done

	TS_RC=0
	wait "$TS_PID" || TS_RC=$?

	printf '\r                                                            \r'

	cat "$TS_OUT" >&3
	rm -f "$TS_OUT"

	if (( TS_RC != 0 )); then
		if [[ -z "$TS_URL" ]]; then
			flag "Tailscale never reached its control server, so no link was printed"
			flag "the exclusion that lets it out past Mullvad is the thing to check"
			flag "test it with: mullvad-exclude curl -I https://login.tailscale.com"
		else
			flag "the link was not approved in time, run rebuild again to get a new one"
		fi
	fi
fi


## Firewall

if ip link show tailscale0 &> /dev/null; then
	soft "allow ssh on tailnet" $SUDO ufw allow in on tailscale0 to any port 22 proto tcp
else
	flag "tailscale0 absent, ssh rule not added"
fi



#    Firewall


section "Firewall"

####### mullvad already drops everything that is not in the tunnel, so ufw
####### is here for inbound only, outbound filtering would be duplicate work

pac ufw

run "deny incoming"   $SUDO ufw default deny incoming
run "allow outgoing"  $SUDO ufw default allow outgoing
run "enable ufw"      $SUDO ufw --force enable
run "enable at boot"  $SUDO systemctl enable ufw



#    Verify


section "Verify"

check "mullvad daemon"    systemctl is-active --quiet mullvad-daemon
check "mullvad logged in" logged_in
check "mullvad connected" connected
check "lan sharing on"    sh -c 'sudo mullvad lan get > /tmp/_lan; grep -qi allow /tmp/_lan'
check "ufw active"        sh -c 'sudo ufw status > /tmp/_ufw; grep -q "Status: active" /tmp/_ufw'

warn  "dns blocking"      sh -c 'sudo mullvad dns get > /tmp/_dns; grep -qi "block" /tmp/_dns'
warn  "auto connect"      sh -c 'sudo mullvad auto-connect get > /tmp/_ac; grep -qi on /tmp/_ac'
warn  "app autostart"     sh -c 'ls ~/.config/autostart/mullvad* >/dev/null 2>&1'
check "tailscaled active"  systemctl is-active --quiet tailscaled
check "tailnet up"         tailnet_up
warn  "tailscale excluded" sh -c 'systemctl show tailscaled -p ExecStart > /tmp/_ts; grep -q mullvad-exclude /tmp/_ts'

####### the via line is the only real proof multihop is active
if [[ "${MULLVAD_ENTRY:-none}" != none ]]; then
	warn "multihop active"   sh -c 'sudo mullvad status -v > /tmp/_mh; grep -q " via " /tmp/_mh'
fi

verify_done

stage_done



#    End


section "End"

printf '  VPN and firewall up.\n'
printf '  Check yourself any time at https://mullvad.net/check\n\n'
