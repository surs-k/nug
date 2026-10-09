#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Snapper


section "Snapper"

	# Ai - snap-pac takes a snapshot before and after every pacman run, so a bad
	#      update can be rolled back, and that is all this is for
	#      no hourly timeline, a USB SSD gains nothing from being written to once
	#      an hour, and the boot menu has no snapshot entries on this machine,
	#      a rollback from the installer USB is the way back if it ever will
	#      not boot


## Config

if [[ -f /etc/snapper/configs/root ]]; then
	note "root config already present"
else
	mountpoint -q /.snapshots && $SUDO umount /.snapshots
	$SUDO rm -rf /.snapshots
	run "create root config" $SUDO snapper -c root create-config /
		# Ai - snapper makes a nested .snapshots, we want the sibling instead
	soft "remove nested subvol" $SUDO btrfs subvolume delete /.snapshots
	$SUDO mkdir -p /.snapshots
fi


## Fstab

if grep -Eq '^[^#]*[[:space:]]/\.snapshots[[:space:]]' /etc/fstab; then
	note "/.snapshots already in fstab"
else
	SYS_UUID="$($SUDO blkid -s UUID -o value /dev/mapper/cryptsystem)"
	[[ -n "$SYS_UUID" ]] || { printf 'no cryptsystem UUID\n' >&2; exit 1; }

	$SUDO cp /etc/fstab /etc/fstab.bak-snapshots

	printf 'UUID=%s /.snapshots btrfs subvol=@snapshots,compress=zstd:1,noatime 0 0\n' "$SYS_UUID" \
		| $SUDO tee -a /etc/fstab > /dev/null

	note "added /.snapshots, backup at /etc/fstab.bak-snapshots"
fi

run "reload systemd" $SUDO systemctl daemon-reload

mountpoint -q /.snapshots || $SUDO mount /.snapshots

SNAP_SRC="$(capture findmnt -no SOURCE /.snapshots)"

contains "$SNAP_SRC" "[/@snapshots]" \
	|| { printf '/.snapshots is not @snapshots, got: %s\n' "$SNAP_SRC" >&2; exit 1; }

$SUDO chmod 750 /.snapshots
$SUDO chown root:wheel /.snapshots


## Retention

	# Ai - the last ten before and after pairs are kept, five of the important
	#      ones, and the cleanup timer enforces it
run "set retention" $SUDO snapper -c root set-config \
	TIMELINE_CREATE=no \
	NUMBER_CLEANUP=yes \
	NUMBER_LIMIT=10 \
	NUMBER_LIMIT_IMPORTANT=5 \
	ALLOW_GROUPS=wheel \
	SYNC_ACL=yes

run "enable cleanup timer" $SUDO systemctl enable --now snapper-cleanup.timer


## Baseline

soft "baseline snapshot" $SUDO snapper -c root create --description "rebuild baseline"



#    Verify


section "Verify"

snap_mounted() {
	local src
	src="$(capture findmnt -no SOURCE /.snapshots)"
	contains "$src" "[/@snapshots]"
}

check "root config"       test -f /etc/snapper/configs/root
check "snapshots mounted" snap_mounted
check "snap-pac"          pacman -Qq snap-pac
check "cleanup timer"     systemctl is-enabled --quiet snapper-cleanup.timer

verify_done

stage_done



#    End


section "End"

printf '  Snapshots are taken around every update.\n\n'
printf '  List them:  sudo snapper -c root list\n\n'
