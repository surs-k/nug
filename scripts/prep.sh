#!/usr/bin/env bash

# Ai - prep, run once on the old install, before reinstalling with v2
#      it checks the PC is ready, and saves onto the data disk what lives on
#      the system disk and would be lost: the backup drive's key, the SSH
#      identity, the Tailscale device and the Mullvad login
#      it reads everything and writes only into the data disk's @persist

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

title "Prep" "ready the old install for a v2 reinstall"

ROOT=/mnt/data-root
P="$ROOT/@persist"
READY=1


step "Data disk"

if ! mountpoint -q "$ROOT"; then run "mount the data disk's root" $SUDO mount "$ROOT"; fi
mountpoint -q "$ROOT" || die "the data disk's root is not mounted at $ROOT"
if [[ ! -d "$P" ]]; then run "make @persist" $SUDO btrfs subvolume create "$P"; fi
quiet $SUDO install -d -m 755 "$P"
quiet $SUDO install -d -m 700 "$P/keys" "$P/ssh" "$P/headers"
quiet $SUDO install -d -m 755 "$P/tailscale" "$P/mullvad-vpn" "$P/state"
ok "@persist is ready on the data disk"

	# Ai - the one thing nothing can recover: the passphrase the data disk
	#      opens with, the reinstall asks for it, so it is proven here first
DATA_DEV="$($SUDO cryptsetup status cryptdata | sed -n 's/^ *device: *//p')"
[[ -n "$DATA_DEV" ]] || die "cannot find the data disk's encrypted partition"
dim "Type the data disk passphrase, the one the reinstall will ask for."
if $SUDO cryptsetup open --test-passphrase "$DATA_DEV" < /dev/tty; then
	ok "you know the data disk's passphrase"
else
	READY=0
	printf '    %s✗%s that passphrase does not open the data disk\n' "$C_BAD" "$C_0"
fi


step "Save settings"

	# Ai - the backup drive's key and which drive it is
if $SUDO test -s /etc/cryptsetup-keys.d/backup.key; then
	run "backup drive key" $SUDO install -m 600 /etc/cryptsetup-keys.d/backup.key "$P/keys/backup.key"
	UUID="$($SUDO sed -n 's/^backup[[:space:]]\+UUID=\([^[:space:]]*\).*/\1/p' /etc/crypttab | head -n 1)"
	if [[ -z "$UUID" ]]; then
		# Ai - the crypttab line went missing once, so every encrypted partition
		#      is tried with the key until one opens
		for dev in $($SUDO blkid -t TYPE=crypto_LUKS -o device); do
			$SUDO cryptsetup open --test-passphrase --key-file /etc/cryptsetup-keys.d/backup.key "$dev" 2> /dev/null || continue
			UUID="$($SUDO blkid -s UUID -o value "$dev")"
			break
		done
	fi
	if [[ -n "$UUID" ]]; then
		printf '%s\n' "$UUID" | put "$P/keys/backup.uuid" 600
		ok "the backup drive is found again after the reinstall"
	else
		warn "the backup drive's key is saved, but which drive it opens was not found"
	fi
else
	warn "no backup drive key on this PC, set one up after the reinstall: backup setup"
fi

	# Ai - the PC's SSH identity, so the laptop does not warn after the reinstall
run "SSH identity" $SUDO sh -c "cp -a /etc/ssh/ssh_host_* '$P/ssh/'"

	# Ai - the Tailscale device, so the PC keeps its name and is not added twice
if $SUDO test -d /var/lib/tailscale; then
	run "Tailscale device" $SUDO cp -a /var/lib/tailscale/. "$P/tailscale/"
else
	dim "no Tailscale here, skipped"
fi

	# Ai - the Mullvad login, so no new device slot is used
if $SUDO test -d /etc/mullvad-vpn; then
	run "Mullvad login" $SUDO cp -a /etc/mullvad-vpn/. "$P/mullvad-vpn/"
else
	dim "no Mullvad here, skipped"
fi

	# Ai - the VM definitions, the disks themselves are already on the data disk
if $SUDO sh -c 'ls /etc/libvirt/qemu/*.xml' > /dev/null 2>&1; then
	quiet $SUDO install -d -m 700 "$P/libvirt"
	run "VM definitions" $SUDO sh -c "cp -a /etc/libvirt/qemu/*.xml '$P/libvirt/'"
fi


step "Backups"

if mountpoint -q /mnt/backup; then
	NEWEST="$($SUDO sh -c 'ls -1d /mnt/backup/@home.* 2> /dev/null' | sort | tail -n 1)"
	if [[ -n "$NEWEST" ]]; then
		ok "newest daily backup: ${NEWEST##*@home.}"
	else
		READY=0
		warn "the backup drive has no backup of your home"
	fi
else
	READY=0
	warn "the backup drive is not mounted, back up before reinstalling"
fi
todo "Right before the reinstall, run one last backup:  sudo btrbk run"


step "Ready"

if (( READY == 1 )); then
	ok "ready for the v2 install"
	todo "Start the Arch USB, then follow the install steps you were given."
else
	printf '    %s✗%s not ready yet, fix what is marked above and run prep again\n' "$C_BAD" "$C_0"
fi
finish
