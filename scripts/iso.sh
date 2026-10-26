#!/usr/bin/env bash

# Ai - iso
#      run from the Arch ISO, it turns the system disk into a working,
#      encrypted Arch install and keeps your data disk
#      every question comes first, then one plan screen, then it runs alone
#
#      bash iso.sh             install
#      bash iso.sh --dry-run   show every step and every file, change nothing

[[ "${1:-}" == --dry-run ]] && export DRY=1

LOG=/tmp/nug-install.log
export LOG

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

T=/mnt
KEY=/run/nug.key

title "Install" "from the Arch ISO onto this PC"


#    Look

step "Check the PC"

[[ "$(cat /sys/firmware/efi/fw_platform_size 2> /dev/null || true)" == 64 ]] \
	|| die "this PC did not start in 64-bit UEFI mode, start the USB in UEFI mode"
ok "started in UEFI mode"

(( EUID == 0 )) || die "run it as root, the Arch ISO already is"

	# Ai - a stopped earlier attempt leaves /mnt mounted and the disks open,
	#      and the retry would fail on busy devices instead of starting over
if (( DRY == 0 )); then
	if mountpoint -q "$T"; then umount -R "$T"; fi
	for m in cryptsystem cryptdata nugpeek; do
		if [[ -e "/dev/mapper/$m" ]]; then cryptsetup close "$m" 2> /dev/null || true; fi
	done
fi

quiet loadkeys "$KEYMAP" || true
quiet timedatectl set-ntp true || true

wait_for 20 online || die "no internet, connect first (iwctl for Wi-Fi), then run this again"
ok "online"

	# Ai - the hardware decides a few packages, read from sysfs so no tool is needed
GPU=other
for d in /sys/bus/pci/devices/*; do
	[[ "$(cat "$d/class" 2> /dev/null)" == 0x03* ]] || continue
	if [[ "$(cat "$d/vendor" 2> /dev/null)" == 0x10de ]]; then GPU=nvidia; fi
done
UCODE=intel-ucode
if grep -q AuthenticAMD /proc/cpuinfo; then UCODE=amd-ucode; fi
VM=""
if systemd-detect-virt -q 2> /dev/null; then VM=", in a VM"; fi
ok "graphics: $GPU, processor: ${UCODE%-ucode}$VM"


#    Questions

step "Questions"

dim "Everything you type is here. After the plan screen it runs on its own."
printf '\n'

## Disks

	# Ai - the USB the ISO started from is never offered
BOOT_DEV="$(findmnt -no SOURCE /run/archiso/bootmnt 2> /dev/null || true)"
USB_DISK="none"
if [[ -n "$BOOT_DEV" ]]; then USB_DISK="/dev/$(lsblk -no PKNAME "$BOOT_DEV" 2> /dev/null | head -n 1)"; fi

mapfile -t DISKS < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}' | grep -v -e '^/dev/zram' -e '^/dev/loop' | grep -vx "$USB_DISK" || true)
(( ${#DISKS[@]} >= 2 )) || die "this needs two disks, a system disk and a data disk, found ${#DISKS[@]}"

	# Ai - what is on each disk, in words, so the right one is easy to spot
holds() {
	local labels
	labels="$(lsblk -nro PARTLABEL,FSTYPE "$1" 2> /dev/null | tr '\n' ' ')"
	case "$labels" in
		*cryptdata*)   printf 'your data, encrypted' ;;
		*cryptsystem*) printf 'the old system' ;;
		*crypto_LUKS*) printf 'something encrypted, maybe a backup' ;;
		*[a-z]*)       lsblk -nro FSTYPE "$1" | sort -u | grep . | tr '\n' ' ' ;;
		*)             printf 'empty' ;;
	esac
}

SYS_GUESS="" DATA_GUESS=""
for d in "${DISKS[@]}"; do
	if lsblk -nro PARTLABEL "$d" | grep -qx cryptdata; then DATA_GUESS="$d"; fi
	if lsblk -nro PARTLABEL "$d" | grep -qx cryptsystem; then SYS_GUESS="$d"; fi
done
	# Ai - with no old system, the smallest disk that is not the data disk
if [[ -z "$SYS_GUESS" ]]; then
	SYS_GUESS="$(for d in "${DISKS[@]}"; do
		[[ "$d" == "$DATA_GUESS" ]] || printf '%s %s\n' "$(lsblk -dnbo SIZE "$d")" "$d"
	done | sort -n | head -n 1 | cut -d' ' -f2)"
fi

printf '    %s#  %-14s %-7s %-5s %-24s %s%s\n' "$C_DIM" "Disk" "Size" "Type" "Model" "Holds" "$C_0"
i=1
for d in "${DISKS[@]}"; do
	printf '    %s  %-14s %-7s %-5s %-24.24s %s\n' "$i" "$d" "$(lsblk -dno SIZE "$d" | tr -d ' ')" \
		"$(lsblk -dno TRAN "$d" | tr -d ' ')" "$(lsblk -dno MODEL "$d" | sed 's/ *$//')" "$(holds "$d")"
	i=$(( i + 1 ))
done
printf '\n'

pick_disk() {
	local q=$1 def=$2 a d
	while true; do
		a="$(ask "$q" "$def")"
		if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#DISKS[@]} )); then a="${DISKS[a-1]}"; fi
		[[ "$a" == /dev/* ]] || a="/dev/$a"
		for d in "${DISKS[@]}"; do
			if [[ "$d" == "$a" ]]; then printf '%s' "$a"; return 0; fi
		done
		printf '      pick a number or a name from the list\n' > /dev/tty
	done
}

while true; do
	SYSTEM_DISK="$(pick_disk "System disk, erased" "$SYS_GUESS")"
	DATA_DISK="$(pick_disk "Data disk" "$DATA_GUESS")"
	[[ "$SYSTEM_DISK" != "$DATA_DISK" ]] && break
	printf '      those are the same disk, pick two different ones\n' > /dev/tty
done

DATA_PART="$(partname "$DATA_DISK" 1)"

	# Ai - keeping is the default whenever the data disk is one of ours,
	#      erasing it has to be asked for on purpose
if cryptsetup isLuks "$DATA_PART" 2> /dev/null; then
	if yesno "Keep the data disk as it is (your files, settings and games)" y; then
		KEEP_DATA=yes
	else
		KEEP_DATA=no
	fi
else
	say "$DATA_DISK has no encrypted data on it yet, it will be set up new"
	KEEP_DATA=no
fi

## Passphrase

printf '\n'
if [[ "$KEEP_DATA" == yes ]]; then
	dim "The disk passphrase is the one your data disk already has."
	dim "The new system disk gets the same one."
	while true; do
		LUKS_PASS="$(secret "Disk passphrase")"
		( umask 077; printf '%s' "$LUKS_PASS" > "$KEY" )
		cryptsetup open --test-passphrase --key-file "$KEY" "$DATA_PART" 2> /dev/null && break
		printf '      that does not open the data disk, once more\n' > /dev/tty
	done
	ok "the passphrase opens your data disk"
else
	dim "One disk passphrase unlocks both disks. You type it at every start."
	LUKS_PASS="$(secret_twice "Disk passphrase")"
	( umask 077; printf '%s' "$LUKS_PASS" > "$KEY" )
fi
unset LUKS_PASS

	# Ai - a look inside the kept disk, read only, for smart defaults: who you
	#      are, and the settings saved there for the next install
PEEK=/tmp/nug-peek
HOMES=() PERSIST=no BACKUP_UUID=""
if [[ "$KEEP_DATA" == yes ]]; then
	cryptsetup open --readonly --key-file "$KEY" "$DATA_PART" nugpeek
	mkdir -p "$PEEK"
	if mount -o ro,subvolid=5 /dev/mapper/nugpeek "$PEEK" 2> /dev/null; then
		for h in "$PEEK"/@home/*/; do
			h="${h%/}"
			[[ "${h##*/}" == ai || "${h##*/}" == lost+found ]] || HOMES+=("${h##*/}")
		done
		if [[ -d "$PEEK/@persist" ]]; then PERSIST=yes; fi
		BACKUP_UUID="$(cat "$PEEK/@persist/keys/backup.uuid" 2> /dev/null || true)"
		umount "$PEEK"
	fi
	cryptsetup close nugpeek
fi

## Names

printf '\n'
HOSTNAME_NEW="$(ask "Name for this PC" "$HOSTNAME_DEFAULT")"
USER_DEF=""
if (( ${#HOMES[@]} == 1 )); then USER_DEF="${HOMES[0]}"; fi
while true; do
	USERNAME="$(ask "Your username" "$USER_DEF")"
	[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
	printf '      lowercase letters, numbers, - and _ only\n' > /dev/tty
done
USER_PASS="$(secret_twice "Password for $USERNAME")"

## Plan

	# Ai - the one screen that says exactly what happens to each disk
printf '\n  %sThe plan%s\n\n' "$C_B" "$C_0"
printf '    %sERASE%s      %s  %s  becomes the new system\n' "$C_BAD" "$C_0" "$SYSTEM_DISK" "$(lsblk -dno SIZE "$SYSTEM_DISK" | tr -d ' ')"
if [[ "$KEEP_DATA" == yes ]]; then
	printf '    %skeep%s       %s  %s  your data, as it is\n' "$C_GOOD" "$C_0" "$DATA_DISK" "$(lsblk -dno SIZE "$DATA_DISK" | tr -d ' ')"
else
	printf '    %sERASE%s      %s  %s  becomes the new data disk\n' "$C_BAD" "$C_0" "$DATA_DISK" "$(lsblk -dno SIZE "$DATA_DISK" | tr -d ' ')"
fi
for d in "${DISKS[@]}"; do
	[[ "$d" == "$SYSTEM_DISK" || "$d" == "$DATA_DISK" ]] && continue
	printf '    %suntouched%s  %s  %s\n' "$C_DIM" "$C_0" "$d" "$(holds "$d")"
done
printf '\n'
dim "PC name $HOSTNAME_NEW, user $USERNAME, keyboard $KEYMAP, $TIMEZONE"
if [[ "$PERSIST" == yes ]]; then dim "saved settings found on the data disk, they come back"; fi
if [[ -n "$BACKUP_UUID" ]]; then dim "the backup drive is set up again from the data disk"; fi
printf '\n'

if ! confirm_word ERASE; then
	rm -f "$KEY"
	printf '\n    Nothing was changed.\n\n'
	exit 0
fi
printf '\n'
dim "Hands off from here, it takes about 10 to 20 minutes."


#    Install

step "Partitions"

SYS_ESP="$(partname "$SYSTEM_DISK" 1)"
SYS_ROOT="$(partname "$SYSTEM_DISK" 2)"

	# Ai - 2 GiB for boot, there is one boot image per kernel and a fallback
	#      for each, and with NVIDIA's firmware inside, each is large
run "clear the system disk"        wipefs -af "$SYSTEM_DISK"
run "new partition table"          sgdisk --zap-all "$SYSTEM_DISK"
run "boot partition, 2 GiB"        sgdisk -n1:0:+2G -t1:EF00 -c1:ESP "$SYSTEM_DISK"
run "system partition"             sgdisk -n2:0:0 -t2:8309 -c2:cryptsystem "$SYSTEM_DISK"
if [[ "$KEEP_DATA" == no ]]; then
	run "clear the data disk"      wipefs -af "$DATA_DISK"
	run "new data partition table" sgdisk --zap-all "$DATA_DISK"
	run "data partition"           sgdisk -n1:0:0 -t1:8309 -c1:cryptdata "$DATA_DISK"
fi
quiet partprobe "$SYSTEM_DISK" "$DATA_DISK" || true
quiet udevadm settle || true
if (( DRY == 0 )); then
	wait_for 10 test -b "$SYS_ROOT" || die "the new system partition did not appear"
fi


step "Encryption"

	# Ai - argon2id with its memory pinned, a benchmark sizes it to whatever RAM
	#      happens to be free, and the second disk can then get a cost the PC
	#      cannot pay later, which reads as a wrong passphrase
LUKS=(--type luks2 --batch-mode --pbkdf argon2id --pbkdf-memory "$LUKS_MEMORY_KIB" --iter-time 2000)

run "encrypt the system disk"    cryptsetup luksFormat "${LUKS[@]}" --label cryptsystem --key-file "$KEY" "$SYS_ROOT"
run "open the system disk"       cryptsetup open --allow-discards --persistent --key-file "$KEY" "$SYS_ROOT" cryptsystem
if [[ "$KEEP_DATA" == yes ]]; then
	run "open the data disk"     cryptsetup open --allow-discards --key-file "$KEY" "$DATA_PART" cryptdata
else
	run "encrypt the data disk"  cryptsetup luksFormat "${LUKS[@]}" --label cryptdata --key-file "$KEY" "$DATA_PART"
	run "open the data disk"     cryptsetup open --allow-discards --key-file "$KEY" "$DATA_PART" cryptdata
fi


step "Filesystems"

BTRFS_OPTS="noatime,compress=zstd:1"

run "boot filesystem"   mkfs.fat -F 32 -n ESP "$SYS_ESP"
run "system filesystem" mkfs.btrfs -f -L system /dev/mapper/cryptsystem
if [[ "$KEEP_DATA" == no ]]; then run "data filesystem" mkfs.btrfs -f -L data /dev/mapper/cryptdata; fi

	# Ai - on the system disk, logs and the package cache are their own
	#      subvolumes, so rolling back the system keeps the logs that explain
	#      why, and does not throw away downloads
	#      @snapshots sits beside @, never inside it, a rollback replaces @
run "system subvolumes" sh -c "mount /dev/mapper/cryptsystem $T \
	&& for s in @ @snapshots @log @pkg; do btrfs subvolume create $T/\$s; done \
	&& umount $T"

	# Ai - on a kept data disk only a missing subvolume is made, nothing that
	#      exists is touched, @persist holds the settings that outlive a reinstall
	#      VM disks get no copy on write, the flag is set on the folder so every
	#      disk image made inside it inherits it
run "data subvolumes" sh -c "mount /dev/mapper/cryptdata $T \
	&& for s in @home @games @vms @docker @ai @persist; do [ -d $T/\$s ] || btrfs subvolume create $T/\$s; done \
	&& { [ -d $T/@games/modding ] || btrfs subvolume create $T/@games/modding; } \
	&& chattr +C $T/@vms \
	&& umount $T"

mounts() {
	mount -o "$BTRFS_OPTS,subvol=/@" /dev/mapper/cryptsystem "$T"
	mount --mkdir -o "$BTRFS_OPTS,subvol=/@snapshots" /dev/mapper/cryptsystem "$T/.snapshots"
	mount --mkdir -o "$BTRFS_OPTS,subvol=/@log" /dev/mapper/cryptsystem "$T/var/log"
	mount --mkdir -o "$BTRFS_OPTS,subvol=/@pkg" /dev/mapper/cryptsystem "$T/var/cache/pacman/pkg"
	mount --mkdir -o umask=0077 "$SYS_ESP" "$T/boot"
	mount --mkdir -o "$BTRFS_OPTS,subvol=/@home" /dev/mapper/cryptdata "$T/home"
	mount --mkdir -o "$BTRFS_OPTS,subvol=/@persist" /dev/mapper/cryptdata "$T/persist"
}
run "mount everything" mounts


step "Packages"

	# Ai - fastest mirrors first, a failed ranking keeps the ISO's own list
soft "rank mirrors" reflector --latest 15 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist
quiet sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/; s/^#Color$/Color/' /etc/pacman.conf
	# Ai - an ISO older than a signature reads as a bad signature, so the
	#      keyring is refreshed before anything is downloaded
run "refresh the package keys" pacman -Sy --noconfirm --needed archlinux-keyring

	# Ai - a corrupt download stays in the cache and fails the same way forever,
	#      so between tries the cache is emptied and the mirrors ranked again
pacstrap_retry() {
	local n
	for n in 1 2 3; do
		pacstrap -K "$T" "$@" && return 0
		rm -f "$T"/var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.zst
		reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true
		sleep 3
	done
	return 1
}

BASE=(base linux linux-lts linux-firmware "$UCODE")
DISK=(btrfs-progs cryptsetup dosfstools efibootmgr sbctl)
CORE=(networkmanager sudo git base-devel openssh reflector pacman-contrib zram-generator snapper snap-pac)
TOOLS=(nano vim bash-completion man-db man-pages less)
	# Ai - the open NVIDIA modules are the ones for this card's generation,
	#      dkms builds them for both kernels, the headers are what it builds with
GRAPHICS=()
if [[ "$GPU" == nvidia ]]; then GRAPHICS=(nvidia-open-dkms nvidia-utils linux-headers linux-lts-headers); fi

run "base system"             pacstrap_retry "${BASE[@]}"
run "disks and boot tools"    pacstrap_retry "${DISK[@]}"
run "network and maintenance" pacstrap_retry "${CORE[@]}"
run "everyday tools"          pacstrap_retry "${TOOLS[@]}"
if (( ${#GRAPHICS[@]} )); then run "NVIDIA driver" pacstrap_retry "${GRAPHICS[@]}"; fi
quiet sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/; s/^#Color$/Color/' "$T/etc/pacman.conf"


step "System"

	# Ai - written straight to the files, hostnamectl and friends inside a
	#      chroot talk to the ISO's systemd and rename the ISO instead
put "$T/etc/hostname" <<< "$HOSTNAME_NEW"
put "$T/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF
put "$T/etc/vconsole.conf" <<< "KEYMAP=$KEYMAP"
put "$T/etc/locale.conf" <<< "LANG=$LOCALE"
quiet sed -i "s/^#\($LOCALE\)/\1/" "$T/etc/locale.gen"
run "language" arch-chroot "$T" locale-gen
quiet ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$T/etc/localtime"
run "clock" arch-chroot "$T" hwclock --systohc

	# Ai - zram is swap in compressed memory, fast and nothing on disk
	#      the kernel's own zswap would compress twice, so it is off
put "$T/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
put "$T/etc/sysctl.d/80-zram.conf" << 'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

	# Ai - one owner for names: systemd-resolved, NetworkManager hands it the
	#      network's servers, Mullvad hands it the tunnel's
put "$T/etc/NetworkManager/conf.d/dns.conf" << 'EOF'
[main]
dns=systemd-resolved
EOF

run "services at start" arch-chroot "$T" systemctl enable \
	NetworkManager systemd-resolved systemd-timesyncd fstrim.timer paccache.timer systemd-boot-update


step "You"

	# Ai - uid 1000, the owner of a kept home, so its files stay yours
if arch-chroot "$T" id -u "$USERNAME" > /dev/null 2>&1; then
	ok "$USERNAME already exists"
elif [[ -d "$T/home/$USERNAME" ]]; then
	run "add $USERNAME, keeping the home" arch-chroot "$T" useradd -M -u 1000 -G wheel -s /bin/bash "$USERNAME"
else
	run "add $USERNAME" arch-chroot "$T" useradd -m -u 1000 -G wheel -s /bin/bash "$USERNAME"
fi
if (( DRY == 0 )); then printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot "$T" chpasswd; fi
unset USER_PASS
ok "password set"

	# Ai - root has no password and cannot log in, sudo is the way in, and the
	#      USB with rescue.sh is the way in when nothing else works
run "lock the root login" arch-chroot "$T" passwd -l root

put "$T/etc/sudoers.d/10-wheel" 440 << 'EOF'
%wheel ALL=(ALL:ALL) ALL
Defaults lecture = never
Defaults passwd_timeout = 0
EOF
run "check the sudo rules" arch-chroot "$T" visudo -c -f /etc/sudoers.d/10-wheel


step "Disks at start"

	# Ai - an empty id in fstab or crypttab would stop the PC starting, so a
	#      real run stops here instead, a dry run shows a placeholder
uuid_of() {
	local u
	u="$(blkid -s UUID -o value "$1" 2> /dev/null || true)"
	if [[ -z "$u" ]]; then
		(( DRY == 1 )) || die "no id found for $1"
		u="$2"
	fi
	printf '%s' "$u"
}
SYS_LUKS_UUID="$(uuid_of "$SYS_ROOT" SYSTEM-UUID)"
SYS_FS_UUID="$(uuid_of /dev/mapper/cryptsystem SYSTEM-FS-UUID)"
ESP_UUID="$(uuid_of "$SYS_ESP" ESP-UUID)"
DATA_LUKS_UUID="$(uuid_of "$DATA_PART" DATA-UUID)"
DATA_FS_UUID="$(uuid_of /dev/mapper/cryptdata DATA-FS-UUID)"

## Data key

	# Ai - the data disk opens at start with a random key kept on the encrypted
	#      system disk, so the passphrase is typed once, for the system disk
DATA_KEY="$T/etc/cryptsetup-keys.d/cryptdata.key"
if (( DRY == 0 )); then
	install -d -m 700 "$T/etc/cryptsetup-keys.d"
	( umask 077; dd if=/dev/urandom of="$DATA_KEY" bs=512 count=8 status=none )
fi
run "give the data disk the new key" cryptsetup luksAddKey --batch-mode --pbkdf pbkdf2 \
	--key-file "$KEY" "$DATA_PART" "$DATA_KEY"

	# Ai - a kept disk still holds the key of the install being replaced, which
	#      exists nowhere now, only the passphrase and the new key stay
if [[ "$KEEP_DATA" == yes ]] && (( DRY == 0 )); then
	slot_of() { cryptsetup open --test-passphrase -v --key-file "$1" "$DATA_PART" 2>&1 | sed -n 's/^Key slot \([0-9]*\) unlocked.*/\1/p'; }
	PASS_SLOT="$(slot_of "$KEY")"
	NEW_SLOT="$(slot_of "$DATA_KEY")"
	if [[ -n "$PASS_SLOT" && -n "$NEW_SLOT" ]]; then
		for s in $(cryptsetup luksDump "$DATA_PART" | sed -n 's/^  \([0-9]*\): luks2$/\1/p'); do
			[[ "$s" == "$PASS_SLOT" || "$s" == "$NEW_SLOT" ]] && continue
			soft "remove the old install's key, slot $s" cryptsetup luksKillSlot --batch-mode --key-file "$KEY" "$DATA_PART" "$s"
		done
	else
		warn "could not tell the data disk's keys apart, the old ones were left"
	fi
fi

## Backup drive

	# Ai - its key is kept on the data disk, so a reinstall finds it again
BACKUP_LINE="" BACKUP_MOUNT=""
if [[ -n "$BACKUP_UUID" && -f "$T/persist/keys/backup.key" ]]; then
	quiet install -m 600 "$T/persist/keys/backup.key" "$T/etc/cryptsetup-keys.d/backup.key"
	BACKUP_LINE="backup UUID=$BACKUP_UUID /etc/cryptsetup-keys.d/backup.key luks,nofail,x-systemd.device-timeout=10s"
	BACKUP_MOUNT="/dev/mapper/backup  /mnt/backup  btrfs  $BTRFS_OPTS,nofail,x-systemd.device-timeout=10s  0 0"
	quiet mkdir -p "$T/mnt/backup"
	ok "backup drive set up again"
fi

## Crypttab

put "$T/etc/crypttab" 600 << EOF
# Ai - the system disk is opened before this file is read, by the boot image
cryptdata UUID=$DATA_LUKS_UUID /etc/cryptsetup-keys.d/cryptdata.key luks,discard,nofail,x-systemd.device-timeout=10s
$BACKUP_LINE
EOF

## Fstab

	# Ai - written by hand, not by genfstab: / is mounted by name only, so a
	#      rollback that swaps @ just works, and every disk but the system disk
	#      is optional, a missing one never stops the PC at an emergency screen
DOPT="$BTRFS_OPTS,nofail,x-systemd.device-timeout=10s"
put "$T/etc/fstab" << EOF
# Ai - system disk
UUID=$SYS_FS_UUID  /                      btrfs  $BTRFS_OPTS,subvol=/@          0 0
UUID=$SYS_FS_UUID  /.snapshots            btrfs  $BTRFS_OPTS,subvol=/@snapshots 0 0
UUID=$SYS_FS_UUID  /var/log               btrfs  $BTRFS_OPTS,subvol=/@log       0 0
UUID=$SYS_FS_UUID  /var/cache/pacman/pkg  btrfs  $BTRFS_OPTS,subvol=/@pkg       0 0
UUID=$ESP_UUID     /boot                  vfat   umask=0077                     0 2

# Ai - data disk, all optional
UUID=$DATA_FS_UUID  /home                    btrfs  $DOPT,subvol=/@home      0 0
UUID=$DATA_FS_UUID  /home/ai                 btrfs  $DOPT,subvol=/@ai        0 0
UUID=$DATA_FS_UUID  /games                   btrfs  $DOPT,subvol=/@games     0 0
UUID=$DATA_FS_UUID  /var/lib/libvirt/images  btrfs  noatime,nofail,x-systemd.device-timeout=10s,subvol=/@vms  0 0
UUID=$DATA_FS_UUID  /var/lib/docker          btrfs  $DOPT,subvol=/@docker    0 0
UUID=$DATA_FS_UUID  /persist                 btrfs  $DOPT,subvol=/@persist   0 0
UUID=$DATA_FS_UUID  /mnt/data-root           btrfs  $DOPT,subvolid=5         0 0

# Ai - state that outlives a reinstall, kept on the data disk
/persist/tailscale    /var/lib/tailscale  none  bind,nofail,x-systemd.requires-mounts-for=/persist  0 0
/persist/mullvad-vpn  /etc/mullvad-vpn    none  bind,nofail,x-systemd.requires-mounts-for=/persist  0 0

# Ai - backup drive, optional
$BACKUP_MOUNT
EOF

if (( DRY == 0 )); then
	mkdir -p "$T"/{games,var/lib/libvirt/images,var/lib/docker,mnt/data-root,var/lib/tailscale,etc/mullvad-vpn}
	mkdir -p "$T"/persist/{tailscale,mullvad-vpn,ssh,keys,headers,state}
	chmod 700 "$T/persist/keys" "$T/persist/headers" "$T/persist/ssh"
fi

	# Ai - the PC keeps its SSH identity, so the laptop does not warn about a
	#      changed key after every reinstall
if compgen -G "$T/persist/ssh/ssh_host_*" > /dev/null; then
	quiet cp -a "$T"/persist/ssh/ssh_host_* "$T/etc/ssh/"
	ok "SSH identity kept"
fi


step "Boot"

## Image

	# Ai - the systemd boot image unlocks the disk itself, with the keyboard
	#      layout loaded first so the passphrase types the way you know
	#      for NVIDIA the driver loads early and the kms hook goes, the Arch
	#      wiki's way to keep the old nouveau driver out
HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
MODULES=""
if [[ "$GPU" == nvidia ]]; then
	HOOKS="${HOOKS/ kms/}"
	MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
fi
put "$T/etc/mkinitcpio.conf.d/nug.conf" << EOF
# Ai - written by the nug install, the main mkinitcpio.conf is left as shipped
MODULES=($MODULES)
HOOKS=($HOOKS)
EOF

	# Ai - one file per kernel holds the kernel, the boot image and the command
	#      line, so nothing at start can be edited, and Secure Boot can sign
	#      exactly what boots
CMDLINE="rd.luks.name=$SYS_LUKS_UUID=cryptsystem rd.luks.options=$SYS_LUKS_UUID=discard root=/dev/mapper/cryptsystem rootflags=subvol=/@ rw zswap.enabled=0 quiet loglevel=3"
if [[ "$GPU" == nvidia ]]; then CMDLINE+=" nvidia_drm.modeset=1 nvidia_drm.fbdev=1"; fi
put "$T/etc/kernel/cmdline" <<< "$CMDLINE"

for k in linux linux-lts; do
	put "$T/etc/mkinitcpio.d/$k.preset" << EOF
# Ai - written by the nug install: one unified image per kernel, and a fallback
ALL_kver="/boot/vmlinuz-$k"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-$k.efi"
fallback_uki="/boot/EFI/Linux/arch-$k-fallback.efi"
fallback_options="-S autodetect"
EOF
done

quiet mkdir -p "$T/boot/EFI/Linux"
run "build the boot images" arch-chroot "$T" mkinitcpio -P
quiet rm -f "$T"/boot/initramfs-*.img

## Menu

	# Ai - old entries from earlier installs are removed first, so the firmware
	#      menu never offers a system that is gone
if (( DRY == 0 )); then
	for b in $(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} \(Linux Boot Manager\|Arch Linux Limine\).*/\1/p'); do
		quiet efibootmgr -b "$b" -B || true
	done
fi
run "install the boot menu" arch-chroot "$T" bootctl install

put "$T/boot/loader/loader.conf" << EOF
default arch-linux.efi
timeout $BOOT_TIMEOUT
console-mode max
editor no
EOF


step "Hand over"

	# Ai - the install repo goes into your home, where rebuild and Changes
	#      use it, a kept home's old copy is moved aside, never deleted
DEST="$T/home/$USERNAME/$REPO_DIR_NAME"
if [[ -d "$DEST" ]]; then
	OLD="$DEST.before-$(date +%F)"
	quiet mv "$DEST" "$OLD"
	say "your old copy is at ~/${OLD##*/}"
fi
run "copy the install repo" cp -a "$REPO" "$DEST"
quiet chown -R 1000:1000 "$DEST"
if [[ -d "$T/home/$USERNAME" ]]; then quiet chown 1000:1000 "$T/home/$USERNAME"; fi

put "$T/usr/local/bin/rebuild" 755 << 'EOF'
#!/bin/sh
# Ai - rebuild: the after-install setup, see scripts/setup.sh
exec bash "$HOME/rebuild/scripts/setup.sh" "$@"
EOF

	# Ai - the first login says what to do next, until setup has run once
put "$T/etc/profile.d/nug-next.sh" << 'EOF'
if [ ! -f "$HOME/.local/state/nug/done/setup" ] && [ -t 1 ]; then
	printf '\n  Welcome. One step left, it sets up the desktop and everything else:\n\n'
	printf '    rebuild\n\n'
fi
EOF

quiet cp "$LOG" "$T/var/log/nug-install.log"

	# Ai - names go to systemd-resolved from the first start, done outside the
	#      chroot, which holds its own copy of this file while it runs
quiet ln -sf ../run/systemd/resolve/stub-resolv.conf "$T/etc/resolv.conf"


step "Check"

checks=(
	"boot image:test -f $T/boot/EFI/Linux/arch-linux.efi"
	"fallback kernel:test -f $T/boot/EFI/Linux/arch-linux-lts.efi"
	"boot menu:test -f $T/boot/EFI/systemd/systemd-bootx64.efi"
	"menu cannot be edited:grep -q '^editor no' $T/boot/loader/loader.conf"
	"firmware entry:efibootmgr | grep -q 'Linux Boot Manager'"
	"system mounts by name:grep -q 'subvol=/@ ' $T/etc/fstab"
	"data disk optional:grep -q 'cryptdata.*nofail' $T/etc/crypttab"
	"data key:test -s $DATA_KEY"
	"user $USERNAME:arch-chroot $T id $USERNAME"
	"sudo rules:arch-chroot $T visudo -c"
	"install repo:test -f $DEST/scripts/setup.sh"
)
FAILED=0
for c in "${checks[@]}"; do
	if (( DRY == 1 )); then
		dim "would check: ${c%%:*}"
	elif bash -c "${c#*:}" > /dev/null 2>&1; then
		ok "${c%%:*}"
	else
		printf '    %s✗%s %s\n' "$C_BAD" "$C_0" "${c%%:*}"
		FAILED=$(( FAILED + 1 ))
	fi
done

rm -f "$KEY"
if (( DRY == 0 )); then
	sync
	umount -R "$T"
	cryptsetup close cryptdata || true
	cryptsetup close cryptsystem || true
fi

(( FAILED == 0 )) || die "$FAILED check(s) failed, do not restart yet, send the log: $LOG"

todo "Take out the USB and restart."
todo "Type the disk passphrase, then log in as $USERNAME."
todo "Run:  rebuild"
finish
