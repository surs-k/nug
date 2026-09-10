#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


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

####### lockdown mode is deliberately left until 50-bkp-net
####### turning it on here would cut Tailscale off before the exclusion that
####### lets it through has been set up, and remote access would never connect


## Blocking

####### every content blocker, this is the biggest privacy win for daily use
####### each one is soft on its own, so a flag that gets renamed upstream
####### shows up in the failure list instead of ending the stage
soft "block ads"          $SUDO mullvad dns set default --block-ads
soft "block trackers"     $SUDO mullvad dns set default --block-ads --block-trackers
soft "block malware"      $SUDO mullvad dns set default --block-ads --block-trackers --block-malware
soft "block adult"        $SUDO mullvad dns set default --block-ads --block-trackers --block-malware --block-adult-content
soft "block gambling"     $SUDO mullvad dns set default --block-ads --block-trackers --block-malware --block-adult-content --block-gambling
soft "block social media" $SUDO mullvad dns set default --block-ads --block-trackers --block-malware --block-adult-content --block-gambling --block-social-media


## Tunnel

####### multihop sends the traffic in one country and out another
####### the CLI wording for these has moved between releases, so each is soft
soft "multihop on"    $SUDO mullvad relay set tunnel wireguard --use-multihop on

soft "in tunnel ipv6" $SUDO mullvad tunnel set ipv6 on


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


## Appearance

####### the animated map is a GUI setting held in the app's own settings file,
####### there is no CLI for it, so it is edited directly if the file is there
GUI_CONF="$HOME/.config/Mullvad VPN/gui_settings.json"

if [[ -f "$GUI_CONF" ]]; then
	if grep -q 'animateMap' "$GUI_CONF"; then
		sed -i 's/"animateMap"[[:space:]]*:[[:space:]]*true/"animateMap": false/' "$GUI_CONF"
	else
		sed -i 's/^{/{\n  "animateMap": false,/' "$GUI_CONF"
	fi
	note "map animation turned off"
else
	flag "Mullvad GUI settings not created yet, turn off animate map in the app once"
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

verify_done

stage_done



#    End


section "End"

printf '  VPN and firewall up.\n'
printf '  Check yourself any time at https://mullvad.net/check\n\n'
