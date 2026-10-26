#!/usr/bin/env bash

# Ai - recovery: three layers, each for a different kind of bad day
#        snapshots   the system, before every update and every hour,
#                    undo a bad update in a minute
#        daily       your data to the internal backup drive, for a dead disk
#        monthly     your data to the external drive, kept unplugged, for
#                    anything that could reach a plugged-in drive
#      plus copies of each disk's encryption header, without which a damaged
#      disk cannot be opened even with the right passphrase

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Recovery" "snapshots, daily backups, the backup command"


step "Snapshots"

	# Ai - snapper wants to make /.snapshots itself, inside @, where a rollback
	#      would delete it, so it is let make it, then its folder is swapped
	#      for the @snapshots subvolume the install made beside @
if [[ -f /etc/snapper/configs/root ]]; then
	ok "already set up"
else
	quiet $SUDO umount /.snapshots || true
	quiet $SUDO rm -rf /.snapshots
	run "snapshot settings" $SUDO snapper -c root create-config /
	quiet $SUDO btrfs subvolume delete /.snapshots
	quiet $SUDO mkdir -p /.snapshots
	run "use the @snapshots subvolume" $SUDO mount /.snapshots
fi
if (( DRY == 0 )); then
	findmnt -no SOURCE /.snapshots | grep -q '@snapshots' || die "/.snapshots is not the @snapshots subvolume"
fi
quiet $SUDO chmod 750 /.snapshots
quiet $SUDO chown root:wheel /.snapshots

	# Ai - a few hourly, a week of daily, a month of weekly, and the ones made
	#      around every update by snap-pac, the oldest go by themselves
run "how many to keep" $SUDO snapper -c root set-config \
	TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes \
	TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=4 \
	TIMELINE_LIMIT_MONTHLY=2 TIMELINE_LIMIT_YEARLY=0 \
	NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5 \
	ALLOW_GROUPS=wheel SYNC_ACL=yes
run "snapshot timers" $SUDO systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

	# Ai - a window for snapshots, to look through them and undo one
any "Btrfs Assistant" btrfs-assistant || true

	# Ai - undoing an update that stops the PC starting is done from the USB:
	#      bash ~/rebuild/scripts/rescue.sh, it swaps @ for a snapshot
soft "first snapshot" $SUDO snapper -c root create --description "nug setup" --cleanup-algorithm number


step "Daily backups"

pac btrbk

	# Ai - the data disk's own root, where btrbk keeps its snapshots
if (( DRY == 0 )) && ! mountpoint -q /mnt/data-root; then
	quiet $SUDO mount /mnt/data-root || die "the data disk root did not mount"
fi
quiet $SUDO mkdir -p /mnt/data-root/.btrbk

BACKUP=no
if grep -q ' /mnt/backup ' /etc/fstab; then
	BACKUP=yes
	if ! mountpoint -q /mnt/backup; then soft "mount the backup drive" $SUDO mount /mnt/backup; fi
	if ! mountpoint -q /mnt/backup; then BACKUP=no; fi
fi

	# Ai - written whole every run from these lines, never patched, so it is
	#      always exactly what is here
	#      snapshots stay 2 days at least, then daily for 2 weeks, weekly for 8,
	#      and monthly for 3, the monthly ones are what the external copy sends
	#      changes from, so it never has to send everything again
TARGET=""
if [[ "$BACKUP" == yes ]]; then TARGET="  target /mnt/backup"; fi
put /etc/btrbk/btrbk.conf << EOF
# Ai - written by rebuild recovery, change it in modules/40-recovery.sh
transaction_log        /var/log/btrbk.log
lockfile               /var/lock/btrbk.lock
timestamp_format       long
snapshot_dir           .btrbk
snapshot_preserve_min  2d
snapshot_preserve      14d 8w 3m
target_preserve_min    no
target_preserve        20d 10w 6m

volume /mnt/data-root
$TARGET
  subvolume @home
  subvolume @ai
  subvolume @vms
  subvolume @docker
  subvolume @persist
  subvolume @games/modding
EOF

	# Ai - the monthly copy sends what the daily one already snapshotted,
	#      it makes and deletes nothing on this PC
put /etc/btrbk/external.conf << 'EOF'
# Ai - written by rebuild recovery, used by: backup external
transaction_log        /var/log/btrbk-external.log
lockfile               /var/lock/btrbk.lock
timestamp_format       long
snapshot_dir           .btrbk
snapshot_create        no
snapshot_preserve_min  all
target_preserve_min    no
target_preserve        12m

volume /mnt/data-root
  target /mnt/external
  subvolume @home
  subvolume @ai
  subvolume @vms
  subvolume @docker
  subvolume @persist
  subvolume @games/modding
EOF

	# Ai - btrbk only runs with its drive mounted, without the drive it once
	#      wrote 220 GB into the empty folder on the system disk instead
	#      the folder is also made unwritable while nothing is mounted on it
	#      Persistent catches up a day missed while the PC was off
if [[ "$BACKUP" == yes ]]; then
	put /etc/systemd/system/btrbk.service.d/nug.conf << 'EOF'
[Unit]
RequiresMountsFor=/mnt/backup /mnt/data-root
EOF
	ok "backups need their drive, and never write without it"
fi
put /etc/systemd/system/btrbk.timer.d/nug.conf << 'EOF'
[Timer]
Persistent=true
EOF
if (( DRY == 0 )) && [[ -d /mnt/backup ]] && ! mountpoint -q /mnt/backup; then
	quiet $SUDO chattr +i /mnt/backup || true
fi
run "reload services" $SUDO systemctl daemon-reload
run "check the backup settings" $SUDO btrbk -n run
run "daily backups on" $SUDO systemctl enable --now btrbk.timer

if [[ "$BACKUP" == yes ]]; then
	run "first backup, only what changed" $SUDO btrbk run
else
	warn "no internal backup drive yet, your data is snapshotted but not copied anywhere"
	todo "Set up the backup drive:  backup setup
Then:  rebuild recovery"
fi


step "Disk headers"

	# Ai - a copy of each disk's header, kept on the data disk and the backup
	#      drive, the header is the small part that holds the keys, and a
	#      damaged one makes the whole disk unreadable
	#      the copies are root only, they can open the disk with an old
	#      passphrase, so they are refreshed every run
header() {
	local name=$1 dev
	dev="$($SUDO cryptsetup status "$name" 2> /dev/null | sed -n 's/^ *device: *//p')"
	[[ -n "$dev" ]] || return 0
	quiet $SUDO rm -f "/persist/headers/$name.img"
	run "save the $name header" $SUDO cryptsetup luksHeaderBackup "$dev" --header-backup-file "/persist/headers/$name.img"
	if [[ "$BACKUP" == yes ]]; then
		quiet $SUDO install -d -m 700 /mnt/backup/headers
		quiet $SUDO install -m 600 "/persist/headers/$name.img" "/mnt/backup/headers/$name.img"
	fi
	return 0
}
quiet $SUDO install -d -m 700 /persist/headers
for n in cryptsystem cryptdata backup; do header "$n"; done
if (( DRY == 0 )); then mkdir -p "$STATE"; date '+%F' > "$STATE/headers-saved"; fi


step "Backup command"

put /usr/local/bin/backup 755 < "$SCRIPTS/bin/backup"
quiet $SUDO install -d -m 755 /persist/state
ok "backup, backup now, backup external, backup test"

	# Ai - a nudge once a month, the external copy is the one that needs you
put_mine "$HOME/.config/systemd/user/nug-external.service" << 'EOF'
[Unit]
Description=Remind about the monthly external backup

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'f=/persist/state/external-last; if [ ! -f "$f" ] || [ $(( ($(date +%%s) - $(date -d "$(cat $f)" +%%s)) / 86400 )) -gt 30 ]; then notify-send -u critical -a Backup "Time for the monthly backup" "Plug in the external drive, then run: backup external"; fi'
EOF
put_mine "$HOME/.config/systemd/user/nug-external.timer" << 'EOF'
[Unit]
Description=Check weekly whether the monthly external backup is due

[Timer]
OnCalendar=Sun 12:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
soft "monthly reminder" systemctl --user enable nug-external.timer


step "Check"

if $SUDO snapper -c root list > /dev/null 2>&1; then ok "snapshots work"; else warn "snapper cannot list snapshots"; fi
if systemctl is-enabled --quiet btrbk.timer; then ok "daily backups on"; else warn "the daily backup timer is off"; fi
if [[ "$BACKUP" == yes ]]; then ok "backup drive mounted"; fi
todo "Once a month: plug in the external drive, run  backup external, unplug it."
