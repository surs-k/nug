#!/usr/bin/env bash


set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


## Stage

require_stage 20-desktop


## Tools

command -v yay >/dev/null || { echo "yay missing - rerun 10-base" >&2; exit 1; }


## HyDE

LUA="$HOME/.config/hypr/hyprland.lua"
BINDS="$HOME/.local/share/hypr/lua/key_binds.lua"

export LUA

[[ -f "$HOME/.local/share/hypr/hyde.lua" ]] \
	|| { echo "hyde.lua missing - HyDE is pre-lua, run install.sh -r first" >&2; exit 1; }


section_done "Check"



#    Repos


## Multilib

if grep -q '^\[multilib\]' /etc/pacman.conf; then

	echo "multilib already enabled"

else
	sudo cp /etc/pacman.conf /etc/pacman.conf.bak-multilib

	sudo sed -i '/^#\[multilib\]$/,+1s/^#//' /etc/pacman.conf

	grep -q '^\[multilib\]' /etc/pacman.conf \
		|| { echo "multilib uncomment failed - restore /etc/pacman.conf.bak-multilib" >&2; exit 1; }
fi


## Sync

sudo pacman -Syu --noconfirm


section_done "Repos"



#    Packages


## Repo

sudo pacman -S --needed --noconfirm \
	signal-desktop dolphin flatpak curl pciutils xdg-utils


## Purge

for p in code firefox; do
	if pacman -Qq "$p" &>/dev/null; then
		sudo pacman -Rns --noconfirm "$p" \
			|| echo "could not remove $p - something depends on it" >&2
	fi
done


## Driver

GPU="$(lspci)"

if grep -qi nvidia <<< "$GPU"; then
	sudo pacman -S --needed --noconfirm lib32-nvidia-utils
else
	sudo pacman -S --needed --noconfirm lib32-mesa
fi


## Steam

sudo pacman -S --needed --noconfirm steam


## Key

OP_KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22

if gpg --list-keys "$OP_KEY" &>/dev/null; then

	echo "1password key already imported"

else
	curl -fsSL -o /tmp/1password.asc https://downloads.1password.com/linux/keys/1password.asc

	gpg --import /tmp/1password.asc

	gpg --list-keys "$OP_KEY" &>/dev/null \
		|| echo "1password key not in keyring - the AUR build will fail" >&2
fi


## AUR

yay -S --needed --noconfirm 1password \
	|| echo "1password did not build - SUPER + P will do nothing" >&2

yay -S --needed --noconfirm mullvad-browser-bin \
	|| echo "mullvad-browser-bin did not build - SUPER + B will do nothing" >&2

yay -S --needed --noconfirm vscodium-bin \
	|| echo "vscodium-bin did not build - SUPER + C will do nothing" >&2


section_done "Packages"



#    Flatpak


## Remote

sudo flatpak remote-add --if-not-exists flathub \
	https://dl.flathub.org/repo/flathub.flatpakrepo


## FreeTube

sudo flatpak install -y --noninteractive flathub io.freetubeapp.FreeTube \
	|| echo "FreeTube did not install - SUPER + V will do nothing" >&2


section_done "Flatpak"



#    Hyprland


## Survey

if [[ -f "$BINDS" ]]; then
	for combo in "SUPER + C" "SUPER + P" "SUPER + B" "SUPER + V" "SUPER + S" "SUPER + E"; do
		grep -qF "\"$combo\"" "$BINDS" \
			|| echo "warn: HyDE no longer binds $combo - that unbind may pop an error" >&2
	done
else
	echo "warn: $BINDS absent - cannot confirm HyDE bind spellings" >&2
fi


## Backup

mkdir -p "$(dirname "$LUA")"

touch "$LUA"

[[ -f "$LUA.bak-prefs" ]] || cp "$LUA" "$LUA.bak-prefs"


## Clear

sed -i '/^-- rebuild prefs start$/,/^-- rebuild prefs end$/d' "$LUA"


## Write

cat >> "$LUA" << 'LUAEOF'
-- rebuild prefs start

hl.unbind("SUPER + C")
hl.bind("SUPER + C", hl.dsp.exec_cmd("codium"), { description = "[Rebuild] codium" })

hl.unbind("SUPER + P")
hl.bind("SUPER + P", hl.dsp.exec_cmd("1password"), { description = "[Rebuild] 1password" })

hl.unbind("SUPER + B")
hl.bind("SUPER + B", hl.dsp.exec_cmd("mullvad-browser"), { description = "[Rebuild] mullvad-browser" })

hl.unbind("SUPER + V")
hl.bind("SUPER + V", hl.dsp.exec_cmd("flatpak run io.freetubeapp.FreeTube"), { description = "[Rebuild] freetube" })

hl.unbind("SUPER + S")
hl.bind("SUPER + S", hl.dsp.exec_cmd("steam"), { description = "[Rebuild] steam" })

hl.bind("SUPER + D", hl.dsp.exec_cmd("signal-desktop"), { description = "[Rebuild] signal" })

hl.unbind("SUPER + E")
hl.bind("SUPER + F", hl.dsp.exec_cmd("dolphin"), { description = "[Rebuild] dolphin" })

hl.window_rule({
	name = "rebuild-mullvad",
	match = { class = "^(mullvad browser)$" },
	float = true,
	size = { 1400, 1000 },
	center = true,
})

-- rebuild prefs end
LUAEOF


## Reload

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then

	hyprctl reload || echo "hyprctl reload failed - log out and back in" >&2

	hyde-shell keybinds_hint --reload &>/dev/null || true

else
	echo "not inside a Hyprland session - binds apply at next login"
fi


section_done "Hyprland"



#    Defaults


## Editor

CODE_DESKTOP=""

for d in vscodium-wayland.desktop vscodium.desktop codium.desktop; do
	[[ -f "/usr/share/applications/$d" ]] && { CODE_DESKTOP="$d"; break; }
done


## Mime

if [[ -n "$CODE_DESKTOP" ]]; then

	xdg-mime default "$CODE_DESKTOP" text/plain

	xdg-mime default "$CODE_DESKTOP" text/x-shellscript

	xdg-mime default "$CODE_DESKTOP" text/markdown

	echo "dolphin will open text with $CODE_DESKTOP"

else
	echo "warn: no vscodium desktop file found - set the editor by hand in dolphin" >&2
fi


## Browser

BROWSER_DESKTOP=""

for d in mullvad-browser.desktop mullvadbrowser.desktop; do
	[[ -f "/usr/share/applications/$d" ]] && { BROWSER_DESKTOP="$d"; break; }
done

if [[ -n "$BROWSER_DESKTOP" ]]; then

	xdg-settings set default-web-browser "$BROWSER_DESKTOP"

	echo "default browser is $BROWSER_DESKTOP"

else
	echo "warn: no mullvad-browser desktop file found - default browser unchanged" >&2
fi


section_done "Defaults"



#    Configs


## Source

CFG="$(dirname "$(readlink -f "$0")")/config"


## Dolphin

if [[ -d "$CFG" ]]; then

	if [[ -f "$CFG/dolphinrc" ]]; then
		cp "$CFG/dolphinrc" "$HOME/.config/dolphinrc"
	fi

	if [[ -f "$CFG/user-places.xbel" ]]; then
		mkdir -p "$HOME/.local/share"
		cp "$CFG/user-places.xbel" "$HOME/.local/share/user-places.xbel"
	fi

	if [[ -d "$CFG/view_properties" ]]; then
		mkdir -p "$HOME/.local/share/dolphin"
		cp -r "$CFG/view_properties" "$HOME/.local/share/dolphin/"
	fi

else
	echo "no config/ directory - dolphin settings left alone"
fi


section_done "Configs"



#    Verify


echo "VERIFY"
echo


check "multilib enabled"    grep -q '^\[multilib\]' /etc/pacman.conf

check "signal-desktop"      command -v signal-desktop

check "dolphin"             command -v dolphin

check "steam"               command -v steam

check "flatpak"             command -v flatpak

check "prefs block"         grep -q 'rebuild prefs start' "$LUA"

check "block closed"        grep -q 'rebuild prefs end' "$LUA"

check "block written once"  sh -c 'test "$(grep -c "rebuild prefs start" "$LUA")" = 1'

warn  "codium"              command -v codium

warn  "1password"           command -v 1password

warn  "mullvad-browser"     command -v mullvad-browser

warn  "freetube"            flatpak info io.freetubeapp.FreeTube

warn  "hyde key_binds"      test -f "$BINDS"

warn  "firefox removed"     sh -c '! pacman -Qq firefox'

warn  "mullvad rule"        grep -q 'rebuild-mullvad' "$LUA"

warn  "editor default"      sh -c 'test -n "$(xdg-mime query default text/plain)"'

verify_done


section_done "Verify"



#    End


stage_done 60-userprefs

echo
echo "Log out and back in if the binds did not take"
echo
echo "SUPER + slash lists every bind"
echo
echo "Rollback: restore $LUA.bak-prefs"
echo


section_done "End"
