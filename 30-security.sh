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

####### multihop sends traffic in through one country and out another
####### the CLI wording has moved between releases, so the known spellings are
####### tried in turn rather than assuming one of them is current
multihop() {
	local ok=no

	$SUDO mullvad relay set tunnel wireguard --use-multihop on >&3 2>&1 && ok=yes
	[[ "$ok" == yes ]] || $SUDO mullvad relay set tunnel wireguard --use-multihop=on >&3 2>&1 && ok=yes
	[[ "$ok" == yes ]] || $SUDO mullvad relay set tunnel wireguard --use-multihop true >&3 2>&1 && ok=yes

	if [[ "$ok" == yes ]]; then
		printf '  [ok]   multihop on\n'
	else
		flag "multihop needs turning on by hand in the app, WireGuard settings"
	fi
}

multihop

ipv6() {
	local ok=no

	$SUDO mullvad tunnel set ipv6 on >&3 2>&1 && ok=yes
	[[ "$ok" == yes ]] || $SUDO mullvad tunnel ipv6 set on >&3 2>&1 && ok=yes

	if [[ "$ok" == yes ]]; then
		printf '  [ok]   in tunnel ipv6\n'
	else
		flag "in tunnel IPv6 needs turning on by hand in the app"
	fi
}

ipv6


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
GUI_DIR="$HOME/.config/Mullvad VPN"
GUI_CONF="$GUI_DIR/gui_settings.json"

####### the file does not exist until the app window has been opened once
####### writing it first means the app picks the setting up on its first run
####### instead of this being something you have to remember to do
mkdir -p "$GUI_DIR"

if [[ -f "$GUI_CONF" ]]; then
	if grep -q 'animateMap' "$GUI_CONF"; then
		sed -i 's/"animateMap"[[:space:]]*:[[:space:]]*true/"animateMap": false/' "$GUI_CONF"
	else
		sed -i 's/^{/{\n  "animateMap": false,/' "$GUI_CONF"
	fi
	note "map animation turned off"
else
	cat > "$GUI_CONF" << 'JSONEOF'
{
  "animateMap": false,
  "monochromaticIcon": false,
  "startMinimized": false,
  "unpinnedWindow": true
}
JSONEOF
	note "map animation pre-set before the app first opens"
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
	printf '\n  A browser link prints below. Open it and approve this machine.\n\n'
	$SUDO tailscale up --accept-dns=false --timeout=300s
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

verify_done

stage_done



#    End


section "End"

printf '  VPN and firewall up.\n'
printf '  Check yourself any time at https://mullvad.net/check\n\n'
