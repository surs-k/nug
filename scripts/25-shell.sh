#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop



#    Shell


section "Shell"

	# Ai - the Dream shell is a bar, launcher, notifications and settings window
	#      drawn by quickshell, it sits beside HyDE and never replaces it
	#      HyDE stays as the second choice at the login screen


## Package

pac quickshell


## Paths

SRC="$REPO/shell"
DST="$HOME/.config/quickshell/dream"
CFG="$HOME/.config/dream"
LUA="$HOME/.config/hypr/hyprland.lua"

[[ -f "$SRC/shell.qml" ]] || { printf 'No shell folder in the repo at %s\n' "$SRC" >&2; exit 1; }

mkdir -p "$HOME/.config/quickshell" "$CFG/hypr" "$HOME/.local/bin" "$HOME/.local/state/dream"


## Code

	# Ai - the shell's own files are replaced whole, the repo is the truth
	#      a change made in ~/.config/quickshell/dream is lost here, the guide
	#      says to copy it into the repo's shell folder to keep it
	#      a link from an earlier test is removed first, rm -rf on a link to a
	#      folder would otherwise leave the link and copy the folder onto itself
[[ -L "$DST" ]] && rm "$DST"
rm -rf "$DST"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

note "shell files copied to $DST"


## Yours

	# Ai - these three are yours once they exist, so they are only written
	#      when missing, settings.json is never written here at all, the shell
	#      makes it on first start and every choice you make lands in it
for f in looks.json hypr/dream.lua; do
	if [[ ! -f "$CFG/$f" ]]; then
		cp "$SRC/$f" "$CFG/$f"
		note "wrote $CFG/$f"
	elif ! cmp -s "$SRC/$f" "$CFG/$f"; then
		note "kept your $f, it differs from the repo's"
	fi
done

	# Ai - the guide is not yours to edit, it is refreshed so it matches the code
cp "$SRC/GUIDE.md" "$CFG/GUIDE.md"


## Command

install -m 755 "$SRC/bin/dream" "$HOME/.local/bin/dream"

note "the command is: dream"


## Hook

	# Ai - one small block in your Hyprland config loads dream.lua
	#      dream.lua does nothing unless Dream is on, and the block catches any
	#      mistake in it, so a broken Dream file cannot break the HyDE desktop
mkdir -p "$(dirname "$LUA")"
touch "$LUA"
[[ -f "$LUA.bak-dream" ]] || cp "$LUA" "$LUA.bak-dream"

sed -i '/^-- rebuild dream start$/,/^-- rebuild dream end$/d' "$LUA"

cat >> "$LUA" << 'LUAEOF'
-- rebuild dream start

-- The Dream shell. This does nothing unless Dream is switched on
-- (the Dream login session, or the command: dream on).
-- A mistake in the Dream file is caught here and cannot break this config.
do
	local file = (os.getenv("HOME") or "") .. "/.config/dream/hypr/dream.lua"
	local handle = io.open(file, "r")
	if handle then
		handle:close()
		local ok, err = pcall(dofile, file)
		if not ok then print("dream.lua: " .. tostring(err)) end
	end
end

-- rebuild dream end
LUAEOF

note "hook written to hyprland.lua"


## Session

	# Ai - a second entry on the login screen, same Hyprland, Dream switched on
	#      the plain Hyprland entry is left alone and stays the HyDE desktop
$SUDO install -m 755 "$SRC/session/dream-session" /usr/local/bin/dream-session
$SUDO install -m 644 "$SRC/session/dream.desktop" /usr/share/wayland-sessions/dream.desktop

note "login screen now lists Dream beside Hyprland"



#    Verify


section "Verify"

check "quickshell present"   command -v qs
check "shell entry file"     test -f "$DST/shell.qml"
check "shell is a copy"      test ! -L "$DST"
check "dream command"        test -x "$HOME/.local/bin/dream"
check "looks file"           test -f "$CFG/looks.json"
check "looks file parses"    jq empty "$CFG/looks.json"
check "dream.lua"            test -f "$CFG/hypr/dream.lua"
check "guide"                test -f "$CFG/GUIDE.md"
check "hook block"           grep -q 'rebuild dream start' "$LUA"
check "hook closed"          grep -q 'rebuild dream end' "$LUA"
check "hook written once"    sh -c "test \"\$(grep -c 'rebuild dream start' '$LUA')\" = 1"
check "session wrapper"      test -x /usr/local/bin/dream-session
check "session entry"        test -f /usr/share/wayland-sessions/dream.desktop
check "hyde entry untouched" test -f /usr/share/wayland-sessions/hyprland.desktop

	# Ai - the file being there proves nothing, this asks Hyprland to read it
check "hyprland config ok"   sh -c "Hyprland --verify-config 2>&1 | grep -q 'config ok'"

	# Ai - only when a desktop is up, the shell cannot start without one
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
	warn "shell answers when on" sh -c "! systemctl --user is-active --quiet dream-shell.service || qs -c dream ipc show | grep -q launcher"
fi

verify_done

stage_done



#    End


section "End"

printf '  Dream shell installed. HyDE is untouched and still the default.\n\n'
printf '  Try it now, without logging out:   dream on\n'
printf '  Go back:                           dream off\n'
printf '  Or pick Dream on the login screen.\n\n'
