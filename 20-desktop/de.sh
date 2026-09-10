#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Firelink


section "Firelink"

####### one folder of shortcuts to everything that lives off the root disk

mkdir -p "$HOME/firelink"

ln -sfn /var/lib/libvirt/images "$HOME/firelink/vms"
ln -sfn /var/lib/docker         "$HOME/firelink/docker"
ln -sfn /home/ai                "$HOME/firelink/ai"
ln -sfn /games                  "$HOME/firelink/games"

for d in /games /home/ai; do
	[[ -d "$d" ]] && $SUDO chown "$USERNAME:$USERNAME" "$d"
done



#    Graphics


section "Graphics"

####### capture then match
####### lspci | grep -q can take SIGPIPE and return 141, and under pipefail
####### that reads as failure, so the branch gets skipped exactly when it
####### should have run

PCI="$(capture lspci)"

if contains "$PCI" "NVIDIA" || contains "$PCI" "nVidia"; then

	note "NVIDIA detected"

	pac nvidia-open-dkms nvidia-utils linux-headers

	$SUDO sed -i 's/^MODULES=.*/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
		/etc/mkinitcpio.conf

	####### wayland compositors need this, and so does sunshine later
	if ! grep -q 'nvidia_drm.modeset=1' /etc/kernel/cmdline 2>/dev/null; then
		$SUDO sed -i 's/$/ nvidia_drm.modeset=1/' /etc/kernel/cmdline
		note "added nvidia_drm.modeset=1 to the kernel cmdline"
	fi

	run "rebuild initramfs" $SUDO mkinitcpio -P

	save_cfg HAS_NVIDIA yes

else
	note "no NVIDIA card, using mesa"
	pac mesa vulkan-icd-loader
	save_cfg HAS_NVIDIA no
fi



#    Desktop


section "Desktop"


## Deps

####### both of these were found missing mid install before, so they go first
pac luarocks gobject-introspection archlinux-keyring


## Clone

if [[ -d "$HOME/HyDE" ]]; then
	note "HyDE already cloned"
else
	run "clone HyDE" git clone --depth 1 https://github.com/HyDE-Project/HyDE "$HOME/HyDE"
fi


## Install

####### this one stays loud, it is long and silence looks like a hang
printf '\n  HyDE installer starts now. This takes a while.\n\n'

( cd "$HOME/HyDE/Scripts" && ./install.sh -n )



#    Repos


section "Repos"

if [[ "${WANT_CHAOTIC_REMOVE:-no}" == yes ]] && grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
	$SUDO sed -i '/\[chaotic-aur\]/,+1d' /etc/pacman.conf
	soft "remove chaotic keyring" $SUDO pacman -Rns --noconfirm chaotic-keyring chaotic-mirrorlist
	run  "resync repos" $SUDO pacman -Syu --noconfirm
else
	note "leaving chaotic-aur alone"
fi



#    Keyboard


section "Keyboard"

run "set console keymap" $SUDO localectl set-keymap "$KEYMAP"

run "set x11 keymap"     $SUDO localectl set-x11-keymap us pc105 "$KEYMAP"

####### the hyprland layout is written by 60-uprefs into its managed block



#    Verify


section "Verify"

check "hyde config dir"   test -d "$HOME/.config/hypr"
check "hyprland present"  command -v Hyprland
check "firelink"          test -d "$HOME/firelink"

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
	check "nvidia driver"  pacman -Qq nvidia-open-dkms
	check "modeset in cmdline" grep -q 'nvidia_drm.modeset=1' /etc/kernel/cmdline
fi

warn  "sddm enabled"      systemctl is-enabled sddm

verify_done

stage_done



#    End


section "End"

printf '  Desktop installed.\n\n'
