#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 30-desktop

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

	# Ai - librewolf is in extra now, no AUR build needed
	#      moonlight-qt is gone from this list, it is the client that runs on
	#      the laptop and connects to Sunshine on this PC, it was left here when
	#      v6.0 moved it from the AUR to the official repo, which is why it
	#      installed even with Sunshine turned off
pac signal-desktop dolphin flatpak curl pciutils xdg-utils xorg-xrandr gamescope


## Keyring

	# Ai - 1password and claude desktop both refuse to start without a secret
	#      service, this supplies one without touching pam
pac gnome-keyring libsecret seahorse


## Purge

	# Ai - moonlight-qt is here so an install made before v7.0 loses it too
for p in code firefox moonlight-qt; do
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
	# Ai - the browser is signed by the Tor Browser developers key
	#      yay asks the keyservers for it and they returned nothing, which
	#      stopped the build, so it is fetched by fingerprint first
MB_KEY=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290

if gpg --list-keys "$MB_KEY" &> /dev/null; then
	note "mullvad browser key already imported"
else
	run "fetch mullvad browser key" curl -fsSL -o /tmp/mullvad-browser.asc \
		"https://keys.openpgp.org/vks/v1/by-fingerprint/$MB_KEY"
	soft "import mullvad browser key" gpg --import /tmp/mullvad-browser.asc
fi

soft "mullvad browser" yay -S --needed --noconfirm mullvad-browser-bin
soft "vscodium"       yay -S --needed --noconfirm vscodium-bin

	# Ai - AUR names move around, so each of these tries its alternates before
	#      being recorded as a failure
try_aur() {
	local label=$1; shift
	local pkg

	for pkg in "$@"; do
		if yay -S --needed --noconfirm --answerdiff=None --answerclean=None \
			--answeredit=None --removemake "$pkg" >&3 2>&1; then
			pass "$label   via $pkg"
			return 0
		fi
		printf '  ..     %s not available, trying the next name\n' "$pkg"
	done

	flag "$label could not be installed under any known name"
	return 0
}

if [[ "${WANT_LIBREWOLF:-yes}" == yes ]]; then
		# Ai - librewolf is in extra now, the AUR build is the fallback
	pac librewolf || try_aur "librewolf" librewolf-bin
fi

	# Ai - unofficial repackaging of the official build
	#      claude-desktop tracks the official Linux build, the others are
	#      community repackaging
try_aur "claude desktop" claude-desktop claude-desktop-bin claude-desktop-native



## Search

	# Ai - SearXNG goes into Mullvad Browser as a keyword bookmark, made once by
	#      hand, see Search in Guides/Selfhost.md
	#      v7.3 wrote a policy file for it instead, the browser never took it, so
	#      a file of ours left in the browser's folder is removed again

MB_FILES="$(pacman -Qlq mullvad-browser-bin 2>/dev/null || true)"

while IFS= read -r f; do
	case "$f" in
		*/mullvadbrowser|*/mullvadbrowser.real)
			MB_POL="$(dirname "$f")/distribution/policies.json"
			if [[ -f "$MB_POL" ]] && grep -q 'SearXNG on this PC' "$MB_POL"; then
				$SUDO rm -f "$MB_POL"
				note "removed the unused search policy from Mullvad Browser"
			fi
			break ;;
	esac
done <<< "$MB_FILES"



#    Flatpak


section "Flatpak"

run "add flathub" $SUDO flatpak remote-add --if-not-exists flathub \
	https://dl.flathub.org/repo/flathub.flatpakrepo

soft "freetube" $SUDO flatpak install -y --noninteractive flathub io.freetubeapp.FreeTube
soft "vesktop"  $SUDO flatpak install -y --noninteractive flathub dev.vencord.Vesktop

	# Ai - krita for drawing, and the comfyui plugin has a home to be added to
soft "krita"    $SUDO flatpak install -y --noninteractive flathub org.kde.krita

	# Ai - flatseal edits what each flatpak is allowed to touch
soft "flatseal" $SUDO flatpak install -y --noninteractive flathub com.github.tchx84.Flatseal


#    Bluetooth


section "Bluetooth"

	# Ai - HyDE turns the bluetooth service on, this machine has nothing that
	#      uses it, and a radio that is never used is only an open door
	#      nothing is removed, so one command brings it back:
	#      sudo systemctl enable --now bluetooth.service

if systemctl list-unit-files bluetooth.service &> /dev/null \
	&& systemctl is-enabled --quiet bluetooth.service 2>/dev/null; then
	soft "turn bluetooth off" $SUDO systemctl disable --now bluetooth.service
	note "bluetooth service off, it was on"
else
	note "bluetooth service already off"
fi

	# Ai - the tray applet starts itself from the desktop session, not systemd
for f in "$HOME/.config/autostart/blueman.desktop" \
	"$HOME/.config/autostart/blueman-applet.desktop"; do
	if [[ -f "$f" ]]; then
		mv "$f" "$f.disabled"
		note "stopped the bluetooth applet starting with the desktop"
	fi
done



#    Hyprland


section "Hyprland"


## Backup

mkdir -p "$(dirname "$LUA")"
touch "$LUA"
[[ -f "$LUA.bak-prefs" ]] || cp "$LUA" "$LUA.bak-prefs"


## Clear

sed -i '/^-- rebuild binds start$/,/^-- rebuild binds end$/d' "$LUA"


## Write

	# Ai - lua, because that is the file Hyprland reads on this machine

cat >> "$LUA" << 'LUAEOF'
-- rebuild binds start

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

hl.bind("SUPER + L", hl.dsp.exec_cmd("librewolf"), { description = "[Rebuild] librewolf" })

hl.window_rule({
	name = "rebuild-mullvad-nomax",
	match = { class = "^(Mullvad Browser)$" },
	suppress_event = "maximize",
})

hl.window_rule({
	name = "rebuild-mullvad",
	match = { class = "^(Mullvad Browser)$" },
	float = true,
	size = "1400 1000",
	center = true,
})

-- rebuild binds end
LUAEOF


## Reload

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	soft "reload hyprland" hyprctl reload
	hyde-shell keybinds_hint --reload &> /dev/null || true
else
	note "not inside Hyprland, binds apply at next login"
fi



#    Keyboard


section "Keyboard"

	# Ai - 30-desktop already wrote this, it is re-asserted here at the end of
	#      the file so nothing added in between can win
	#      in lua the last assignment is the one that counts

LUA="$HOME/.config/hypr/hyprland.lua"

mkdir -p "$(dirname "$LUA")"
touch "$LUA"

sed -i '/^-- rebuild keyboard start$/,/^-- rebuild keyboard end$/d' "$LUA"

cat >> "$LUA" << LUAEOF
-- rebuild keyboard start

hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "$KEYMAP"
  }
})

-- rebuild keyboard end
LUAEOF

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	soft "reload hyprland" hyprctl reload

	LIVE="$(capture hyprctl getoption input:kb_variant)"

	if contains "$LIVE" "$KEYMAP"; then
		pass "keyboard is $KEYMAP right now"
	else
		flag "Hyprland reports: $LIVE"
		flag "log out and back in, or type: kbfix"
	fi
else
	note "not in a session, layout applies at next login"
fi



#    Monitors


section "Monitors"

[[ -f "$MON" ]] || touch "$MON"
[[ -f "$MON.bak-prefs" ]] || cp "$MON" "$MON.bak-prefs"

sed -i '/^-- rebuild monitors start$/,/^-- rebuild monitors end$/d' "$MON"

	# Ai - transform 1 is 90 degrees, 3 is 270
	#      change ROTATE in ~/.install-config if the monitor moves again
cat >> "$MON" << MONEOF
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
	transform = ${ROTATE:-3},
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

	# Ai - left is 90 degrees, right is 270
ROTDIR=right
[[ "${ROTATE:-3}" == 1 ]] && ROTDIR=left

	# Ai - only ROTDIR is expanded here, everything else has to reach the file
	#      literally or the greeter script would run with an empty output name
$SUDO tee /etc/sddm/Xsetup-rebuild > /dev/null << XEOF
#!/bin/sh
OUT=\$(xrandr --query | awk '/ connected/{o=\$1} o!="" && /^ +1920x1080/ && /\\+/{print o; exit}')
[ -n "\$OUT" ] && xrandr --output "\$OUT" --rotate $ROTDIR
exit 0
XEOF

$SUDO chmod 755 /etc/sddm/Xsetup-rebuild

$SUDO tee /etc/sddm.conf.d/20-rebuild-rotate.conf > /dev/null << 'SEOF'
[X11]
DisplayCommand=/etc/sddm/Xsetup-rebuild
SEOF



#    Brightness


section "Brightness"

	# Ai - brightness follows the time of day and learns from your changes
	#      ddcutil talks to the monitors over DDC/CI, and ddcutil-service is how
	#      wluma reads them, raw reads came back garbled on this PC's NVIDIA card
	#      the time schedule stands in for a light sensor, which a desktop lacks

pac ddcutil

try_aur "ddcutil-service" ddcutil-service
try_aur "wluma" wluma

	# Ai - the kernel module DDC/CI goes through, loaded at every boot
printf 'i2c-dev\n' | $SUDO tee /etc/modules-load.d/i2c-dev.conf > /dev/null
soft "load i2c-dev" $SUDO modprobe i2c-dev


## Config

	# Ai - written only when missing, so tuning you do later is never replaced
	#      to carry your tuning into the next install, copy it into the repo:
	#      cp ~/.config/wluma/config.toml ~/Rebuild/configs/wluma.toml
WLUMA_CONF="$HOME/.config/wluma/config.toml"

if [[ -f "$WLUMA_CONF" ]]; then
	note "wluma config already there, left exactly as it is"
else
	mkdir -p "$(dirname "$WLUMA_CONF")"
	cp "$REPO/configs/wluma.toml" "$WLUMA_CONF"
	note "wluma config written, change the hours in it to match your day"
fi


## Service

	# Ai - starts with your session from now on
	#      a wluma already running by hand in a terminal should be closed first,
	#      two copies would fight over the same monitors
if command -v wluma > /dev/null; then
	soft "wluma at login" systemctl --user enable --now wluma.service
fi



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

	# Ai - this used to point at config, the directory is configs
	#      the block silently did nothing every single run
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
check "bluetooth off"      sh -c '! systemctl is-enabled --quiet bluetooth.service'
warn  "ddcutil"            command -v ddcutil
warn  "wluma"              command -v wluma
warn  "wluma config"       test -f "$HOME/.config/wluma/config.toml"
warn  "wluma at login"     systemctl --user is-enabled --quiet wluma.service
check "keyring present"    command -v gnome-keyring-daemon
check "binds block"        grep -q 'rebuild binds start' "$LUA"
check "block closed"       grep -q 'rebuild binds end' "$LUA"
check "block written once" sh -c "test \"\$(grep -c 'rebuild binds start' '$LUA')\" = 1"
check "keyboard in lua"    grep -q 'kb_variant' "$LUA"
check "monitors block"     grep -q 'rebuild monitors start' "$MON"
check "monitors once"      sh -c "test \"\$(grep -c 'rebuild monitors start' '$MON')\" = 1"
check "dolphin config"     test -f "$HOME/.config/dolphinrc"

warn  "codium"             command -v codium
warn  "1password"          command -v 1password
warn  "mullvad-browser"    command -v mullvad-browser
	# Ai - only when you asked for it, a skipped install is not a problem
if [[ "${WANT_LIBREWOLF:-yes}" == yes ]]; then
	warn  "librewolf"        command -v librewolf
fi
warn  "claude desktop"     command -v claude-desktop
warn  "freetube"           flatpak info io.freetubeapp.FreeTube
warn  "krita"              flatpak info org.kde.krita
warn  "flatseal"           flatpak info com.github.tchx84.Flatseal
warn  "places installed"   test -f "$HOME/.local/share/user-places.xbel"
warn  "greeter rotate"     test -x /etc/sddm/Xsetup-rebuild

verify_done

stage_done



#    End


section "End"

printf '  Preferences applied.\n'
printf '  SUPER + slash lists every keybind.\n\n'
