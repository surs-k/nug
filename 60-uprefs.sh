#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-desktop

PREFS="$HOME/.config/hypr/userprefs.conf"
BINDS="$HOME/.local/share/hypr/lua/key_binds.lua"
MON="$HOME/.config/hypr/monitors.conf"

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

####### moonlight-qt and librewolf are in extra now, no AUR build needed
pac signal-desktop dolphin flatpak curl pciutils xdg-utils xorg-xrandr gamescope
pac moonlight-qt


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

####### AUR names move around, so each of these tries its alternates before
####### being recorded as a failure
try_aur() {
	local label=$1; shift
	local pkg

	for pkg in "$@"; do
		if yay -S --needed --noconfirm "$pkg" >&3 2>&1; then
			pass "$label   via $pkg"
			return 0
		fi
		printf '  ..     %s not available, trying the next name\n' "$pkg"
	done

	flag "$label could not be installed under any known name"
	return 0
}

if [[ "${WANT_LIBREWOLF:-yes}" == yes ]]; then
	####### librewolf is in extra now, the AUR build is the fallback
	pac librewolf || try_aur "librewolf" librewolf-bin
fi

####### unofficial repackaging of the official build
####### claude-desktop tracks the official Linux build, the others are
####### community repackaging
try_aur "claude desktop" claude-desktop claude-desktop-bin claude-desktop-native



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

mkdir -p "$(dirname "$PREFS")"
touch "$PREFS"
[[ -f "$PREFS.bak-prefs" ]] || cp "$PREFS" "$PREFS.bak-prefs"


## Clear

sed -i '/^# rebuild binds start$/,/^# rebuild binds end$/d' "$PREFS"


## Write

####### hyprlang, because HyDE does not use the Lua provider
####### unbind first, then bind, so HyDE's own binding is replaced rather
####### than fighting with ours

cat >> "$PREFS" << 'CONFEOF'
# rebuild binds start

unbind = SUPER, C
bind = SUPER, C, exec, codium

unbind = SUPER, P
bind = SUPER, P, exec, 1password

unbind = SUPER, B
bind = SUPER, B, exec, mullvad-browser

unbind = SUPER, V
bind = SUPER, V, exec, flatpak run io.freetubeapp.FreeTube

unbind = SUPER, S
bind = SUPER, S, exec, steam

bind = SUPER, D, exec, signal-desktop

unbind = SUPER, E
bind = SUPER, F, exec, dolphin

bind = SUPER, L, exec, librewolf

windowrulev2 = float, class:^(Mullvad Browser)$
windowrulev2 = size 1400 1000, class:^(Mullvad Browser)$
windowrulev2 = center, class:^(Mullvad Browser)$
windowrulev2 = suppressevent maximize, class:^(Mullvad Browser)$

# rebuild binds end
CONFEOF


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

sed -i '/^# rebuild monitors start$/,/^# rebuild monitors end$/d' "$MON"

cat >> "$MON" << 'MONEOF'
# rebuild monitors start

monitor = desc:Sceptre Tech Inc Sceptre O34, 3440x1440@165, 1080x233, 1
monitor = desc:Acer Technologies KG251Q T8ZAA00A8575, 1920x1080@143.98, 0x0, 1, transform, 1
monitor = , preferred, auto, 1

# rebuild monitors end
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
CFG="$REPO/configs"

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
check "binds block"        grep -q 'rebuild binds start' "$PREFS"
check "block closed"       grep -q 'rebuild binds end' "$PREFS"
check "block written once" sh -c "test \"\$(grep -c 'rebuild binds start' '$PREFS')\" = 1"
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
