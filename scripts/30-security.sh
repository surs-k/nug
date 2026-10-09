#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Firewall


section "Firewall"

	# Ai - this laptop only ever calls out, to Tailscale and to your PC, so
	#      nothing is allowed in and nothing listens
	#      there is no VPN here, everything private happens on the PC, and the
	#      stream to it is already encrypted by Tailscale
	#      ssh is installed for the client and its server is never turned on

pac ufw

run "deny incoming"   $SUDO ufw default deny incoming
run "allow outgoing"  $SUDO ufw default allow outgoing
run "enable ufw"      $SUDO ufw --force enable
run "enable at boot"  $SUDO systemctl enable ufw

	# Ai - a server left running by an earlier try is turned off
if systemctl is-enabled --quiet sshd.service 2>/dev/null; then
	soft "turn the ssh server off" $SUDO systemctl disable --now sshd.service
fi



#    Verify


section "Verify"

ufw_active() {
	local s
	s="$(capture $SUDO ufw status)"
	contains "$s" "Status: active"
}

sshd_off() {
	! systemctl is-enabled --quiet sshd.service 2>/dev/null
}

check "ufw active"        ufw_active
check "ufw at boot"       systemctl is-enabled --quiet ufw
check "ssh server off"    sshd_off

verify_done

stage_done



#    End


section "End"

printf '  Firewall up. Nothing is allowed in.\n\n'
