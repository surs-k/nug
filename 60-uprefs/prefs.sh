#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop

LUA="$HOME/.config/hypr/hyprland.lua"
BINDS="$HOME/.local/share/hypr/lua/key_binds.lua"
MON="$HOME/.config/hypr/monitors.lua"

[[ -f "$HOME/.local/share/hypr/hyde.lua" ]] \
	|| { printf 'hyde.lua missing, HyDE is pre-lua, run install.sh -r first\n' >&2; exit 1; }



#    Repos


section "Repos"

if grep -q '^\[multilib\]' /etc/pacman.conf; then
	note "multilib already enabled"
else
	$SUDO cp /etc/pacman.conf /etc/pacman.conf.bak-multilib
	$SUDO sed -i '/^#\[multilib\]$/,+1s/^#//' /etc/pacman.conf
	grep -q '^\[multilib\]' /etc/pacman.conf \
		|| { printf 'multilib uncomment failed, restore the .bak-multilib file\n' >&2; exit 1; }
fi

run "sync repos" $SUDO pacman -Syu --noconfirm



#    Packages


section "Packages"


## Repo

pac signal-desktop dolphin flatpak curl pciutils xdg-utils xorg-xrandr gamescope


## Keyring

####### 1password and claude desktop both refuse to start without a secret
####### service, this supplies one without touching pam
pac gnome-keyring libsecret seahorse


## Purge

for p in code firefox; do
	if pacman -Qq "$p" &> /dev/null; then
		soft "remove $p" $SUDO pacman -Rns --noconfirm "$p"
	fi
done


## Driver

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
	pac lib32-nvidia-utils
else
	pac lib32-mesa
fi


## Steam

pac steam



#    Aur


section "Aur"


## Key

OP_KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22

if gpg --list-keys "$OP_KEY" &> /dev/null; then
	note "1password key already imported"
else
	run "fetch 1password key" curl -fsSL -o /tmp/1password.asc \
		https://downloads.1password.com/linux/keys/1password.asc
	soft "import 1password key" gpg --import /tmp/1password.asc
fi


## Builds

soft "1password"      yay -S --needed --noconfirm 1password
soft "mullvad browser" yay -S --needed --noconfirm mullvad-browser-bin
soft "vscodium"       yay -S --needed --noconfirm vscodium-bin

if [[ "${WANT_LIBREWOLF:-yes}" == yes ]]; then
	soft "librewolf" yay -S --needed --noconfirm librewolf-bin
fi

####### unofficial repackaging of the official build, so it warns and
####### carries on rather than stopping the run when it breaks
soft "claude desktop" yay -S --needed --noconfirm claude-desktop-native



#    Flatpak


section "Flatpak"

run "add flathub" $SUDO flatpak remote-add --if-not-exists flathub \
	https://dl.flathub.org/repo/flathub.flatpakrepo

soft "freetube" $SUDO flatpak install -y --noninteractive flathub io.freetubeapp.FreeTube
soft "vesktop"  $SUDO flatpak install -y --noninteractive flathub dev.vencord.Vesktop



#    Hyprland


section "Hyprland"


## Survey

if [[ -f "$BINDS" ]]; then
	for combo in "SUPER + C" "SUPER + P" "SUPER + B" "SUPER + V" "SUPER + S" "SUPER + E"; do
		grep -qF "\"$combo\"" "$BINDS" \
			|| flag "HyDE no longer binds $combo, that unbind may pop an error"
	done
else
	flag "$BINDS absent, cannot confirm HyDE bind spellings"
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

hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "colemak"
  }
})

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

hl.bind("SUPER + L", hl.dsp.exec_cmd("librewolf"), { description = "[Rebuild] librewolf local" })

hl.window_rule({
	name = "rebuild-mullvad-nomax",
	match = { class = "^(Mullvad Browser)$" },
	suppress_event = "maximize",
})

hl.window_rule({
	name = "rebuild-mullvad",
	match = { class = "^(Mullvad Browser)$" },
	float = true,
	size = { 1400, 1000 },
	center = true,
})

-- rebuild prefs end
LUAEOF


## Reload

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	soft "reload hyprland" hyprctl reload
	hyde-shell keybinds_hint --reload &> /dev/null || true
else
	note "not inside Hyprland, binds apply at next login"
fi



#    Monitors


section "Monitors"

[[ -f "$MON" ]] || touch "$MON"
[[ -f "$MON.bak-prefs" ]] || cp "$MON" "$MON.bak-prefs"

sed -i '/^-- rebuild monitors start$/,/^-- rebuild monitors end$/d' "$MON"

cat >> "$MON" << 'MONEOF'
-- rebuild monitors start

hl.monitor({
	output = "desc:Sceptre Tech Inc Sceptre O34",
	mode = "3440x1440@165",
	position = "1080x233",
	scale = 1,
	transform = 0,
})

hl.monitor({
	output = "desc:Acer Technologies KG251Q T8ZAA00A8575",
	mode = "1920x1080@143.98",
	position = "0x0",
	scale = 1,
	transform = 1,
})

hl.monitor({
	output = "",
	mode = "preferred",
	position = "auto",
	scale = 1,
	transform = 0,
})

-- rebuild monitors end
MONEOF


## Greeter

$SUDO mkdir -p /etc/sddm /etc/sddm.conf.d

$SUDO tee /etc/sddm/Xsetup-rebuild > /dev/null << 'XEOF'
#!/bin/sh
OUT=$(xrandr --query | awk '/ connected/{o=$1} o!="" && /^ +1920x1080/ && /\+/{print o; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --rotate left
exit 0
XEOF

$SUDO chmod 755 /etc/sddm/Xsetup-rebuild

$SUDO tee /etc/sddm.conf.d/20-rebuild-rotate.conf > /dev/null << 'SEOF'
[X11]
DisplayCommand=/etc/sddm/Xsetup-rebuild
SEOF



#    Defaults


section "Defaults"


## Editor

CODE_DESKTOP=""

for d in vscodium-wayland.desktop vscodium.desktop codium.desktop; do
	[[ -f "/usr/share/applications/$d" ]] && { CODE_DESKTOP="$d"; break; }
done

if [[ -n "$CODE_DESKTOP" ]]; then
	xdg-mime default "$CODE_DESKTOP" text/plain
	xdg-mime default "$CODE_DESKTOP" text/x-shellscript
	xdg-mime default "$CODE_DESKTOP" text/markdown
	note "text files open with $CODE_DESKTOP"
else
	flag "no vscodium desktop file found, set the editor by hand in dolphin"
fi


## Browser

BROWSER_DESKTOP=""

for d in mullvad-browser.desktop mullvadbrowser.desktop; do
	[[ -f "/usr/share/applications/$d" ]] && { BROWSER_DESKTOP="$d"; break; }
done

if [[ -n "$BROWSER_DESKTOP" ]]; then
	soft "set default browser" xdg-settings set default-web-browser "$BROWSER_DESKTOP"
else
	flag "no mullvad-browser desktop file found, default browser unchanged"
fi



#    Configs


section "Configs"

####### this used to point at config, the directory is configs
####### the block silently did nothing every single run
CFG="$(dirname "$(readlink -f "$0")")/configs"

if [[ -d "$CFG" ]]; then

	[[ -f "$CFG/dolphinrc" ]] && cp "$CFG/dolphinrc" "$HOME/.config/dolphinrc"

	if [[ -f "$CFG/user-places.xbel" ]]; then
		mkdir -p "$HOME/.local/share"
		sed "s|/home/[^/\"]*|/home/$(id -un)|g" "$CFG/user-places.xbel" \
			> "$HOME/.local/share/user-places.xbel"
	fi

	if [[ -d "$CFG/view_properties" ]]; then
		mkdir -p "$HOME/.local/share/dolphin"
		cp -r "$CFG/view_properties" "$HOME/.local/share/dolphin/"
	fi

	note "dolphin settings applied"
else
	flag "no configs directory at $CFG"
fi



#    Verify


section "Verify"

check "multilib enabled"   grep -q '^\[multilib\]' /etc/pacman.conf
check "signal-desktop"     command -v signal-desktop
check "dolphin"            command -v dolphin
check "steam"              command -v steam
check "flatpak"            command -v flatpak
check "keyring present"    command -v gnome-keyring-daemon
check "prefs block"        grep -q 'rebuild prefs start' "$LUA"
check "block closed"       grep -q 'rebuild prefs end' "$LUA"
check "block written once" sh -c "test \"\$(grep -c 'rebuild prefs start' '$LUA')\" = 1"
check "monitors block"     grep -q 'rebuild monitors start' "$MON"
check "monitors once"      sh -c "test \"\$(grep -c 'rebuild monitors start' '$MON')\" = 1"
check "dolphin config"     test -f "$HOME/.config/dolphinrc"

warn  "codium"             command -v codium
warn  "1password"          command -v 1password
warn  "mullvad-browser"    command -v mullvad-browser
warn  "librewolf"          command -v librewolf
warn  "claude desktop"     command -v claude-desktop
warn  "freetube"           flatpak info io.freetubeapp.FreeTube
warn  "places installed"   test -f "$HOME/.local/share/user-places.xbel"
warn  "greeter rotate"     test -x /etc/sddm/Xsetup-rebuild

verify_done

stage_done



#    End


section "End"

printf '  Preferences applied.\n'
printf '  SUPER + slash lists every keybind.\n\n'
