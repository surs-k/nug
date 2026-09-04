#!/usr/bin/env bash


set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


## Stage

require_stage 40-virt


## Tools

command -v yay >/dev/null || { echo "yay missing - rerun 10-base" >&2; exit 1; }

for c in mullvad ufw snapper btrfs mountpoint; do
	command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }
done


## Mullvad

MV_STATE="$(mullvad status 2>&1 || true)"

if [[ "$MV_STATE" == *Connected* ]]; then
	echo "mullvad connected"
else
	echo "mullvad NOT connected - tailscale will still be configured" >&2
fi



#    Resolver


## Backend

sudo mkdir -p /etc/NetworkManager/conf.d

sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF


## Service

sudo systemctl enable --now systemd-resolved.service

sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf


## Reload

if systemctl cat NetworkManager.service &>/dev/null; then
	sudo systemctl restart NetworkManager.service
fi

sudo systemctl restart systemd-resolved.service


## Test

wait_for 60 getent hosts archlinux.org



#    Tailscale


## Install

sudo pacman -S --needed --noconfirm tailscale inotify-tools


## Exclude

TS_UNIT=/usr/lib/systemd/system/tailscaled.service
TS_DROP=/etc/systemd/system/tailscaled.service.d/mullvad-exclude.conf

if command -v mullvad-exclude >/dev/null; then

	TS_EXEC="$(sed -n 's/^ExecStart=//p' "$TS_UNIT" | sed -n 1p)"
	[[ -n "$TS_EXEC" ]] || { echo "No ExecStart in $TS_UNIT" >&2; exit 1; }

	sudo mkdir -p "$(dirname "$TS_DROP")"

	sudo tee "$TS_DROP" > /dev/null << EOF
[Unit]
After=mullvad-daemon.service
Wants=mullvad-daemon.service

[Service]
ExecStart=
ExecStart=$(command -v mullvad-exclude) ${TS_EXEC}
EOF

	sudo systemctl daemon-reload

else
	echo "mullvad-exclude absent - tailscaled will run unwrapped" >&2
fi


## Daemon

sudo systemctl enable tailscaled.service

sudo systemctl restart tailscaled.service

wait_for 30 test -S /run/tailscale/tailscaled.sock


## Up

tailnet_up() {
	local s
	s="$(tailscale status 2>&1 || true)"
	[[ "$s" != *"Logged out"* && "$s" != *"Tailscale is stopped"* ]]
}

if tailnet_up; then
	echo "tailscale already logged in"
	sudo tailscale set --accept-dns=false
else
	echo "Browser login needed - the URL prints on the terminal"
	sudo tailscale up --accept-dns=false --timeout=300s > /dev/tty 2>&1
fi


## Firewall

if ip link show tailscale0 &>/dev/null; then
	sudo ufw allow in on tailscale0 to any port 22 proto tcp
else
	echo "tailscale0 absent - SSH rule not added" >&2
fi



#    SSH


## Harden

sudo mkdir -p /etc/ssh/sshd_config.d

sudo tee /etc/ssh/sshd_config.d/10-harden.conf > /dev/null << 'EOF'
PermitRootLogin no
EOF

if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
	printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
		| sudo tee -a /etc/ssh/sshd_config.d/10-harden.conf > /dev/null
else
	echo "no authorized_keys - password auth left enabled"
fi


## Start

sudo ssh-keygen -A

sudo sshd -t

sudo systemctl enable --now sshd.service

sudo systemctl try-reload-or-restart sshd.service



#    Snapper


## Config

if [[ -f /etc/snapper/configs/root ]]; then

	echo "snapper root config already set"

else
	mountpoint -q /.snapshots && sudo umount /.snapshots

	sudo rm -rf /.snapshots

	sudo snapper -c root create-config /

	sudo btrfs subvolume delete /.snapshots

	sudo mkdir -p /.snapshots
fi


## Fstab

SNAP_RE='^[^#]*[[:space:]]/\.snapshots[[:space:]]'

if grep -Eq "$SNAP_RE" /etc/fstab; then

	echo "/.snapshots already in fstab"

else
	SYS_UUID="$(sudo blkid -s UUID -o value /dev/mapper/cryptsystem)"
	[[ -n "$SYS_UUID" ]] || { echo "no cryptsystem UUID" >&2; exit 1; }

	sudo cp /etc/fstab /etc/fstab.bak-snapshots

	echo "UUID=$SYS_UUID /.snapshots btrfs subvol=@snapshots,compress=zstd:1,noatime 0 0" \
		| sudo tee -a /etc/fstab > /dev/null

	echo "added /.snapshots to fstab - backup at /etc/fstab.bak-snapshots"
fi

sudo systemctl daemon-reload

mountpoint -q /.snapshots || sudo mount /.snapshots


## Subvol

SNAP_SRC="$(findmnt -no SOURCE /.snapshots || true)"

[[ "$SNAP_SRC" == *"[/@snapshots]"* ]] \
	|| { echo "/.snapshots is not @snapshots - got: $SNAP_SRC" >&2; exit 1; }

sudo chmod 750 /.snapshots

sudo chown root:wheel /.snapshots


## Retention

sudo snapper -c root set-config \
	TIMELINE_CREATE=yes \
	TIMELINE_CLEANUP=yes \
	TIMELINE_LIMIT_HOURLY=5 \
	TIMELINE_LIMIT_DAILY=7 \
	TIMELINE_LIMIT_WEEKLY=4 \
	TIMELINE_LIMIT_MONTHLY=2 \
	TIMELINE_LIMIT_YEARLY=0 \
	NUMBER_LIMIT=10 \
	NUMBER_LIMIT_IMPORTANT=5 \
	ALLOW_GROUPS=wheel \
	SYNC_ACL=yes


## Timers

sudo systemctl enable --now snapper-timeline.timer

sudo systemctl enable --now snapper-cleanup.timer



#    Snapboot


## Install

SNAPBOOT=no

if pacman -Qi limine-snapper-sync &>/dev/null; then
	SNAPBOOT=yes
elif yay -S --needed --noconfirm limine-snapper-sync; then
	SNAPBOOT=yes
else
	echo "limine-snapper-sync did not build - boot entry sync skipped" >&2
fi


## Defaults

if [[ "$SNAPBOOT" == yes ]]; then

	LUKS_UUID="$(sudo blkid -s UUID -o value /dev/disk/by-partlabel/cryptsystem)"
	[[ -n "$LUKS_UUID" ]] || { echo "no cryptsystem UUID" >&2; exit 1; }

	sudo tee /etc/default/limine > /dev/null << EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Arch Linux"
SNAPPER_CONFIG_NAME="root"
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=10
LIMIT_USAGE_PERCENT=80
KERNEL_CMDLINE[default]="rd.luks.name=$LUKS_UUID=cryptsystem root=/dev/mapper/cryptsystem rootflags=subvol=@ rw"
EOF
fi


## Sync

if [[ "$SNAPBOOT" == yes ]]; then

	if [[ -f /boot/EFI/limine/limine.conf ]]; then
		sudo mv /boot/EFI/limine/limine.conf /boot/EFI/limine/limine.conf.off
		echo "moved /boot/EFI/limine/limine.conf aside - it outranks /boot/limine.conf"
	fi

	[[ -f /boot/limine.conf ]] \
		|| { echo "/boot/limine.conf missing - do not reboot" >&2; exit 1; }

	sudo snapper -c root create --description "stage 50 baseline"

	sudo limine-snapper-sync || echo "limine-snapper-sync reported errors" >&2

	sudo systemctl enable --now limine-snapper-sync.service \
		|| echo "limine-snapper-sync.service did not start" >&2
fi



#    btrbk


## Install

sudo pacman -S --needed --noconfirm btrbk

sudo mkdir -p /etc/btrbk


## Config

if [[ -f /etc/btrbk/btrbk.conf ]]; then

	echo "btrbk.conf already present"

else
	sudo tee /etc/btrbk/btrbk.conf > /dev/null << 'EOF'
####### Stub only. No volume is defined, so btrbk run is a no-op.
####### Fill this in once 45-backup-disk mounts the internal HDD.
#######
####### snapshot_preserve_min   2d
####### snapshot_preserve       14d
####### target_preserve_min     no
####### target_preserve         20d 10w
#######
####### volume /
#######   subvolume @
#######     target /mnt/backup/machineherald
EOF
fi



#    Verify


echo "VERIFY"
echo


check "resolved active"     systemctl is-active --quiet systemd-resolved

check "resolv.conf stub"    sh -c '[ "$(readlink -f /etc/resolv.conf)" = /run/systemd/resolve/stub-resolv.conf ]'

check "dns resolves"        getent hosts archlinux.org

check "tailscaled active"   systemctl is-active --quiet tailscaled

check "tailscale excluded"  sh -c 'systemctl show tailscaled -p ExecStart | grep -q mullvad-exclude'

check "tailnet up"          tailnet_up

check "ufw tailscale rule"  sh -c 'sudo ufw status | grep -q tailscale0'

check "sshd config valid"   sudo sshd -t

check "sshd active"         systemctl is-active --quiet sshd

check "snapper config"      test -f /etc/snapper/configs/root

check "snapshots mounted"   mountpoint -q /.snapshots

check "snapshots is sibling" sh -c 'findmnt -no SOURCE /.snapshots | grep -q "@snapshots"'

check "snapshots listable"  sh -c 'snapper -c root list >/dev/null'

check "timeline timer"      systemctl is-enabled --quiet snapper-timeline.timer

check "cleanup timer"       systemctl is-enabled --quiet snapper-cleanup.timer

check "btrbk installed"     command -v btrbk

check "inotifywait present" command -v inotifywait

check "limine conf on esp"  test -f /boot/limine.conf

check "no efi conf override" sh -c '! test -f /boot/EFI/limine/limine.conf'

warn  "snapshot entries"    sh -c 'limine-snapper-list | grep -q .'

warn  "sync watcher active" systemctl is-active --quiet limine-snapper-sync

warn  "restore tool"        command -v limine-snapper-restore

verify_done



#    End


stage_done 50-backup-net

echo
echo "REBOOT"
echo
echo "Then rerun this stage - every block is idempotent"
echo
echo "Rollback: boot a Snapshots entry, then run limine-snapper-restore"
echo "Manual fallback is in Rollback.md"
echo
