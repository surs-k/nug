#!/usr/bin/env bash

# Ai - gaming: Steam with Proton, a tool to add newer Proton builds, an
#      overlay for frame rate and temperatures, and GameMode, which gives a
#      running game the CPU's full attention

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Gaming" "Steam, Proton tools, MangoHud and GameMode"


step "Steam"

	# Ai - the 32-bit graphics drivers come from the desktop module
pac steam gamescope
ok "Steam, and gamescope for games that need their own screen"


step "Tools"

	# Ai - MangoHud is the overlay, SHIFT_R + F12 shows and hides it in a game
	#      GameMode is turned on per game, in Steam: gamemoderun %command%
pac mangohud lib32-mangohud gamemode lib32-gamemode
if getent group gamemode > /dev/null && ! id -nG "$USER" | tr ' ' '\n' | grep -qx gamemode; then
	run "allow GameMode to tune the CPU" $SUDO usermod -aG gamemode "$USER"
fi

	# Ai - ProtonPlus over ProtonUp-Qt: one small app that also covers Lutris
	#      and Heroic, should you add them, and keeps the builds up to date
has flatpak || pac flatpak
soft "Flathub" flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
if flatpak info com.vysp3r.ProtonPlus > /dev/null 2>&1; then
	ok "ProtonPlus already here"
else
	soft "ProtonPlus, newer Proton builds" flatpak install --user -y --noninteractive flathub com.vysp3r.ProtonPlus
fi


step "Games folder"

	# Ai - games live on the data disk in /games, so a reinstall keeps them,
	#      and mods have their own subvolume, /games/modding, which is backed up
if [[ -d /games ]]; then quiet $SUDO chown "$USER:$USER" /games; fi
if [[ -d /games/modding ]]; then quiet $SUDO chown "$USER:$USER" /games/modding; fi
todo "In Steam: Settings, Storage, add a drive: /games. Then set it as the default."


step "Check"

if has steam; then ok "Steam installed"; else warn "Steam is missing"; fi
if has mangohud; then ok "MangoHud installed"; else warn "MangoHud is missing"; fi
