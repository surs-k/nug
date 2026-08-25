#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# = =    Check     = = = = = = =


set -Eeuo pipefail

require_stage 20-desktop

if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
	echo "nvidia modeset: $(cat /sys/module/nvidia_drm/parameters/modeset)"
else
	echo "nvidia_drm not loaded"
fi



# = =    Mullvad     = = = = = = =


yay -S --needed --noconfirm mullvad-vpn

sudo systemctl enable --now mullvad-daemon

echo "If stuck mullvad not starting"

until sudo mullvad status &>/dev/null; do sleep 1; done

sudo mullvad lan set allow


# = =    UFW     = = = = = = = = =


sudo pacman -S --needed --noconfirm ufw

	
sudo systemctl enable ufw


sudo ufw default deny incoming


sudo ufw default allow outgoing


sudo ufw --force enable



# = =    End     = = = = = = = = = 

stage_done 30-security

echo "Run virt.sh"