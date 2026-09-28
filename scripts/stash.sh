#!/usr/bin/env bash

	# Ai - stash
	#      run on the old install, right before a reinstall that keeps the
	#      data disk, it copies what lives on the system disk into your home,
	#      which is on the data disk and survives
	#      each stage puts its own part back when it finds it
	#      run it again any time, it replaces the last stash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"

stage_banner "stash" "save what lives on the system disk" "before a reinstall   $(date +%H:%M)"


#    Check


section "Check"

sudo_keepalive

$SUDO rm -rf "$STASH"
$SUDO install -d -m 700 "$STASH"

note "saving to $STASH"


#    Save


section "Save"


## Services

	# Ai - the service passwords, a fresh random one would lock the old
	#      databases on @docker out
for d in /srv/rebuild/stacks/*/; do
	[[ -f "$d.env" ]] || continue
	$SUDO install -D -m 600 "$d.env" "$STASH/stacks/$(basename "$d").env"
done

if $SUDO test -d "$STASH/stacks"; then
	pass "service secrets"
else
	info "no service secrets to save"
fi


## Vms

	# Ai - the disk images are on @vms, these are the machines that use them
if compgen -G '/etc/libvirt/qemu/*.xml' > /dev/null; then
	$SUDO install -d -m 700 "$STASH/libvirt"
	$SUDO cp -a /etc/libvirt/qemu/*.xml "$STASH/libvirt/"
	pass "VM definitions"
else
	info "no VMs to save"
fi


## Ssh

	# Ai - this PC's identity, so the laptop does not warn it changed
$SUDO install -d -m 700 "$STASH/ssh"
$SUDO cp -a /etc/ssh/ssh_host_* "$STASH/ssh/"
pass "SSH host keys"


## Mullvad

	# Ai - the login and this device, so it does not use up a new device slot
if $SUDO test -d /etc/mullvad-vpn; then
	$SUDO cp -a /etc/mullvad-vpn "$STASH/mullvad"
	pass "Mullvad login and settings"
else
	info "Mullvad not set up, nothing to save"
fi


## Backups

	# Ai - the backup drive's key and mount lines, and btrbk's config with
	#      its target, so daily backups carry on after the reinstall
if $SUDO test -f /etc/cryptsetup-keys.d/backup.key; then
	$SUDO install -d -m 700 "$STASH/backup"
	$SUDO cp -a /etc/cryptsetup-keys.d/backup.key "$STASH/backup/"
	grep '^backup ' /etc/crypttab | $SUDO tee "$STASH/backup/crypttab" > /dev/null || true
	grep ' /mnt/backup ' /etc/fstab | $SUDO tee "$STASH/backup/fstab" > /dev/null || true
	pass "backup drive key"
else
	info "no backup drive set up"
fi

if [[ -f /etc/btrbk/btrbk.conf ]]; then
	$SUDO cp -a /etc/btrbk/btrbk.conf "$STASH/btrbk.conf"
	pass "btrbk config"
fi


## Packages

	# Ai - everything installed on purpose, compared after the reinstall so
	#      the ones added by hand show up as a list
pacman -Qqe | $SUDO tee "$STASH/packages.txt" > /dev/null
pass "package list, $(wc -l < <($SUDO cat "$STASH/packages.txt")) packages"


## Hypr

	# Ai - HyDE's installer may overwrite this on the reinstall, 20-desktop
	#      compares and puts this copy back
if [[ -d "$HOME/.config/hypr" ]]; then
	$SUDO cp -a "$HOME/.config/hypr" "$STASH/hypr"
	pass "Hyprland config"
fi


#    End


section "End"

$SUDO du -sh "$STASH" | sed 's/^/  size   /'
printf '\n'
printf '  Stash saved. Reinstall now, and answer yes to keep the data disk.\n\n'
