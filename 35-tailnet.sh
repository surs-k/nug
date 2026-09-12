#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

####### tailscale is the most fragile piece in the whole pipeline
####### it has to leave outside the Mullvad tunnel, which means a cgroup
####### exclusion, a daemon restart and a browser login all lining up, and
####### when any of that misses you lose DNS and it looks like the internet died
####### so it is its own stage, off unless you ask for it, and nothing else
####### depends on it
####### the PC is fully usable without it, you only need it for the laptop

sudo_keepalive

require_stage 30-security

if [[ "${WANT_TAILSCALE:-no}" != yes ]]; then
	note "tailnet remote access is off"
	note "turn it on later with:  rebuild --only 35-tailnet"
	stage_done
	exit 0
fi

resolves_now() { getent ahostsv4 archlinux.org &> /dev/null; }

if ! resolves_now; then
	printf '\n  No working DNS, so Tailscale cannot reach its control server.\n' >&2
	printf '  Fix the network first, then:  rebuild --only 35-tailnet\n\n' >&2
	exit 1
fi



#    Tailnet


section "Tailnet"


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

	$SUDO tailscale up --accept-dns=false --timeout=300s > "$TS_OUT" 2>&1 &
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

if ip link show tailscale0 &> /dev/null; then
	soft "allow ssh on tailnet" $SUDO ufw allow in on tailscale0 to any port 22 proto tcp
else
	flag "tailscale0 absent, ssh rule not added"
fi



#    Verify


section "Verify"

check "tailscaled active"  systemctl is-active --quiet tailscaled
check "tailnet up"         tailnet_up

warn  "tailscale excluded" sh -c 'systemctl show tailscaled -p ExecStart > /tmp/_ts; grep -q mullvad-exclude /tmp/_ts'
warn  "dns still working"  resolves_now

verify_done

stage_done



#    End


section "End"

printf '  Tailnet up.\n'
printf '  Your services can now be reached from the laptop and phone.\n\n'
