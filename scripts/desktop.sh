#!/usr/bin/env bash

	# Ai - desktop: add, remove and list desktops on the login screen
	#      HyDE is the base
	#      classic desktops (Plasma, GNOME) are extra choices at login, added
	#      and removed here, with a record of exactly what each installed
	#      Hyprland setups like HyDE are tried: snapshot, install, and
	#      "desktop back" puts everything the way it was
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

	# Ai - Hyprland setups like HyDE: someone's finished desktop, built from
	#      settings files and an installer, published on GitHub
	#      they all write into the same folders HyDE uses, so only one can
	#      be in place at a time, which is why these are tried, not added:
	#      a snapshot is taken first and "desktop back" returns to it
	#      name | label | where it comes from | how it installs | what it is like
	#      $SRC is a scratch folder for the download, removed again on back
SETUPS='
end4|illogical-impulse|https://github.com/end-4/dots-hyprland|git clone --depth 1 https://github.com/end-4/dots-hyprland "$SRC" && cd "$SRC" && ./setup install|by end-4: Quickshell widgets, colours taken from the wallpaper, an overview of all windows
ml4w|ML4W|https://github.com/mylinuxforwork/dotfiles|bash <(curl -s https://ml4w.com/os/stable)|full desktop with its own settings apps, colours taken from the wallpaper
caelestia|Caelestia|https://github.com/caelestia-dots/caelestia|yay -S --needed caelestia-cli && caelestia install|Quickshell shell with a dashboard and launcher, has no login screen of its own
jakoolit|JaKooLit Hyprland|https://github.com/JaKooLit/Arch-Hyprland|git clone --depth 1 https://github.com/JaKooLit/Arch-Hyprland "$SRC" && cd "$SRC" && ./install.sh|Waybar and Rofi based, many ready layouts and themes, guided installer
'

STATE=/var/lib/rebuild/desktops

	# Ai - one trial at a time, this folder existing means one is running
TRIAL=/var/lib/rebuild/trial

	# Ai - the read only copy of every home folder, taken the moment a trial starts
SNAP=/home/.desktop-trial

SRC="$HOME/.desktop-trial-src"

	# Ai - hidden things in your home that going back must leave alone
	#      the installer's own records, and the trial's download folder
KEEP_LIVE=(.desktop-trial-src .rebuild .install-state .install-config)
SAVED="$HOME/.local/state/rebuild/desktops"

	# Ai - settings files more than one desktop writes to, kept before each add
SHARED=(gtk-3.0 gtk-4.0 kdeglobals qt5ct qt6ct dconf Kvantum xsettingsd mimeapps.list)

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"


#    Helpers

field() { printf '%s\n' "$CATALOG" | awk -F'|' -v n="$1" -v f="$2" '$1==n {print $f}'; }

sfield() { printf '%s\n' "$SETUPS" | awk -F'|' -v n="$1" -v f="$2" '$1==n {print $f}'; }

snames() { printf '%s\n' "$SETUPS" | awk -F'|' 'NF>1 {print $1}'; }

sknown() { [[ -n "$(sfield "$1" 2)" ]]; }

trying() { [[ -d "$TRIAL" ]]; }

	# Ai - a real yes typed by you, the VM test sets DESKTOP_YES instead
agree() {
	local reply
	[[ "${DESKTOP_YES:-0}" == 1 ]] && return 0
	read -rp "  $1 Type yes to go on: " reply
	[[ "$reply" == yes ]]
}

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
	printf '  %-8s  %-20s  %s\n' "hyde" "HyDE on Hyprland" "the base"
	for n in $(names); do
		if added "$n"; then mark="added"; else mark="not added"; fi
		printf '  %-8s  %-20s  %-9s  %s\n' "$n" "$(field "$n" 2)" "$mark" "$(field "$n" 4)"
	done
	printf '\n  Hyprland setups like HyDE, to try and go back from\n\n'
	for n in $(snames); do
		printf '  %-10s  %-18s  %s\n' "$n" "$(sfield "$n" 2)" "$(sfield "$n" 5)"
	done
	if trying; then
		printf '\n  Trying now: %s, since %s\n' "$(cat "$TRIAL/name" 2>/dev/null)" "$(cat "$TRIAL/date" 2>/dev/null)"
		printf '  desktop back   return to how things were     desktop keep   stay on it\n'
	fi
	printf '\n  On the login screen now:\n\n'
	sessions | sed 's/^/    /'
	printf '\n  Now running: %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
	printf '\n  desktop try NAME      snapshot, then install a Hyprland setup in place of HyDE\n'
	printf '  desktop back          undo the trial: settings, packages and system files\n'
	printf '  desktop keep          stay on the trial and drop the snapshot\n'
	printf '  desktop add NAME      put a classic desktop on the login screen\n'
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


## Try

cmd_try() {
	local n=$1 cmd label num rc

	sknown "$n" || { printf 'Not a setup: %s\nTry: desktop\n' "$n" >&2; return 1; }
	[[ $EUID -ne 0 ]] || { printf 'Run this as yourself, not as root.\n' >&2; return 1; }
	trying && { printf 'Already trying %s. First: desktop back, or desktop keep\n' "$(cat "$TRIAL/name")" >&2; return 1; }
	[[ "$HOME" == /home/* ]] || { printf 'Your home is not under /home, the snapshot cannot cover it.\n' >&2; return 1; }

	label="$(sfield "$n" 2)"
	cmd="${DESKTOP_TRY_CMD:-$(sfield "$n" 4)}"

	printf '\n  Try %s\n\n' "$label"
	printf '  from   %s\n' "$(sfield "$n" 3)"
	printf '  runs   %s\n\n' "$cmd"
	printf '  First a snapshot is taken of every hidden settings folder in your\n'
	printf '  home, of the list of installed packages, and of the system files.\n'
	printf '  Then the setup installs itself over HyDE. Its installer is someone\n'
	printf '  else'"'"'s program and will ask its own questions and for your password.\n\n'
	printf '  desktop back undoes it. Files in Documents, Downloads and other\n'
	printf '  visible folders are never touched, in either direction.\n\n'

	agree "Start the trial?" || { printf '  Nothing changed.\n'; return 0; }

	$SUDO true || return 1

	if [[ "$(findmnt -no FSTYPE /home)" != btrfs ]] || ! $SUDO btrfs subvolume show /home > /dev/null 2>&1; then
		printf '\n  /home is not a btrfs subvolume, so no snapshot can be taken. Nothing changed.\n' >&2
		return 1
	fi

	command -v rsync > /dev/null || $SUDO pacman -S --needed --noconfirm rsync || return 1

	if $SUDO test -e "$SNAP"; then
		printf '\n  A leftover snapshot is in the way: %s\n  Remove it with: sudo btrfs subvolume delete %s\n' "$SNAP" "$SNAP" >&2
		return 1
	fi


	# Record

	$SUDO mkdir -p "$TRIAL"
	printf '%s\n' "$n" | $SUDO tee "$TRIAL/name" > /dev/null
	date '+%Y-%m-%d %H:%M' | $SUDO tee "$TRIAL/date" > /dev/null
	pacman -Qq  | sort | $SUDO tee "$TRIAL/pkgs.all"     > /dev/null
	pacman -Qqm | sort | $SUDO tee "$TRIAL/pkgs.foreign" > /dev/null
	getent passwd "$USER" | cut -d: -f7 | $SUDO tee "$TRIAL/shell" > /dev/null

		# Ai - the system side, snapper is what the boot menu's snapshots use
	if command -v snapper > /dev/null && $SUDO snapper -c root get-config > /dev/null 2>&1; then
		num="$($SUDO snapper -c root create --type single --cleanup-algorithm number \
			--description "before trying $label" --print-number)"
		printf '%s\n' "$num" | $SUDO tee "$TRIAL/snapper" > /dev/null
		printf '  system snapshot %s taken\n' "$num"
	fi

	sync
	$SUDO btrfs subvolume snapshot -r /home "$SNAP" > /dev/null || {
		printf '\n  The home snapshot failed. Nothing was installed.\n' >&2
		$SUDO rm -rf "$TRIAL"
		return 1
	}
	printf '  home snapshot taken\n\n'


	# Install

	rm -rf "$SRC"
	export SRC

	bash -c "$cmd"
	rc=$?

	printf '\n'
	if (( rc == 0 )); then
		printf '  %s finished installing.\n' "$label"
	else
		printf '  The installer of %s stopped with an error (exit %s).\n' "$label" "$rc"
	fi
	printf '  Restart the PC and log in to look at it.\n\n'
	printf '  desktop back   return to exactly how things were\n'
	printf '  desktop keep   stay on it and drop the snapshot\n\n'
}


## Back

	# Ai - which changed files under /etc are put back
	#      left alone: account files, caches, keys, and files a package
	#      owns but does not treat as settings, those changed because the
	#      package itself was upgraded
etc_to_undo() {
	local num=$1 path owner
	$SUDO snapper -c root status "$num..0" 2>/dev/null | awk '{ $1=""; sub(/^ /, ""); print }' | grep '^/etc/' \
		| grep -vE '^/etc/(passwd|group|shadow|gshadow|subuid|subgid)-?$|^/etc/(\.pwd\.lock|\.updated|ld\.so\.cache|machine-id|mtab|resolv\.conf|adjtime)$|^/etc/(pacman\.d/gnupg|ssl|ca-certificates|fonts/conf\.d|udev/hwdb\.bin|rebuild|cryptsetup-keys\.d)(/|$)' \
		| while IFS= read -r path; do
			owner="$(pacman -Qqo "$path" 2>/dev/null | head -n1)"
			if [[ -z "$owner" ]]; then
				printf '%s\n' "$path"
			elif pacman -Qii "$owner" 2>/dev/null | grep -qF "$path"; then
				printf '%s\n' "$path"
			fi
		done
}

cmd_back() {
	local n label rel num old cur list repo aur p inc=() ex=() k rc

	trying || { printf 'No trial is running. Nothing to go back from.\n'; return 0; }
	[[ $EUID -ne 0 ]] || { printf 'Run this as yourself, not as root.\n' >&2; return 1; }

	n="$(cat "$TRIAL/name")"
	label="$(sfield "$n" 2)"
	rel="${HOME#/home/}"

	printf '\n  Go back from %s to how things were on %s\n\n' "${label:-$n}" "$(cat "$TRIAL/date")"
	printf '  Hidden settings folders in your home return to the snapshot.\n'
	printf '  Packages the trial installed are removed, ones it removed return.\n'
	printf '  System settings files it changed are put back.\n'
	printf '  Visible folders such as Documents and Downloads are not touched.\n\n'

	agree "Go back?" || { printf '  Nothing changed.\n'; return 0; }

	$SUDO true || return 1
	$SUDO test -d "$SNAP/$rel" || { printf '\n  The home snapshot is missing: %s\n  Nothing changed.\n' "$SNAP" >&2; return 1; }


	# Home

	printf '\n  settings folders ...\n'

	for k in "${KEEP_LIVE[@]}"; do ex+=(--exclude="/$k"); done

		# Ai - only what differs is copied, and anything new is removed
		#      the rules read: skip the keep list, take every top level entry
		#      whose name starts with a dot and all inside it, skip the rest
	rsync -aHAX --delete "${ex[@]}" --include='/.*' --include='/.*/**' --exclude='/*' \
		"$SNAP/$rel/" "$HOME/" 2> /tmp/desktop-back-rsync.log
	rc=$?
	if (( rc != 0 && rc != 23 && rc != 24 )); then
		printf '  Copying settings back failed (rsync exit %s). The snapshot is kept, run desktop back again.\n' "$rc" >&2
		tail -n 5 /tmp/desktop-back-rsync.log >&2
		return 1
	fi
	(( rc != 0 )) && printf '  a few files could not be copied, see /tmp/desktop-back-rsync.log\n'

	rm -rf "$SRC"


	# Packages

	printf '  packages ...\n'

	cur="$(pacman -Qq | sort)"
	list="$(comm -23 "$TRIAL/pkgs.all" <(printf '%s\n' "$cur"))"
	repo=""; aur=""
	for p in $list; do
		if grep -qxF "$p" "$TRIAL/pkgs.foreign"; then aur+=" $p"; else repo+=" $p"; fi
	done

		# Ai - ask 4 answers yes to "remove the package this conflicts with",
		#      which is the trial's replacement for the one coming back
		# shellcheck disable=SC2086
	[[ -n "$repo" ]] && { $SUDO pacman -S --needed --noconfirm --ask 4 $repo \
		|| printf '  could not bring back:%s\n' "$repo" >&2; }
		# shellcheck disable=SC2086
	[[ -n "$aur" ]] && command -v yay > /dev/null && { yay -S --needed --noconfirm --answerdiff None --answerclean None $aur \
		|| printf '  could not rebuild:%s\n' "$aur" >&2; }

	list="$(comm -13 "$TRIAL/pkgs.all" <(pacman -Qq | sort))"
		# shellcheck disable=SC2086
	[[ -n "$list" ]] && { $SUDO pacman -Rnsu --noconfirm $list \
		|| printf '  could not remove some packages the trial installed, see: pacman -Qq\n' >&2; }


	# System files

	if [[ -f "$TRIAL/snapper" ]]; then
		printf '  system settings files ...\n'
		num="$(cat "$TRIAL/snapper")"
		etc_to_undo "$num" > /tmp/desktop-back-etc.list
		if [[ -s /tmp/desktop-back-etc.list ]]; then
			$SUDO snapper -c root undochange --input /tmp/desktop-back-etc.list "$num..0" > /dev/null \
				|| printf '  some system files could not be put back, list: /tmp/desktop-back-etc.list\n' >&2
			$SUDO systemctl daemon-reload
		fi
	fi

	old="$(cat "$TRIAL/shell" 2>/dev/null)"
	if [[ -n "$old" && "$(getent passwd "$USER" | cut -d: -f7)" != "$old" ]]; then
		$SUDO chsh -s "$old" "$USER" > /dev/null
	fi


	# Done

	$SUDO btrfs subvolume delete "$SNAP" > /dev/null
	$SUDO rm -rf "$TRIAL"

	printf '\n  Back to how things were.\n'
	[[ -n "${num:-}" ]] && printf '  If the system misbehaves, system snapshot %s in the boot menu is the state before the trial.\n' "$num"
	printf '  Restart the PC now, then log in as usual.\n\n'
}


## Keep

cmd_keep() {
	trying || { printf 'No trial is running.\n'; return 0; }
	printf '\n  Stay on %s. The snapshot is deleted, so desktop back will no longer work.\n\n' "$(sfield "$(cat "$TRIAL/name")" 2)"
	agree "Keep it?" || { printf '  Nothing changed.\n'; return 0; }
	$SUDO btrfs subvolume delete "$SNAP" > /dev/null
	$SUDO rm -rf "$TRIAL"
	rm -rf "$SRC"
	printf '  Kept.\n'
}



#    Entry

case "${1:-list}" in
	list|"")  cmd_list ;;
	catalog)  cmd_catalog ;;
	add)      [[ -n "${2:-}" ]] || { printf 'desktop add NAME\n' >&2; exit 1; }; cmd_add "$2" ;;
	remove)   [[ -n "${2:-}" ]] || { printf 'desktop remove NAME\n' >&2; exit 1; }; cmd_remove "$2" ;;
	try)      [[ -n "${2:-}" ]] || { printf 'desktop try NAME\n' >&2; exit 1; }; cmd_try "$2" ;;
	back)     cmd_back ;;
	keep)     cmd_keep ;;
	restore)  [[ -n "${2:-}" ]] || { printf 'desktop restore NAME\n' >&2; exit 1; }; cmd_restore "$2" ;;
	-h|--help|help) cmd_list ;;
	*) printf 'Unknown: %s\nTry: desktop\n' "$1" >&2; exit 1 ;;
esac
