#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


set -Eeuo pipefail

require_stage 20-desktop

if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
	echo "nvidia modeset: $(cat /sys/module/nvidia_drm/parameters/modeset)"
else
	echo "nvidia_drm not loaded"
fi



#    Mullvad


sudo pacman -S --needed --noconfirm mullvad-vpn


sudo systemctl enable --now mullvad-daemon

wait_for 20 sudo mullvad status



if ! sudo mullvad account get &>/dev/null; then
	until sudo mullvad account get &>/dev/null; do
		read -rsp "Mullvad account number: " ACCT
		echo
		sudo mullvad account login "$ACCT" || echo "Rejected, try again"
		unset ACCT
	done
fi

sudo mullvad connect

wait_for 20 sh -c 'sudo mullvad status | grep -q Connected'


sudo mullvad lan set allow




#   UFW


sudo pacman -S --needed --noconfirm ufw
	
sudo systemctl enable ufw

sudo ufw default deny incoming

sudo ufw default allow outgoing

sudo ufw --force enable



# Verify

echo "verify:"

check "ufw active"            sh -c 'sudo ufw status | grep -q "Status: active"'

check "mullvad daemon"    systemctl is-active --quiet mullvad-daemon

check "mullvad responds"  sudo mullvad status

verify_done

stage_done 30-security



# End

echo "Run virt.sh"
