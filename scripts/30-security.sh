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
		# Ai - run.sh asks up front and passes it in memory, used once here
	if [[ -n "${MULLVAD_ACCT:-}" ]]; then
		$SUDO mullvad account login "$MULLVAD_ACCT" >&3 2>&1 \
			|| printf '  the number from the start was rejected, asking again\n' >&2
	fi
	unset MULLVAD_ACCT

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

	# Ai - local network sharing has to be on or the vm bridge, docker bridge
	#      and tailscale all get cut off by the kill switch
run "allow local network" $SUDO mullvad lan set allow

run "auto connect on"     $SUDO mullvad auto-connect set on

	# Ai - lockdown mode is never turned on by the install
	#      you turn it on in the Mullvad app once your settings are done


## Blocking

	# Ai - every content blocker, this is the biggest privacy win for daily use
	#      each one is soft on its own, so a flag that gets renamed upstream
	#      shows up in the failure list instead of ending the stage
	#      one call, not one per blocker
	#      each dns set replaces the whole config, so chaining them was six
	#      rewrites of the resolver settings for no benefit
if $SUDO mullvad dns set default \
	--block-ads --block-trackers --block-malware \
	--block-adult-content --block-gambling --block-social-media >&3 2>&1; then
	pass "all dns content blockers"
else
	flag "some blocker flags were rejected, falling back to the core three"
	soft "core dns blockers" $SUDO mullvad dns set default \
		--block-ads --block-trackers --block-malware
fi


## Multihop

	# Ai - not set here, the switch and the entry location are both yours to
	#      set in the Mullvad app, once, and the app keeps them from then on
	#      earlier versions set the entry and tried the switch, and every check
	#      on it failed on a fresh install before the app had been opened


## Ipv6

	# Ai - in tunnel IPv6 with no IPv6 route is what killed DNS
	#      the resolver tries v6 first and sits there until it times out, which
	#      is the 10 second per mirror stall that looked like the internet dying
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

	# Ai - auto-connect is the daemon, this is the app window itself
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

	# Ai - everything after this point downloads something
	#      a tunnel that is up but cannot resolve names looks exactly like a dead
	#      internet three stages later, so it gets caught here instead

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



#    Firewall


section "Firewall"

	# Ai - mullvad already drops everything that is not in the tunnel, so ufw
	#      is here for inbound only, outbound filtering would be duplicate work

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

verify_done

stage_done



#    End


section "End"

printf '  VPN and firewall up.\n'
printf '  Check yourself any time at https://mullvad.net/check\n\n'
printf '  Multihop is yours to set in the Mullvad app, once.\n\n'
