#!/usr/bin/env bash

# Ai - system: the package manager, the AUR, firmware updates and the small
#      jobs that keep the PC tidy by themselves

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "System" "packages, updates, swap and housekeeping"


step "Packages"

	# Ai - multilib holds the 32-bit parts Steam and Proton need
if ! grep -qs '^\[multilib\]' /etc/pacman.conf; then
	quiet $SUDO sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
	ok "32-bit packages on, for Steam"
fi
quiet $SUDO sed -i 's/^#Color$/Color/; s/^#VerbosePkgLists$/VerbosePkgLists/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
run "update everything" $SUDO pacman -Syu --noconfirm


step "Mirrors"

	# Ai - the fastest recent mirrors, ranked again every week by a timer
put /etc/xdg/reflector/reflector.conf << 'CONF'
--save /etc/pacman.d/mirrorlist
--protocol https
--latest 15
--age 12
--sort rate
CONF
run "rank mirrors weekly" $SUDO systemctl enable reflector.timer


step "AUR"

	# Ai - yay builds the few apps that are not in the Arch repos
	#      the prebuilt yay-bin, so it does not need Go to build itself
if has yay; then
	ok "yay already installed"
else
	BUILD="$(mktemp -d)"
	run "fetch yay" git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$BUILD/yay-bin"
	run "build yay" bash -c "cd '$BUILD/yay-bin' && makepkg -si --noconfirm"
	rm -rf "$BUILD"
fi


step "Firmware"

	# Ai - fwupd fetches firmware updates for disks, the mouse and the like,
	#      it never installs one without you, it only says one is waiting
pac fwupd
soft "check for firmware weekly" $SUDO systemctl enable fwupd-refresh.timer


step "Housekeeping"

	# Ai - logs are capped, so they never fill the disk
put /etc/systemd/journald.conf.d/size.conf << 'CONF'
[Journal]
SystemMaxUse=500M
CONF

	# Ai - the package cache keeps the last three versions of everything,
	#      enough to step back after a bad update
	#      orphaned packages are not removed by themselves, a wrong guess there
	#      removes something you use, Changes lists them for you instead
soft "cache trim weekly" $SUDO systemctl enable paccache.timer
soft "SSD trim weekly" $SUDO systemctl enable fstrim.timer


step "Check"

if has yay; then ok "AUR builds work"; else warn "yay is missing"; fi
if grep -qs '^\[multilib\]' /etc/pacman.conf; then ok "32-bit packages on"; else warn "multilib is off"; fi
if systemctl is-enabled --quiet reflector.timer; then ok "mirrors ranked weekly"; else warn "the mirror timer is off"; fi
