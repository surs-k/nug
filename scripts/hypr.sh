#!/usr/bin/env bash

# Ai - hypr, writes the nug parts of your Hyprland config, always in this
#      order: keys and start-up, your app keys, your screens, then the look
#      the look goes last, if a future Hyprland rejects a setting in it, only
#      the look is lost, everything above it has already been read
#      used by `rebuild desktop` and `rebuild apps`

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

load_theme

HYPR="$HOME/.config/hypr"
NUG="$HOME/.config/nug"

	# Ai - Hyprland reads hyprland.lua over hyprland.conf when both exist, so
	#      whichever one is there is used, never a second beside it
	#      a new one starts from the example the installed Hyprland ships, so it
	#      always suits that version, and from our own small one if it has none
hypr_file() {
	local f
	if [[ -f "$HYPR/hyprland.lua" ]]; then
		printf '%s' "$HYPR/hyprland.lua"
	elif [[ -f "$HYPR/hyprland.conf" ]]; then
		printf '%s' "$HYPR/hyprland.conf"
	elif (( DRY == 1 )); then
		printf '%s' "$HYPR/hyprland.conf"
	else
		mkdir -p "$HYPR"
		for f in /usr/share/hypr/hyprland.lua /usr/share/hypr/hyprland.conf; do
			if [[ -f "$f" ]]; then
				cp "$f" "$HYPR/${f##*/}"
				printf '%s' "$HYPR/${f##*/}"
				return 0
			fi
		done
		cp "$CONF/hypr/base.conf" "$HYPR/hyprland.conf"
		printf '%s' "$HYPR/hyprland.conf"
	fi
}

write_hypr() {
	local file kind mark='#'
	file="$(hypr_file)"
	kind="${file##*.}"
	if [[ "$kind" == lua ]]; then mark='--'; fi
	fill "$CONF/hypr/core.$kind" | block "$file" core
	if [[ -f "$NUG/apps.$kind" ]]; then
		block "$file" apps < "$NUG/apps.$kind"
	else
		printf '%s Ai - no app keys yet, rebuild apps adds them\n' "$mark" | block "$file" apps
	fi
	fill "$CONF/hypr/monitors.$kind" | block "$file" monitors
	fill "$CONF/hypr/look.$kind" | block "$file" look
	HYPR_FILE="$file"
}

	# Ai - asked of a Hyprland that knows how to check a file without starting
verify_hypr() {
	has Hyprland || return 0
	Hyprland --help 2>&1 | grep -q -- '--verify-config' || return 0
	Hyprland --verify-config -c "$HYPR_FILE" >&3 2>&1
}

write_hypr
if (( DRY == 1 )); then
	ok "Hyprland config would be written"
elif verify_hypr; then
	ok "Hyprland config: keys, apps, screens and look"
else
	sed -i '/nug look start$/,/nug look end$/d' "$HYPR_FILE"
	if verify_hypr; then
		warn "this Hyprland did not accept the look, it was left out, the rest works"
	else
		warn "Hyprland reports a problem in $HYPR_FILE, see $LOG"
	fi
fi

	# Ai - the key list SUPER + / shows, the desktop's keys then your apps'
if (( DRY == 0 )); then
	mkdir -p "$NUG"
	{ cat "$CONF/hypr/keys.txt"; if [[ -f "$NUG/apps-keys.txt" ]]; then cat "$NUG/apps-keys.txt"; fi; } > "$NUG/keys.txt"
fi

	# Ai - reload a running desktop so a change shows at once
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then quiet hyprctl reload || true; fi
