#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

	# Ai - this is the way to your PC, without it the laptop is a laptop
	#      it needs a login on another device, so it is its own stage, and a
	#      failure here never stops the stages that do not need the tailnet

sudo_keepalive

require_stage 30-security

resolves_now() { getent ahostsv4 archlinux.org &> /dev/null; }

if ! resolves_now; then
	printf '\n  No working DNS, so Tailscale cannot reach its control server.\n' >&2
	printf '  Fix the network first, then:  rebuild --only 35-tailnet\n\n' >&2
	exit 1
fi



#    Tailnet


section "Tailnet"


## Install

pac tailscale


## Daemon

run "enable tailscaled"  $SUDO systemctl enable tailscaled.service
run "restart tailscaled" $SUDO systemctl restart tailscaled.service

wait_for 30 test -S /run/tailscale/tailscaled.sock


## Up

tailnet_up() {
	local s
	s="$(capture tailscale status)"
	! contains "$s" "Logged out" && ! contains "$s" "Tailscale is stopped" \
		&& [[ -n "${s//[[:space:]]/}" ]]
}

	# Ai - accept-dns stays off, tailscale then never touches this laptop's DNS
	#      the PC is found by name through tailscale itself, see the pc command
if tailnet_up; then
	note "already logged in"
	soft "keep dns local" $SUDO tailscale set --accept-dns=false

else
		# Ai - tailscale up blocks silently while it reaches the control server
		#      this runs it in the background, watches for the link, and shows
		#      the link and a QR code the moment they exist, plus a count while
		#      it waits
		#      the laptop has no browser, so the approval is done from a phone
		#      by scanning the code, or by typing the link in anywhere
		#      the QR code is block characters, the console font has them

	TS_OUT="$(mktemp)"

	$SUDO tailscale up --qr --accept-dns=false --timeout=300s > "$TS_OUT" 2>&1 &
	TS_PID=$!

	TS_URL=""
	TS_START=$SECONDS

	while kill -0 "$TS_PID" 2>/dev/null; do

		if [[ -z "$TS_URL" ]]; then
			TS_URL="$(grep -m1 -o 'https://login\.tailscale\.com[^[:space:]]*' "$TS_OUT" 2>/dev/null || true)"

			if [[ -n "$TS_URL" ]]; then
				sleep 1
				printf '\r                                                  \r'
				action "Scan the code with your phone, or open the link anywhere,
and approve this laptop:

  $TS_URL

Nothing else runs until you do."
				cat "$TS_OUT" > /dev/tty
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
		else
			flag "the link was not approved in time, run rebuild again to get a new one"
		fi
	fi
fi


	# Ai - so tailscale status and tailscale ip work without sudo, the pc
	#      command asks them every time it runs
soft "tailscale without sudo" $SUDO tailscale set --operator="$USERNAME"



#    Verify


section "Verify"

check "tailscaled active"  systemctl is-active --quiet tailscaled
check "tailnet up"         tailnet_up

verify_done

stage_done



#    End


section "End"

printf '  Tailnet up. Your PC shows in:  tailscale status\n\n'
