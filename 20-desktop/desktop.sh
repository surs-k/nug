#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"




# = =    Check     = = = = = = = =

set -Eeuo pipefail

require_stage 10-base



# = =    Firelink     = = = = = = =


mkdir -p ~/firelink
ln -sfn /var/lib/libvirt/images ~/firelink/vms
ln -sfn /var/lib/docker         ~/firelink/docker
ln -sfn /home/ai                ~/firelink/ai
ln -sfn /games                  ~/firelink/games


sudo chown "$USERNAME:$USERNAME" /games /home/ai




# = =    Nvidia     = = = = = = = =


if lspci | grep -qi nvidia; then
    sudo pacman -S --needed --noconfirm nvidia-open-dkms nvidia-utils linux-headers
    
    sudo sed -i 's/^MODULES=.*/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    
    sudo mkinitcpio -P
    
fi

# = =    HyDE     = = = = = = = =


sudo pacman -S --needed --noconfirm luarocks gobject-introspection
    # both discovered missing mid-install last time - pre-installed now

git clone --depth 1 https://github.com/HyDE-Project/HyDE ~/HyDE

cd ~/HyDE/Scripts

sudo pacman -S archlinux-keyring

./install.sh -n > /dev/tty 2>&1


# = =    Remove Chaotic     = =

    
read -rp "Remove chaotic-aur now? (y/N): " REMOVE_CHAOTIC
if [[ "$REMOVE_CHAOTIC" == "y" ]]; then
    sudo sed -i '/\[chaotic-aur\]/,+1d' /etc/pacman.conf
    sudo pacman -Rns --noconfirm chaotic-keyring chaotic-mirrorlist
    sudo pacman -Syu
fi


# = =    Keyboard     = = = = = =


if grep -q 'input = {' ~/.config/hypr/hyprland.lua 2>/dev/null; then
	sed -i '/input = {/a\		kb_variant = "colemak",' ~/.config/hypr/hyprland.lua
else
	echo "COLEMAK NOT APPLIED - patch hypr config by hand"
fi


sudo localectl --no-convert set-x11-keymap us pc105 colemak



# = =    End     = = = = = = = = = 

stage_done 20-desktop

echo "Reboot"
