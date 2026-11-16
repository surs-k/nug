#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop



#    Command


section "Command"

	# Ai - one command for every desktop on this PC, see desktop.sh
$SUDO install -Dm755 "$SCRIPTS/desktop.sh" /usr/local/bin/desktop

	# Ai - and one entry in the app launcher, so it is found by looking, not
	#      by remembering a command
$SUDO tee /usr/share/applications/rebuild-desktops.desktop > /dev/null << 'APPEOF'
[Desktop Entry]
Type=Application
Name=Desktops
GenericName=Add, remove or switch desktops
Comment=Shows every desktop on this PC and how to add or remove one
Exec=sh -c 'desktop; printf "\n  Type a command above, or exit to close.\n\n"; exec "${SHELL:-bash}"'
Icon=preferences-desktop-display
Terminal=true
Categories=Settings;System;
Keywords=desktop;session;plasma;gnome;hyde;switch;
APPEOF

note "the desktop command and the Desktops launcher entry are in"



#    Extras


section "Extras"

WANT="${WANT_DESKTOPS:-none}"

if [[ "$WANT" == none || -z "$WANT" ]]; then
	note "no extra desktops chosen, add one any time with: desktop add NAME"
else
	IFS=',' read -ra PICKS <<< "$WANT"
	for d in "${PICKS[@]}"; do
		[[ -n "$d" ]] || continue
			# Ai - one desktop failing to install must not take the rest with it
		soft "add $d" /usr/local/bin/desktop add "$d"
	done
fi



#    Verify


section "Verify"

check "desktop command"   test -x /usr/local/bin/desktop
check "launcher entry"    test -f /usr/share/applications/rebuild-desktops.desktop
check "catalog readable"  sh -c '/usr/local/bin/desktop catalog | grep -q plasma'

warn  "sddm still the login screen" systemctl is-enabled sddm

if [[ "$WANT" != none && -n "$WANT" ]]; then
	IFS=',' read -ra PICKS <<< "$WANT"
	for d in "${PICKS[@]}"; do
		[[ -n "$d" && "$d" != dream ]] || continue
		warn "$d recorded" test -f "/var/lib/rebuild/desktops/$d.pkgs"
	done
fi

verify_done

stage_done



#    End


section "End"

printf '  Desktops: type desktop, or open Desktops in the app launcher.\n\n'
