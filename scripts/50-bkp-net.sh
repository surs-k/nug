#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 30-security

for c in mullvad ufw snapper btrfs mountpoint yay; do
	command -v "$c" > /dev/null || { printf 'missing command: %s\n' "$c" >&2; exit 1; }
done



#    Resolver


section "Resolver"

	# Ai - this used to force resolv.conf at the systemd-resolved stub no matter
	#      what, but 30-security has already connected Mullvad by now, and
	#      Mullvad owns DNS inside its tunnel
	#      pointing resolv.conf somewhere else left resolved with an upstream the
	#      kill switch blocks, so name resolution died and the stage timed out
	#      when Mullvad is up it keeps DNS, and this only verifies it works

$SUDO mkdir -p /etc/NetworkManager/conf.d

$SUDO tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF

run "enable resolved" $SUDO systemctl enable --now systemd-resolved.service

MV="$(capture $SUDO mullvad status)"

if contains "$MV" "Connected"; then
	note "Mullvad is connected and owns DNS, leaving resolv.conf alone"
else
	note "Mullvad is not connected, pointing resolv.conf at resolved"
	$SUDO ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
	run "restart networkmanager" $SUDO systemctl restart NetworkManager.service
	run "restart resolved"       $SUDO systemctl restart systemd-resolved.service
fi


## Confirm

	# Ai - routing and name resolution are reported separately, because a stage
	#      that just says timeout tells you nothing about which half broke

if ! wait_for 60 resolves; then

	if routed; then
		flag "routing works but DNS does not"
		flag "Mullvad handles DNS in its tunnel, check: mullvad status"
		flag "then: resolvectl status"
	else
		flag "no route out at all, the VPN or the adapter is down"
		flag "check: mullvad status"
	fi

	printf '\n  DNS is required for the rest of this stage.\n' >&2
	printf '  Fix it, then run ./run.sh again.\n\n' >&2
	exit 1
fi

note "DNS working"



#    SSH


section "SSH"

$SUDO mkdir -p /etc/ssh/sshd_config.d

$SUDO tee /etc/ssh/sshd_config.d/10-harden.conf > /dev/null << 'EOF'
PermitRootLogin no
EOF

	# Ai - a key from the laptop replaces your password for SSH logins only
	#      the login screen and sudo on this PC keep using the password
	#      the firewall only opens SSH on the tailnet, so with Tailscale off
	#      nothing can reach it at all, see Guides/Network.md
if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
	printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
		| $SUDO tee -a /etc/ssh/sshd_config.d/10-harden.conf > /dev/null
	note "SSH takes keys only, passwords are refused"
else
	note "SSH still takes your password, no laptop key added yet"
fi

if ! ip link show tailscale0 &> /dev/null; then
	note "SSH is closed to the network until Tailscale is on"
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

	# Ai - snapshots in the boot menu, beside the normal entry
	#      the menu keeps its nested shape: an open Arch Linux folder with
	#      Linux first inside it, which is what starts on its own, then a
	#      Snapshots folder that stays closed until you open it
	#      limine-snapper-sync fills that folder and runs limine-header-fix
	#      after every save, which re-checks the menu still starts on its own


## Install

SNAPBOOT=no

if pacman -Qi limine-snapper-sync &> /dev/null; then
	SNAPBOOT=yes
	note "already installed"
else
		# Ai - the AUR name has a git variant, try both before giving up
		#      output goes to the log here, so any yay question would sit waiting
		#      where nobody can see it, the answer flags remove the questions
	for pkg in limine-snapper-sync limine-snapper-sync-git; do
		if yay -S --needed --noconfirm --answerdiff=None --answerclean=None \
			--answeredit=None --removemake "$pkg" >&3 2>&1; then
			SNAPBOOT=yes
			note "installed $pkg"
			break
		fi
		printf '  ..     %s did not build, trying the next name\n' "$pkg"
	done

	[[ "$SNAPBOOT" == yes ]] \
		|| flag "limine-snapper-sync would not build, snapshot boot entries skipped"
fi

	# Ai - the watcher that adds entries as snapshots appear is built on this,
	#      and it is only an optional dependency of the package
if [[ "$SNAPBOOT" == yes ]]; then
	pac inotify-tools
fi


## Defaults

	# Ai - read by limine-snapper-sync
	#      ROOT_SUBVOLUME_PATH has to match the cmdline spelling exactly, /@
	#      COMMANDS_BEFORE_SAVE is emptied, the packaged default can call a tool
	#      from limine-entry-tool, which is not installed here
	#      KERNEL_CMDLINE is copied from /etc/kernel/cmdline so the two cannot
	#      disagree, only limine-entry-tool reads it

if [[ "$SNAPBOOT" == yes ]]; then

	CMDLINE_NOW="$(tr -s '[:space:]' ' ' < /etc/kernel/cmdline)"
	CMDLINE_NOW="${CMDLINE_NOW% }"

	$SUDO tee /etc/default/limine > /dev/null << EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Arch Linux"
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=10
LIMIT_USAGE_PERCENT=80
KERNEL_CMDLINE[default]="$CMDLINE_NOW"
COMMANDS_BEFORE_SAVE=""
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

		# Ai - now that the sync tool is installed, the menu tool adds the empty
		#      Snapshots folder inside the Arch entry, after Linux, which is the
		#      one place the sync tool looks for it
	run "add snapshot folder" $SUDO /usr/local/bin/limine-header-fix

	soft "baseline snapshot" $SUDO snapper -c root create --description "rebuild baseline"

	soft "sync boot entries" $SUDO limine-snapper-sync

	soft "enable sync watcher" $SUDO systemctl enable --now limine-snapper-sync.service

		# Ai - the sync rewrote the file, so it is proven once more
		#      if this fails, do not reboot, Guides/Bootmenu.md has the way back
	run "check boot menu" $SUDO /usr/local/bin/limine-header-fix
fi



#    Homesnaps


section "Homesnaps"

	# Ai - root snapshots do not cover /home, it lives on the other disk
	#      btrbk snapshots @home and @ai in place, which costs almost nothing
	#      and is the difference between losing a file and losing an afternoon

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
	# Ai - rebuild managed
	#      snapshots only, on the same disk
	#      this is not a backup, it is an undo button
	#      for a real backup, plug in a second disk and fill in the target below

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

	# Ai - uncomment after mounting a second disk at /mnt/backup
	#volume /mnt/data-root
	#  subvolume @home
	#    target /mnt/backup/home
	#  subvolume @ai
	#    target /mnt/backup/ai
EOF
fi

$SUDO mkdir -p /mnt/data-root/.btrbk


## Timer

run "dry run btrbk" $SUDO btrbk -n run

run "enable daily snapshots" $SUDO systemctl enable --now btrbk.timer

	# Ai - one real run now, so the first undo point for /home exists today
	#      and the health report does not call backups broken on day one
soft "first home snapshot" $SUDO btrbk run



#    Verify


section "Verify"

check "resolved active"    systemctl is-active --quiet systemd-resolved
check "dns resolves"       resolves
check "sshd config valid"  $SUDO sshd -t
check "sshd active"        systemctl is-active --quiet sshd
check "snapper config"     test -f /etc/snapper/configs/root
check "snapshots mounted"  mountpoint -q /.snapshots
check "snapshots sibling"  sh -c 'findmnt -no SOURCE /.snapshots > /tmp/_s; grep -q "@snapshots" /tmp/_s'
check "snapshots listable" sh -c 'snapper -c root list > /dev/null'
check "timeline timer"     systemctl is-enabled --quiet snapper-timeline.timer
check "data root mounted"  mountpoint -q /mnt/data-root
check "btrbk timer"        systemctl is-enabled --quiet btrbk.timer
check "menu starts alone"  $SUDO /usr/local/bin/limine-header-fix --check
check "no stray conf"      sh -c '! test -f /boot/EFI/limine/limine.conf'
check "fstab / by name"    fstab_root_named /etc/fstab

	# Ai - entries three slashes deep are the snapshot entries themselves
snapshot_entries() {
	local n
	n="$(grep -Ec '^[[:space:]]*///' /boot/limine.conf || true)"
	(( ${n:-0} > 0 ))
}

if [[ "$SNAPBOOT" == yes ]]; then
	check "snapshot folder"  grep -Eq '^[[:space:]]*//[+]?Snapshots' /boot/limine.conf
	warn  "snapshot entries" snapshot_entries
	warn  "sync watcher"     systemctl is-active --quiet limine-snapper-sync.service
	warn  "restore tool"     command -v limine-snapper-restore
fi

verify_done

stage_done



#    End


section "End"

printf '  Backups and networking configured.\n'
printf '  Read Guides/Backups.md before you need it, not after.\n\n'
