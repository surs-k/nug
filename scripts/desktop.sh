#!/usr/bin/env bash

	# Ai - desktop: add, remove and list desktops on the login screen
	#      HyDE is the base and always stays
	#      every other desktop is an extra choice at login, added and removed
	#      here, with a record of exactly what it installed so removal is clean
	#      this file stands alone, 26-desktops copies it to /usr/local/bin/desktop

set -uo pipefail


#    Catalog

	# Ai - name | label | packages | what it is best for
	#      to offer another desktop, add one line here
CATALOG='
plasma|KDE Plasma|plasma-meta konsole|classic full desktop, the most settings of any, good fallback
gnome|GNOME|gnome|simple and polished, little to configure, strong touchpad and laptop support
cosmic|COSMIC|cosmic|new desktop with tiling built in, light, still young
niri|Niri|niri fuzzel foot|tiling where windows sit on an endless strip you scroll sideways
sway|Sway|sway swaybg foot wmenu|plain, very light tiling, the stable ancestor of Hyprland
xfce|Xfce|xfce4|old style, very light, runs on X11 instead of Wayland
dream|Dream (unfinished)|-|your own shell on Hyprland, a first draft, not polished
'

STATE=/var/lib/rebuild/desktops
SAVED="$HOME/.local/state/rebuild/desktops"

	# Ai - settings files more than one desktop writes to, kept before each add
SHARED=(gtk-3.0 gtk-4.0 kdeglobals qt5ct qt6ct dconf Kvantum xsettingsd mimeapps.list)

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"


#    Helpers

field() { printf '%s\n' "$CATALOG" | awk -F'|' -v n="$1" -v f="$2" '$1==n {print $f}'; }

names() { printf '%s\n' "$CATALOG" | awk -F'|' 'NF>1 {print $1}'; }

known() { [[ -n "$(field "$1" 2)" ]]; }

added() {
	if [[ "$1" == dream ]]; then
		[[ -f /usr/share/wayland-sessions/dream.desktop ]]
	else
		[[ -f "$STATE/$1.pkgs" ]]
	fi
}

sessions() {
	local f
	for f in /usr/share/wayland-sessions/*.desktop /usr/share/xsessions/*.desktop; do
		[[ -f "$f" ]] || continue
		sed -n 's/^Name=//p' "$f" | head -n 1
	done | sort -u
}

repo_dir() {
	local d
	for d in "$HOME/rebuild" "$(dirname "$(dirname "$(readlink -f "$0")")")"; do
		[[ -f "$d/scripts/25-shell.sh" ]] && { printf '%s' "$d"; return 0; }
	done
	return 1
}


#    Commands


## Catalog

	# Ai - plain list, used by the installer's question
cmd_catalog() {
	local n
	for n in $(names); do
		printf '  %-8s %s\n' "$n" "$(field "$n" 4)"
	done
}


## List

cmd_list() {
	local n mark
	printf '\n  Desktops on this PC\n\n'
	printf '  %-8s  %-20s  %s\n' "hyde" "HyDE on Hyprland" "the base, always here"
	for n in $(names); do
		if added "$n"; then mark="added"; else mark="not added"; fi
		printf '  %-8s  %-20s  %-9s  %s\n' "$n" "$(field "$n" 2)" "$mark" "$(field "$n" 4)"
	done
	printf '\n  On the login screen now:\n\n'
	sessions | sed 's/^/    /'
	printf '\n  Now running: %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
	printf '\n  desktop add NAME      put one on the login screen\n'
	printf '  desktop remove NAME   take it off again, with everything it installed\n'
	printf '\n  To switch: log out, pick the desktop from the list on the login screen, log in.\n\n'
}


## Add

cmd_add() {
	local n=$1 pkgs before after

	known "$n" || { printf 'Not a desktop: %s\nTry: desktop\n' "$n" >&2; return 1; }
	added "$n" && { printf '%s is already added.\n' "$(field "$n" 2)"; return 0; }

	if [[ "$n" == dream ]]; then
		local repo
		repo="$(repo_dir)" || { printf 'The rebuild folder is missing, Dream installs from it.\n' >&2; return 1; }
		bash "$repo/scripts/25-shell.sh"
		return
	fi

		# Ai - a copy of the settings desktops share, taken before the new one
		#      can touch them, so remove can put them back
	mkdir -p "$SAVED/before-$n"
	local s
	for s in "${SHARED[@]}"; do
		[[ -e "$HOME/.config/$s" ]] && cp -a "$HOME/.config/$s" "$SAVED/before-$n/" 2>/dev/null
	done

	pkgs="$(field "$n" 3)"
	before="$(pacman -Qq | sort)"

	printf '\n  Adding %s. This downloads a lot.\n\n' "$(field "$n" 2)"

		# shellcheck disable=SC2086
	$SUDO pacman -S --needed --noconfirm $pkgs || { printf '\n  Install failed, nothing was recorded.\n' >&2; return 1; }

	after="$(pacman -Qq | sort)"

		# Ai - only what this add brought in, so remove never takes a package
		#      that was here before
	$SUDO mkdir -p "$STATE"
	comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | $SUDO tee "$STATE/$n.pkgs" > /dev/null

		# Ai - a desktop may ship its own login screen, SDDM stays the only one
	local dm
	for dm in gdm cosmic-greeter lightdm; do
		$SUDO systemctl disable "$dm" > /dev/null 2>&1 || true
	done

	printf '\n  %s added, %s packages.\n' "$(field "$n" 2)" "$(wc -l < "$STATE/$n.pkgs")"
	printf '  Log out and pick it from the list on the login screen.\n'
	printf '  Take it off again with:  desktop remove %s\n\n' "$n"
}


## Remove

cmd_remove() {
	local n=$1

	known "$n" || { printf 'Not a desktop: %s\n' "$n" >&2; return 1; }
	added "$n" || { printf '%s is not added.\n' "$(field "$n" 2)"; return 0; }

	if [[ "$n" == dream ]]; then
		command -v dream > /dev/null && dream off > /dev/null 2>&1
		$SUDO rm -f /usr/share/wayland-sessions/dream.desktop /usr/local/bin/dream-session
		rm -f "$HOME/.install-state/25-shell"
		printf 'Dream taken off the login screen. Its files stay in ~/.config/dream.\n'
		return 0
	fi

	if [[ "${XDG_CURRENT_DESKTOP:-}" == *"$(field "$n" 2)"* ]]; then
		printf 'You are inside %s now. Log in to HyDE first, then remove it.\n' "$(field "$n" 2)" >&2
		return 1
	fi

	local list
	list="$(comm -12 <(sort "$STATE/$n.pkgs") <(pacman -Qq | sort))"

	if [[ -n "$list" ]]; then
			# Ai - unneeded skips anything another desktop still depends on
			# shellcheck disable=SC2086
		$SUDO pacman -Rnsu --noconfirm $list || { printf '\n  Removal failed, the record was kept.\n' >&2; return 1; }
	fi

	$SUDO rm -f "$STATE/$n.pkgs"

	printf '\n  %s removed.\n' "$(field "$n" 2)"

	if [[ -d "$SAVED/before-$n" ]]; then
		printf '  Your shared settings from before it was added are in:\n    %s\n' "$SAVED/before-$n"
		printf '  Put them back with:  desktop restore %s\n\n' "$n"
	fi
}


## Restore

cmd_restore() {
	local n=$1 s
	[[ -d "$SAVED/before-$n" ]] || { printf 'Nothing saved for %s.\n' "$n" >&2; return 1; }
	for s in "$SAVED/before-$n"/*; do
		[[ -e "$s" ]] || continue
		rm -rf "${HOME:?}/.config/$(basename "$s")"
		cp -a "$s" "$HOME/.config/"
	done
	printf 'Shared settings put back as they were before %s was added.\n' "$n"
}


#    Entry

case "${1:-list}" in
	list|"")  cmd_list ;;
	catalog)  cmd_catalog ;;
	add)      [[ -n "${2:-}" ]] || { printf 'desktop add NAME\n' >&2; exit 1; }; cmd_add "$2" ;;
	remove)   [[ -n "${2:-}" ]] || { printf 'desktop remove NAME\n' >&2; exit 1; }; cmd_remove "$2" ;;
	restore)  [[ -n "${2:-}" ]] || { printf 'desktop restore NAME\n' >&2; exit 1; }; cmd_restore "$2" ;;
	-h|--help|help) cmd_list ;;
	*) printf 'Unknown: %s\nTry: desktop\n' "$1" >&2; exit 1 ;;
esac
