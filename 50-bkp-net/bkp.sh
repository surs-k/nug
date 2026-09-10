#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 40-virt

for c in mullvad ufw snapper btrfs mountpoint yay; do
	command -v "$c" > /dev/null || { printf 'missing command: %s\n' "$c" >&2; exit 1; }
done



#    Resolver


section "Resolver"

$SUDO mkdir -p /etc/NetworkManager/conf.d

$SUDO tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF

run "enable resolved"  $SUDO systemctl enable --now systemd-resolved.service

$SUDO ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

run "restart networkmanager" $SUDO systemctl restart NetworkManager.service
run "restart resolved"       $SUDO systemctl restart systemd-resolved.service

wait_for 60 resolves



#    Tailscale


section "Tailscale"


## Install

pac tailscale inotify-tools


## Exclude

####### tailscale traffic has to leave outside the mullvad tunnel or the
####### kill switch drops it, mullvad-exclude puts the daemon in a cgroup
####### that is marked to bypass the tunnel

TS_UNIT=/usr/lib/systemd/system/tailscaled.service
TS_DROP=/etc/systemd/system/tailscaled.service.d/mullvad-exclude.conf

if command -v mullvad-exclude > /dev/null; then

	TS_EXEC="$(sed -n 's/^ExecStart=//p' "$TS_UNIT" | sed -n 1p)"
	[[ -n "$TS_EXEC" ]] || { printf 'No ExecStart in %s\n' "$TS_UNIT" >&2; exit 1; }

	$SUDO mkdir -p "$(dirname "$TS_DROP")"

	$SUDO tee "$TS_DROP" > /dev/null << EOF
[Unit]
After=mullvad-daemon.service
Wants=mullvad-daemon.service

[Service]
ExecStart=
ExecStart=$(command -v mullvad-exclude) ${TS_EXEC}
EOF

	run "reload systemd" $SUDO systemctl daemon-reload
else
	flag "mullvad-exclude absent, tailscaled will run inside the tunnel"
fi


## Daemon

run "enable tailscaled"  $SUDO systemctl enable tailscaled.service
run "restart tailscaled" $SUDO systemctl restart tailscaled.service

wait_for 30 test -S /run/tailscale/tailscaled.sock


## Up

tailnet_up() {
	local s
	s="$(capture tailscale status)"
	! contains "$s" "Logged out" && ! contains "$s" "Tailscale is stopped"
}

####### accept-dns stays off, magicdns fights systemd-resolved and mullvad
if tailnet_up; then
	note "already logged in"
	soft "keep dns local" $SUDO tailscale set --accept-dns=false
else
	printf '\n  A browser link prints below. Open it and approve this machine.\n\n'
	$SUDO tailscale up --accept-dns=false --timeout=300s
fi


## Firewall

if ip link show tailscale0 &> /dev/null; then
	soft "allow ssh on tailnet" $SUDO ufw allow in on tailscale0 to any port 22 proto tcp
else
	flag "tailscale0 absent, ssh rule not added"
fi



#    SSH


section "SSH"

$SUDO mkdir -p /etc/ssh/sshd_config.d

$SUDO tee /etc/ssh/sshd_config.d/10-harden.conf > /dev/null << 'EOF'
PermitRootLogin no
EOF

if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
	printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
		| $SUDO tee -a /etc/ssh/sshd_config.d/10-harden.conf > /dev/null
	note "key only auth enabled"
else
	flag "no authorized_keys yet, password auth left on"
fi

run "generate host keys" $SUDO ssh-keygen -A
run "test sshd config"   $SUDO sshd -t
run "enable sshd"        $SUDO systemctl enable --now sshd.service



#    Snapper


section "Snapper"


## Config

if [[ -f /etc/snapper/configs/root ]]; then
	note "root config already present"
else
	mountpoint -q /.snapshots && $SUDO umount /.snapshots
	$SUDO rm -rf /.snapshots
	run "create root config" $SUDO snapper -c root create-config /
	####### snapper makes a nested .snapshots, we want the sibling instead
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

run "set retention" $SUDO snapper -c root set-config \
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

run "enable timeline timer" $SUDO systemctl enable --now snapper-timeline.timer
run "enable cleanup timer"  $SUDO systemctl enable --now snapper-cleanup.timer



#    Snapboot


section "Snapboot"


## Install

SNAPBOOT=no

if pacman -Qi limine-snapper-sync &> /dev/null; then
	SNAPBOOT=yes
	note "already installed"
elif aur limine-snapper-sync; then
	SNAPBOOT=yes
else
	flag "limine-snapper-sync did not build, boot entry sync skipped"
fi


## Defaults

####### commands_after_save runs the header enforcer, which is what keeps
####### the boot menu from going back to waiting for a keypress every time
####### a snapshot is added

if [[ "$SNAPBOOT" == yes ]]; then

	LUKS_UUID="$($SUDO blkid -s UUID -o value /dev/disk/by-partlabel/cryptsystem)"
	[[ -n "$LUKS_UUID" ]] || { printf 'no cryptsystem UUID\n' >&2; exit 1; }

	$SUDO tee /etc/default/limine > /dev/null << EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Arch Linux"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=10
LIMIT_USAGE_PERCENT=80
KERNEL_CMDLINE[default]="rd.luks.name=$LUKS_UUID=cryptsystem root=/dev/mapper/cryptsystem rootflags=subvol=@ rw nvidia_drm.modeset=1"
COMMANDS_AFTER_SAVE="/usr/local/bin/limine-header-fix"
EOF
fi


## Sync

if [[ "$SNAPBOOT" == yes ]]; then

	for c in /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf; do
		if [[ -f "$c" ]]; then
			$SUDO mv "$c" "$c.disabled"
			flag "moved $c aside, it outranked /boot/limine.conf"
		fi
	done

	[[ -f /boot/limine.conf ]] \
		|| { printf '/boot/limine.conf missing, do not reboot\n' >&2; exit 1; }

	soft "baseline snapshot" $SUDO snapper -c root create --description "rebuild baseline"

	soft "sync boot entries" $SUDO limine-snapper-sync

	soft "enable sync watcher" $SUDO systemctl enable --now limine-snapper-sync.service

	####### re-assert the header in case the sync rewrote it
	run "restore auto start" $SUDO /usr/local/bin/limine-header-fix
fi



#    Homesnaps


section "Homesnaps"

####### root snapshots do not cover /home, it lives on the other disk
####### btrbk snapshots @home and @ai in place, which costs almost nothing
####### and is the difference between losing a file and losing an afternoon

pac btrbk

$SUDO mkdir -p /etc/btrbk /mnt/data-root


## Mount

if grep -q '/mnt/data-root' /etc/fstab; then
	note "data root already in fstab"
else
	DATA_UUID="$($SUDO blkid -s UUID -o value /dev/mapper/cryptdata)"
	[[ -n "$DATA_UUID" ]] || { printf 'no cryptdata UUID\n' >&2; exit 1; }

	$SUDO cp /etc/fstab /etc/fstab.bak-btrbk

	printf 'UUID=%s /mnt/data-root btrfs subvolid=5,noatime,nofail 0 0\n' "$DATA_UUID" \
		| $SUDO tee -a /etc/fstab > /dev/null

	run "reload systemd" $SUDO systemctl daemon-reload
fi

mountpoint -q /mnt/data-root || $SUDO mount /mnt/data-root


## Config

if [[ -f /etc/btrbk/btrbk.conf ]] && grep -q 'rebuild managed' /etc/btrbk/btrbk.conf; then
	note "btrbk.conf already managed"
else
	[[ -f /etc/btrbk/btrbk.conf ]] && $SUDO cp /etc/btrbk/btrbk.conf /etc/btrbk/btrbk.conf.bak-rebuild

	$SUDO tee /etc/btrbk/btrbk.conf > /dev/null << 'EOF'
####### rebuild managed
####### snapshots only, on the same disk
####### this is not a backup, it is an undo button
####### for a real backup, plug in a second disk and fill in the target below

transaction_log            /var/log/btrbk.log
lockfile                   /var/lock/btrbk.lock
timestamp_format           long

snapshot_preserve_min      2d
snapshot_preserve          14d 8w

target_preserve_min        no
target_preserve            20d 10w 6m

snapshot_dir               .btrbk

volume /mnt/data-root
  subvolume @home
  subvolume @ai

####### uncomment after mounting a second disk at /mnt/backup
####### volume /mnt/data-root
#######   subvolume @home
#######     target /mnt/backup/home
#######   subvolume @ai
#######     target /mnt/backup/ai
EOF
fi

$SUDO mkdir -p /mnt/data-root/.btrbk


## Timer

run "dry run btrbk" $SUDO btrbk -n run

run "enable daily snapshots" $SUDO systemctl enable --now btrbk.timer



#    Verify


section "Verify"

check "resolved active"    systemctl is-active --quiet systemd-resolved
check "dns resolves"       resolves
check "tailscaled active"  systemctl is-active --quiet tailscaled
check "tailnet up"         tailnet_up
check "sshd config valid"  $SUDO sshd -t
check "sshd active"        systemctl is-active --quiet sshd
check "snapper config"     test -f /etc/snapper/configs/root
check "snapshots mounted"  mountpoint -q /.snapshots
check "snapshots sibling"  sh -c 'findmnt -no SOURCE /.snapshots > /tmp/_s; grep -q "@snapshots" /tmp/_s'
check "snapshots listable" sh -c 'snapper -c root list > /dev/null'
check "timeline timer"     systemctl is-enabled --quiet snapper-timeline.timer
check "data root mounted"  mountpoint -q /mnt/data-root
check "btrbk timer"        systemctl is-enabled --quiet btrbk.timer
check "limine conf"        test -f /boot/limine.conf
check "auto start intact"  grep -q '^timeout:' /boot/limine.conf
check "no stray conf"      sh -c '! test -f /boot/EFI/limine/limine.conf'

warn  "tailscale excluded" sh -c 'systemctl show tailscaled -p ExecStart > /tmp/_ts; grep -q mullvad-exclude /tmp/_ts'
warn  "ufw tailscale rule" sh -c 'sudo ufw status > /tmp/_u; grep -q tailscale0 /tmp/_u'
warn  "snapshot entries"   sh -c 'limine-snapper-list > /dev/null'
warn  "restore tool"       command -v limine-snapper-restore

verify_done

stage_done



#    End


section "End"

printf '  Backups and networking configured.\n'
printf '  Read Guides/Backups.md before you need it, not after.\n\n'
