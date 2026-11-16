#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop

if [[ "${WANT_WATCH:-yes}" != yes ]]; then
	note "connection watcher is off"
	note "turn it on later: set WANT_WATCH=yes in $CONFIG, then rebuild --only 85-connections"
	stage_done
	exit 0
fi



#    Watcher


section "Watcher"

	# Ai - OpenSnitch sits between every program and the network
	#      its window lists each connection by program, and the first time a
	#      program reaches out it asks, so you learn what your own PC does
	#      it is in the official Arch repo, and the source is on GitHub under
	#      evilsocket/opensnitch
pac opensnitch


## Answer

	# Ai - what happens when nobody answers the question in time, or the
	#      window is not open at all
	#      allow, on purpose: this starts as something to watch and learn
	#      from, and a watcher that blocks by default breaks updates, the VPN
	#      and games the first evening
	#      once the rules look right, change it in the OpenSnitch window:
	#      Preferences, Pop-ups, Default action, deny
OSCONF=/etc/opensnitchd/default-config.json

if $SUDO test -f "$OSCONF"; then
	if $SUDO grep -q '"DefaultAction": *"allow"' "$OSCONF"; then
		note "unanswered connections are allowed, the learning setting"
	else
		$SUDO cp -n "$OSCONF" "$OSCONF.rebuild-bak"
		$SUDO sed -i 's/"DefaultAction": *"[a-z]*"/"DefaultAction": "allow"/' "$OSCONF"
		note "unanswered connections set to allow, the learning setting"
	fi
else
	flag "OpenSnitch settings file not found, its own defaults apply"
fi


## Service

run "start the watcher" $SUDO systemctl enable --now opensnitchd


## Window

	# Ai - the window has to be running for the questions to appear, so it
	#      starts with the desktop and sits in the tray
mkdir -p "$HOME/.config/autostart"

if [[ -f /usr/share/applications/opensnitch_ui.desktop ]]; then
	cp /usr/share/applications/opensnitch_ui.desktop "$HOME/.config/autostart/opensnitch_ui.desktop"
	note "the OpenSnitch window starts with the desktop"
else
	flag "OpenSnitch launcher entry not found, start it by hand from the app launcher"
fi



#    Firewall


section "Firewall"

	# Ai - Gufw is a window onto the firewall 30-security already set up
	#      it shows whether it is on, what comes in, what goes out, and every
	#      rule, and it changes the same rules ufw does, not a second set
pac gufw



#    Verify


section "Verify"

check "opensnitch installed"   pacman -Qq opensnitch
check "watcher running"        systemctl is-active --quiet opensnitchd
check "watcher starts at boot" systemctl is-enabled --quiet opensnitchd
check "firewall window"        pacman -Qq gufw

warn  "watcher window at login" test -f "$HOME/.config/autostart/opensnitch_ui.desktop"

	# Ai - the watcher must not have cut the network it watches
warn  "network still works"    online

verify_done

stage_done



#    End


section "End"

printf '  Open OpenSnitch from the app launcher to see what connects where.\n'
printf '  Open Firewall Configuration (Gufw) to see what the firewall lets in.\n\n'
