#!/usr/bin/env bash

# Ai - prep, run once on the old install, before reinstalling with v2
#      it checks the PC is ready, and saves onto the data disk what lives on
#      the system disk and would be lost: the backup drive's key, the SSH
#      identity, the Tailscale device and the Mullvad login
#      it also keeps a read-only copy of the whole old system on the data disk
#      as @old-system, so after the reinstall rebuild compare can show what the
#      old system had that the new one lacks
#      it reads everything and writes only into the data disk

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


step "Copy of v1"

	# Ai - the whole old root, read only, on the data disk, so nothing in it is
	#      lost to the reinstall and nothing has to be remembered by hand
	#      a Btrfs root is sent as a snapshot, anything else is copied with rsync
	#      home, games, VMs and containers already live on the data disk, and
	#      the package cache and old snapshots only take room, so none of those
OLD="$ROOT/@old-system"
DONE="$P/state/old-system.done"
COPY=1
if $SUDO test -f "$DONE" && [[ -d "$OLD/etc" ]]; then
	ok "the copy of v1 is already there: $($SUDO cat "$DONE")"
	yesno "Copy again, so it has your latest changes?" n || COPY=0
fi

if (( COPY == 1 )); then
	dim "Counting what v1 holds, this takes a minute."
	USED="$($SUDO du -sxB1 / 2> /dev/null | cut -f1)"
	FREE="$(df -B1 --output=avail "$ROOT" | tail -n 1 | tr -d ' ')"
	NEED=$(( USED + USED / 20 + 2147483648 ))
	if (( FREE < NEED )); then
		READY=0
		printf '    %s✗%s v1 holds %s GB, the data disk has %s GB free, the copy needs %s GB\n' \
			"$C_BAD" "$C_0" "$(( USED / 1000000000 ))" "$(( FREE / 1000000000 ))" "$(( NEED / 1000000000 ))"
		dim "Free some room on the data disk, then run prep again."
	else
		ok "room for it: $(( USED / 1000000000 )) GB to copy, $(( FREE / 1000000000 )) GB free"

			# Ai - a copy that never finished carries no done mark, it is replaced
		if [[ -e "$OLD" ]]; then
			$SUDO btrfs subvolume show "$OLD" > /dev/null 2>&1 || die "$OLD is a plain folder, move it away and run prep again"
			quiet $SUDO rm -f "$DONE"
			run "remove the earlier copy" $SUDO btrfs subvolume delete "$OLD"
		fi
		quiet $SUDO rm -rf "$ROOT/.old-system-incoming"

		METHOD=rsync
		if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then
			SNAP=/.nug-prep-snapshot
			quiet $SUDO btrfs subvolume delete "$SNAP" || true
			if quiet $SUDO btrfs subvolume snapshot -r / "$SNAP"; then
				METHOD=btrfs
				quiet $SUDO install -d -m 755 "$ROOT/.old-system-incoming"
				run "copy v1 to the data disk" $SUDO bash -c \
					'set -o pipefail; btrfs send "$1" | btrfs receive "$2"' _ "$SNAP" "$ROOT/.old-system-incoming"
				run "name it @old-system" $SUDO mv "$ROOT/.old-system-incoming/${SNAP##*/}" "$OLD"
				quiet $SUDO rmdir "$ROOT/.old-system-incoming"
				soft "remove the temporary snapshot" $SUDO btrfs subvolume delete "$SNAP"
			else
				dim "v1's root could not be snapshotted, copying file by file instead"
			fi
		fi
		if [[ "$METHOD" == rsync ]]; then
			has rsync || die "rsync is missing on this PC, install it:  sudo pacman -S rsync"
			run "make @old-system" $SUDO btrfs subvolume create "$OLD"
			run "copy v1 to the data disk" $SUDO rsync -aHAXx --numeric-ids \
				--exclude=/home --exclude=/games --exclude=/mnt --exclude=/.snapshots \
				--exclude=/var/cache/pacman/pkg --exclude=/var/lib/libvirt/images --exclude=/var/lib/docker \
				--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp / "$OLD/"
			run "make the copy read only" $SUDO btrfs property set -ts "$OLD" ro true
		fi

		if [[ -d "$OLD/var/lib/pacman/local" ]]; then
			printf '%s %s\n' "$(date +%F)" "$METHOD" | put "$DONE"
			ok "v1 is saved on the data disk as @old-system, read only"
			todo "After the reinstall, rebuild compare shows what v1 had that v2 lacks."
		else
			READY=0
			printf '    %s✗%s the copy has no package list in it, so it cannot be compared\n' "$C_BAD" "$C_0"
		fi
	fi
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
