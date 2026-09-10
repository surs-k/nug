#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop



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

run "reconnect on boot"   $SUDO mullvad lockdown-mode set off

####### dns level blocking, this is the biggest privacy win for daily use
soft "block ads and trackers" $SUDO mullvad dns set default \
	--block-ads --block-trackers --block-malware


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

verify_done

stage_done



#    End


section "End"

printf '  VPN and firewall up.\n'
printf '  Check yourself any time at https://mullvad.net/check\n\n'
