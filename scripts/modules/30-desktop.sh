#!/usr/bin/env bash

# Ai - desktop: Hyprland with a small set of parts that each do one job,
#      a bar, a launcher, notifications, a lock screen and a login screen,
#      all dressed from one theme file, config/theme.env

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Desktop" "Hyprland, the bar, login, sound and the look"


step "Graphics"

	# Ai - read from sysfs, display controllers are PCI class 03
	#      0x10de is NVIDIA, 0x1002 AMD, 0x8086 Intel
VENDORS=""
for d in /sys/bus/pci/devices/*; do
	if [[ "$(cat "$d/class" 2> /dev/null)" == 0x03* ]]; then VENDORS+=" $(cat "$d/vendor" 2> /dev/null)"; fi
done

GPU_ENV="# Ai - no graphics settings needed for this card"
if [[ "$VENDORS" == *0x10de* ]]; then
	pac nvidia-utils lib32-nvidia-utils egl-wayland libva-nvidia-driver
	GPU_ENV='	# Ai - NVIDIA: its own video decoding and GL, for smooth video and streams
export LIBVA_DRIVER_NAME=nvidia
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct'
		# Ai - keeps the picture after sleep, the driver needs these to save it
	soft "NVIDIA sleep support" $SUDO systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume
elif [[ "$VENDORS" == *0x1002* ]]; then
	pac mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon
elif [[ "$VENDORS" == *0x8086* ]]; then
	pac mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver
else
	pac mesa
fi


step "Programs"

	# Ai - one program per job, nothing that duplicates another
pac hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent hyprlock hypridle
pac waybar mako fuzzel kitty libnotify grim slurp wl-clipboard
pac pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol
pac network-manager-applet dolphin ffmpegthumbs qt5-wayland qt6-wayland
pac papirus-icon-theme ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
	# Ai - the dark GTK theme has moved between the repos and the AUR, so either
any "dark GTK theme" adw-gtk-theme || true
pac greetd greetd-tuigreet

	# Ai - small commands the desktop calls: the power menu, the key list,
	#      screenshots and the problem badge on the bar
for c in nug-power nug-keys nug-shot nug-problems; do
	put "/usr/local/bin/$c" 755 < "$SCRIPTS/bin/$c"
done
ok "power menu, key list, screenshots, problem badge"


step "Your old desktop"

	# Ai - a kept home still has the old desktop's settings, HyDE's among
	#      them, they are moved aside once, never deleted, so nothing of the
	#      old look fights the new one
OLD_MARK="$HOME/.config/nug/old-desktop-moved"
if [[ -f "$OLD_MARK" ]]; then
	ok "already moved aside earlier"
else
	AWAY="$HOME/.config/before-nug-$(date +%F)"
	MOVED=()
	for d in hypr waybar mako fuzzel kitty rofi dunst swaync wlogout hyde hyprpanel; do
		if [[ -e "$HOME/.config/$d" ]]; then
			if (( DRY == 0 )); then mkdir -p "$AWAY"; mv "$HOME/.config/$d" "$AWAY/"; fi
			MOVED+=("$d")
		fi
	done
	if (( ${#MOVED[@]} )); then
		ok "moved to ~/.config/${AWAY##*/}: ${MOVED[*]}"
	else
		ok "nothing to move"
	fi
	if (( DRY == 0 )); then mkdir -p "${OLD_MARK%/*}"; date '+%F' > "$OLD_MARK"; fi
fi


step "Look and keys"

load_theme

	# Ai - every file is filled from the theme, and rewritten on every run, so
	#      a change in theme.env reaches all of them, a change made straight in
	#      one of these files is replaced, theme.env is the place for it
fill "$CONF/waybar/config.jsonc" | put_mine "$HOME/.config/waybar/config.jsonc"
fill "$CONF/waybar/style.css"    | put_mine "$HOME/.config/waybar/style.css"
fill "$CONF/mako/config"         | put_mine "$HOME/.config/mako/config"
fill "$CONF/fuzzel/fuzzel.ini"   | put_mine "$HOME/.config/fuzzel/fuzzel.ini"
fill "$CONF/kitty/kitty.conf"    | put_mine "$HOME/.config/kitty/kitty.conf"
fill "$CONF/hypr/hyprlock.conf"  | put_mine "$HOME/.config/hypr/hyprlock.conf"
fill "$CONF/hypr/hypridle.conf"  | put_mine "$HOME/.config/hypr/hypridle.conf"
ok "bar, notifications, launcher, terminal, lock screen"

	# Ai - GTK apps follow the dark theme, Qt apps follow GTK, see nug-session
for v in 3.0 4.0; do
	put_mine "$HOME/.config/gtk-$v/settings.ini" << EOF
[Settings]
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=$FONT_UI $FONT_SIZE
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF
done
quiet gsettings set org.gnome.desktop.interface color-scheme prefer-dark || true

	# Ai - Dolphin's places and view, only when you have none yet
if [[ ! -f "$HOME/.config/dolphinrc" ]]; then
	put_mine "$HOME/.config/dolphinrc" < "$CONF/dolphin/dolphinrc"
fi
if [[ ! -f "$HOME/.local/share/user-places.xbel" ]]; then
	sed "s/USERNAME/$USER/g" "$CONF/dolphin/user-places.xbel" | put_mine "$HOME/.local/share/user-places.xbel"
fi

run "Hyprland config" bash "$SCRIPTS/hypr.sh"


step "Login"

	# Ai - a plain text login screen, quick and reliable on any graphics card,
	#      it remembers you, and starts the desktop through nug-session
fill "$SCRIPTS/bin/nug-session" | put /usr/local/bin/nug-session 755
put /etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --greeting 'Welcome back' --cmd /usr/local/bin/nug-session"
user = "greeter"
EOF
run "login screen at start" $SUDO systemctl enable greetd

	# Ai - sound starts with you, from your next login
soft "sound at login" systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service


step "Check"

MISSING=()
for c in Hyprland waybar mako fuzzel kitty hyprlock hypridle tuigreet; do
	has "$c" || MISSING+=("$c")
done
if (( ${#MISSING[@]} )); then warn "missing: ${MISSING[*]}"; else ok "every desktop program is installed"; fi
if systemctl is-enabled --quiet greetd; then ok "login screen on"; else warn "the login screen is not enabled"; fi
todo "Restart. The login screen appears, then SUPER + / lists every key."
