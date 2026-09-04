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


section_done "Check"



#    Mullvad


## Install

sudo pacman -S --needed --noconfirm mullvad-vpn


sudo systemctl enable --now mullvad-daemon

wait_for 60 sudo mullvad status


## Login


logged_in() {
	local state
	state="$(sudo mullvad account get 2>&1)" || true
	[[ "$state" != *"Not logged in"* ]]
}

attempt=1

until logged_in; do
	if (( attempt > RETRY_LIMIT )); then
		echo "Login failed $RETRY_LIMIT times" >&2
		exit 1
	fi
	printf 'Mullvad account number: ' > /dev/tty
	read -rs ACCT < /dev/tty
	echo > /dev/tty
	sudo mullvad account login "$ACCT" || echo "Rejected, try again" > /dev/tty
	unset ACCT
	attempt=$(( attempt + 1 ))
done


## Connect

echo "Connecting"

sudo mullvad connect

wait_for 120 sh -c 'sudo mullvad status | grep -q Connected'

echo "Connected"

## Settings

sudo mullvad lan set allow


section_done "Mullvad"



#    UFW


## Install

sudo pacman -S --needed --noconfirm ufw

sudo systemctl enable ufw


## Rules

sudo ufw default deny incoming

sudo ufw default allow outgoing


## Enable

sudo ufw --force enable


section_done "UFW"



#    Verify


echo "verify:"

check "ufw active"            sh -c 'sudo ufw status | grep -q "Status: active"'

check "mullvad daemon"    systemctl is-active --quiet mullvad-daemon

check "mullvad logged in"  logged_in

check "mullvad responds"  sudo mullvad status

verify_done

stage_done 30-security


section_done "Verify"



#    End


echo "Run virt.sh"


section_done "End"
