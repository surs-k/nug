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

####### lspci lives in pciutils, which was not installed until 60-uprefs
####### so this ran with no lspci at all, matched nothing, and quietly chose
####### mesa on a machine with an NVIDIA card in it
pac pciutils

####### sysfs is the fallback, 0x10de is NVIDIA's PCI vendor id
####### it needs no packages and cannot go missing
VENDORS="$(capture cat /sys/bus/pci/devices/*/vendor)"

####### capture then match
####### lspci | grep -q can take SIGPIPE and return 141, and under pipefail
####### that reads as failure, so the branch gets skipped exactly when it
####### should have run
PCI="$(capture lspci)"

if contains "$PCI" "NVIDIA" || contains "$PCI" "nVidia" || contains "$VENDORS" "0x10de"; then

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
	####### mesa is the open driver stack for Intel and AMD
	####### seeing this on a machine with an NVIDIA card means detection
	####### failed, not that the card is unsupported
	note "no NVIDIA card found, using mesa"
	note "if this machine has an NVIDIA card, stop and say so"
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

####### this used to only land in 60-uprefs, which runs after the reboot into
####### the desktop, so the first desktop boot was always qwerty
####### the console half also only wrote a config file, and the terminal you
####### were already sitting in never reloaded it, which is why reboot was
####### hard to type


## Console

####### localectl set-keymap was rewriting this file straight after we wrote
####### it, sometimes quoting the value, which is why the check failed
####### the file is the thing systemd actually reads, so it is written here
####### and localectl is only used for the x11 half, with no-convert so it
####### cannot touch the console side at all
printf 'KEYMAP=%s\n' "$KEYMAP" | $SUDO tee /etc/vconsole.conf > /dev/null

####### apply to the tty you are sitting in right now, not at the next boot
soft "apply console keymap" $SUDO loadkeys "$KEYMAP"

soft "set x11 keymap" $SUDO localectl --no-convert set-x11-keymap us pc105 "$KEYMAP"

####### the passphrase prompt at boot comes from the initramfs, which bakes
####### in vconsole.conf at build time
run "rebuild initramfs" $SUDO mkinitcpio -P


## Hyprland

LUA="$HOME/.config/hypr/hyprland.lua"

mkdir -p "$(dirname "$LUA")"
touch "$LUA"

[[ -f "$LUA.bak-keyboard" ]] || cp "$LUA" "$LUA.bak-keyboard"

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

note "colemak written for the desktop, active at next login"



#    Verify


section "Verify"

check "hyde config dir"   test -d "$HOME/.config/hypr"
check "hyprland present"  command -v Hyprland
check "firelink"          test -d "$HOME/firelink"
check "console keymap"    grep -q "$KEYMAP" /etc/vconsole.conf
check "desktop keymap"    grep -q 'kb_variant' "$HOME/.config/hypr/hyprland.lua"

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
