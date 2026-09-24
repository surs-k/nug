#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Firelink


section "Firelink"

	# Ai - one folder of shortcuts to everything that lives off the root disk

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

	# Ai - lspci lives in pciutils, which was not installed until 60-uprefs
	#      so this ran with no lspci at all, matched nothing, and quietly chose
	#      mesa on a machine with an NVIDIA card in it
pac pciutils

	# Ai - sysfs is the fallback, 0x10de is NVIDIA's PCI vendor id
	#      it needs no packages and cannot go missing
VENDORS="$(capture cat /sys/bus/pci/devices/*/vendor)"

	# Ai - capture then match
	#      lspci | grep -q can take SIGPIPE and return 141, and under pipefail
	#      that reads as failure, so the branch gets skipped exactly when it
	#      should have run
PCI="$(capture lspci)"

if contains "$PCI" "NVIDIA" || contains "$PCI" "nVidia" || contains "$VENDORS" "0x10de"; then

	note "NVIDIA detected"

	pac nvidia-open-dkms nvidia-utils linux-headers

	$SUDO sed -i 's/^MODULES=.*/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
		/etc/mkinitcpio.conf

		# Ai - wayland compositors need this, and so does sunshine later
	if ! grep -q 'nvidia_drm.modeset=1' /etc/kernel/cmdline 2>/dev/null; then
		$SUDO sed -i 's/$/ nvidia_drm.modeset=1/' /etc/kernel/cmdline
		note "added nvidia_drm.modeset=1 to the kernel cmdline"
	fi

	run "rebuild initramfs" $SUDO mkinitcpio -P

		# Ai - save_cfg only writes the file, the Verify block below reads the
		#      variable, so on a first run it never saw yes and skipped the checks
	HAS_NVIDIA=yes
	save_cfg HAS_NVIDIA yes

else
		# Ai - mesa is the open driver stack for Intel and AMD
		#      seeing this on a machine with an NVIDIA card means detection
		#      failed, not that the card is unsupported
	note "no NVIDIA card found, using mesa"
	note "if this machine has an NVIDIA card, stop and say so"
	pac mesa vulkan-icd-loader
	HAS_NVIDIA=no
	save_cfg HAS_NVIDIA no
fi


## Menu

	# Ai - the cmdline only reaches the boot menu when the menu is rewritten
	#      before v7.0 that waited for 50-bkp-net, so the reboot right after
	#      this stage started the NVIDIA driver without modeset
run "update boot menu" $SUDO /usr/local/bin/limine-header-fix



#    Desktop


section "Desktop"


## Deps

	# Ai - both of these were found missing mid install before, so they go first
pac luarocks gobject-introspection archlinux-keyring


## Clone

if [[ -d "$HOME/HyDE" ]]; then
	note "HyDE already cloned"
else
	run "clone HyDE" git clone --depth 1 https://github.com/HyDE-Project/HyDE "$HOME/HyDE"
fi


## Install

	# Ai - this one stays loud, it is long and silence looks like a hang
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

	# Ai - hyprland.lua is what Hyprland actually reads on this machine
	#      it writes that file itself at first launch and then ignores
	#      hyprland.conf entirely, which is why every .conf edit did nothing
	#      the layout goes in the lua, and nothing here touches .conf again

LUA="$HOME/.config/hypr/hyprland.lua"

mkdir -p "$(dirname "$LUA")"


## Restore

	# Ai - an earlier version renamed this file aside, put it back as the base
if [[ ! -f "$LUA" && -f "$LUA.disabled" ]]; then
	mv "$LUA.disabled" "$LUA"
	note "restored hyprland.lua, an earlier version had moved it aside"
fi

touch "$LUA"


## Console

printf 'KEYMAP=%s\n' "$KEYMAP" | $SUDO tee /etc/vconsole.conf > /dev/null

soft "apply console keymap" $SUDO loadkeys "$KEYMAP"

soft "set x11 keymap" $SUDO localectl --no-convert set-x11-keymap us pc105 "$KEYMAP"

	# Ai - the passphrase prompt at boot comes from the initramfs
run "rebuild initramfs" $SUDO mkinitcpio -P


## Desktop

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

note "colemak written to hyprland.lua"


## Command

	# Ai - one short word to put the layout back
	#      when this breaks you cannot type, and every fix so far has been a
	#      paragraph of qwerty guesswork
$SUDO tee /usr/local/bin/kbfix > /dev/null << KBEOF
#!/usr/bin/env bash
set -euo pipefail

LUA="\$HOME/.config/hypr/hyprland.lua"

mkdir -p "\$(dirname "\$LUA")"
touch "\$LUA"

sed -i '/^-- rebuild keyboard start\$/,/^-- rebuild keyboard end\$/d' "\$LUA"

cat >> "\$LUA" << 'INNER'
-- rebuild keyboard start

hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "$KEYMAP"
  }
})

-- rebuild keyboard end
INNER

hyprctl reload 2>/dev/null || true

printf 'keyboard set to $KEYMAP\n'
printf 'if it did not take, log out and back in\n'
KBEOF

$SUDO chmod 755 /usr/local/bin/kbfix

note "if the layout ever breaks again, type: kbfix"


## Greeter

$SUDO mkdir -p /etc/sddm.conf.d/hypr

if [[ -f /etc/sddm.conf.d/hypr/sddm-hyprland.conf ]]; then
	grep -q kb_variant /etc/sddm.conf.d/hypr/sddm-hyprland.conf \
		|| $SUDO sed -i "/kb_layout/a\\    kb_variant = $KEYMAP" \
			/etc/sddm.conf.d/hypr/sddm-hyprland.conf
	note "login screen set to $KEYMAP"
fi


## Live

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	soft "reload hyprland" hyprctl reload
fi



#    Verify


section "Verify"

check "hyde config dir"   test -d "$HOME/.config/hypr"
check "hyprland present"  command -v Hyprland
check "firelink"          test -d "$HOME/firelink"
check "console keymap"    grep -q "$KEYMAP" /etc/vconsole.conf
check "lua keymap"        grep -q 'kb_variant' "$HOME/.config/hypr/hyprland.lua"
check "kbfix command"     test -x /usr/local/bin/kbfix

	# Ai - the file being right proves nothing, this asks hyprland itself
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	warn "layout live" sh -c "hyprctl getoption input:kb_variant | grep -q $KEYMAP"
fi

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
	check "nvidia driver"  pacman -Qq nvidia-open-dkms
	check "modeset in cmdline" grep -q 'nvidia_drm.modeset=1' /etc/kernel/cmdline
	check "modeset in menu"    grep -q 'nvidia_drm.modeset=1' /boot/limine.conf
fi

	# Ai - this stage ends in the one reboot of the run, so the menu is proven
	#      right before it rather than after
check "menu starts alone" $SUDO /usr/local/bin/limine-header-fix --check

warn  "sddm enabled"      systemctl is-enabled sddm

verify_done

stage_done



#    End


section "End"

printf '  Desktop installed.\n\n'
