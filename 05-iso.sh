#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"

stage_banner "05-iso" "partitions, encryption, base system, boot menu" "installer   $(date +%H:%M)"


#    Answers


section "Answers"

####### every question in the whole install lives in this one block
####### after the last password nothing else is asked until the end
####### subjects are split by an arrow line, with one extra blank line
####### after a long subject, as laid out in the v7.0 review

act_text "Everything you type is in this section.

After the last password the install runs on its own."


## Firmware

if [[ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || true)" != "64" ]]; then
	printf 'Not booted in 64 bit UEFI mode. Aborting.\n' >&2
	exit 1
fi


## Leftovers

####### if an earlier attempt stopped partway it left mappers open and /mnt
####### mounted, and the retry would then fail on device busy rather than
####### simply starting over

mountpoint -q /mnt && umount -R /mnt

for m in cryptsystem cryptdata; do
	if [[ -e "/dev/mapper/$m" ]]; then
		cryptsetup close "$m" 2>/dev/null || true
		note "closed a leftover $m from an earlier attempt"
	fi
done


## Console

loadkeys "$KEYMAP"

timedatectl set-ntp true


## Network

retry online


## Names

if [[ "$HOSTNAME" == CHANGEME || "$USERNAME" == CHANGEME ]]; then
	act_next
	act_text "Name this machine and yourself."
	HOSTNAME="$(ask 'Hostname')"
	USERNAME="$(ask 'Username')"
	[[ -n "$HOSTNAME" && -n "$USERNAME" ]] || { printf 'Both required\n' >&2; exit 1; }
	save_cfg HOSTNAME "$HOSTNAME"
	save_cfg USERNAME "$USERNAME"
fi

export USERNAME


## Disks

####### the listing goes inside the block, so the thing you need and the
####### thing you need it for are not separated by a border
####### the wipe is confirmed right here, while the choice is still on screen
####### it used to come after the passwords, so a wrong disk meant typing
####### six passwords first and then starting the script over
####### anything but YES asks for the disks again

while true; do
	act_next big
	act_line "Pick the two disks. BOTH ARE COMPLETELY ERASED."
	act_line ""
	lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS | act_feed
	act_line ""

	SYSTEM_DISK="$(pick_disk 'System disk: ')"
	DATA_DISK="$(pick_disk 'Data disk: ')"

	if [[ "$SYSTEM_DISK" == "$DATA_DISK" ]]; then
		act_line ""
		act_line "That is the same disk twice, pick two different ones."
		continue
	fi

	act_next
	act_line "Check this, then type YES to erase both disks."
	act_line ""
	act_line "system disk  $SYSTEM_DISK  $(lsblk -dno SIZE "$SYSTEM_DISK")  WILL BE WIPED"
	act_line "data disk    $DATA_DISK  $(lsblk -dno SIZE "$DATA_DISK")  WILL BE WIPED"
	act_line ""

	confirmed "Type YES to erase them, anything else to pick again" && break

	act_line ""
	act_line "Nothing erased."
done

require_disk "$SYSTEM_DISK"
require_disk "$DATA_DISK"


## Passwords

act_next big
act_text "Set three passwords, each typed twice.

The disk passphrase unlocks both disks. You set it once."
act_line ""

LUKS_PASS="$(secret_twice 'Disk passphrase, both disks')"

act_next

ROOT_PASS="$(secret_twice 'Root password')"

act_next

USER_PASS="$(secret_twice "Password for $USERNAME")"

act_close

note "Hands off from here."



#    Partitions


section "Partitions"


## System

run "wipe system disk"  sgdisk --zap-all "$SYSTEM_DISK"
run "efi partition"     sgdisk -n1:0:+4G -t1:EF00 -c1:"EFI"         "$SYSTEM_DISK"
run "root partition"    sgdisk -n2:0:0   -t2:8300 -c2:"cryptsystem" "$SYSTEM_DISK"


## Data

run "wipe data disk"    sgdisk --zap-all "$DATA_DISK"
run "data partition"    sgdisk -n1:0:0   -t1:8300 -c1:"cryptdata"   "$DATA_DISK"

run "reread tables"     partprobe "$SYSTEM_DISK" "$DATA_DISK"


## Names

SYS_ESP="$(partname "$SYSTEM_DISK" 1)"
SYS_ROOT="$(partname "$SYSTEM_DISK" 2)"
DATA_PART="$(partname "$DATA_DISK" 1)"

udevadm settle

wait_for 10 test -b "$SYS_ESP"
wait_for 10 test -b "$SYS_ROOT"
wait_for 10 test -b "$DATA_PART"



#    Encrypt


section "Encrypt"

####### one passphrase unlocks both disks
####### it goes to a file on /run, which is a tmpfs and never touches a disk
####### not on stdin, because a backgrounded job cannot reliably inherit a pipe
####### not as an argument, because arguments are visible in the process table

KEYTMP=/run/rebuild.key

( umask 077; printf '%s' "$LUKS_PASS" > "$KEYTMP" )

KEYSUM="$(sha256sum "$KEYTMP" | cut -d' ' -f1)"


## Cost

####### the argon2 memory cost is pinned rather than benchmarked
####### left to benchmark, luksFormat sizes the cost against whatever RAM is
####### free at that instant, and every later unlock has to allocate that same
####### amount again
####### the second disk is formatted after the first one is already open, so it
####### can be handed a cost the machine can no longer satisfy, and a keyslot
####### that cannot be derived reads as a wrong passphrase
####### 256 MiB is strong for a disk passphrase and fits any machine you will
####### run this on, including a small test VM

LUKSFMT=(
	--type luks2
	--batch-mode
	--pbkdf argon2id
	--pbkdf-memory 262144
	--iter-time 2000
)


## Guard

####### confirm the key file is byte for byte what we wrote, before each use
keyguard() {
	local now
	now="$(sha256sum "$KEYTMP" | cut -d' ' -f1)"
	[[ "$now" == "$KEYSUM" ]] \
		|| { printf 'The key file changed underneath us, stopping\n' >&2; exit 1; }
}


## Disks

encrypt_disk() {
	local part=$1 name=$2

	keyguard

	run "format $name"  cryptsetup luksFormat "${LUKSFMT[@]}" --key-file "$KEYTMP" "$part"

	####### prove the passphrase actually opens it before going further, so a
	####### mismatch surfaces at the step that caused it rather than later
	run "verify $name"  cryptsetup open --test-passphrase --key-file "$KEYTMP" "$part"

	run "open $name"    cryptsetup open --batch-mode --key-file "$KEYTMP" "$part" "$name"
}

encrypt_disk "$SYS_ROOT"  cryptsystem

encrypt_disk "$DATA_PART" cryptdata



#    Filesystems


section "Filesystems"


## Format

run "format esp"         mkfs.fat -F32 "$SYS_ESP"
run "format system"      mkfs.btrfs -f -L system /dev/mapper/cryptsystem
run "format data"        mkfs.btrfs -f -L data   /dev/mapper/cryptdata


## System subvols

####### @snapshots is a sibling of @, never nested inside it
####### nested snapshots are destroyed by their own rollback
run "mount system top"   mount /dev/mapper/cryptsystem /mnt
run "create @"           btrfs subvolume create /mnt/@
run "create @snapshots"  btrfs subvolume create /mnt/@snapshots
run "unmount system top" umount /mnt


## Data subvols

run "mount data top"     mount /dev/mapper/cryptdata /mnt
run "create @home"       btrfs subvolume create /mnt/@home
run "create @games"      btrfs subvolume create /mnt/@games
run "create @vms"        btrfs subvolume create /mnt/@vms
run "create @docker"     btrfs subvolume create /mnt/@docker
run "create @ai"         btrfs subvolume create /mnt/@ai
run "unmount data top"   umount /mnt


## Mount

OPTS="compress=zstd:1,noatime"

mount -o "$OPTS,subvol=@" /dev/mapper/cryptsystem /mnt

mount --mkdir -o "$OPTS,subvol=@snapshots" /dev/mapper/cryptsystem /mnt/.snapshots

mount --mkdir "$SYS_ESP" /mnt/boot

mount --mkdir -o "$OPTS,subvol=@home"  /dev/mapper/cryptdata /mnt/home
mount --mkdir -o "$OPTS,subvol=@games" /dev/mapper/cryptdata /mnt/games

####### vm images get no copy on write and no compression
mkdir -p /mnt/var/lib/libvirt/images
mount -o noatime,subvol=@vms /dev/mapper/cryptdata /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/libvirt/images

mkdir -p /mnt/var/lib/docker
mount -o "$OPTS,subvol=@docker" /dev/mapper/cryptdata /mnt/var/lib/docker

mkdir -p /mnt/home/ai
mount -o "$OPTS,subvol=@ai" /dev/mapper/cryptdata /mnt/home/ai

####### the whole data disk gets an fstab entry in 50-bkp-net so btrbk can
####### snapshot @home, it is deliberately not mounted here because genfstab
####### would record it without nofail and a missing data disk would then
####### stop the machine booting at all

findmnt -R /mnt >&3



#    Install


section "Install"


## Mirrors

run "rank mirrors" reflector --latest 10 --protocol https --age 12 \
	--sort rate --save /etc/pacman.d/mirrorlist


## Pacman

sed -i 's/^#Color$/Color/'                       /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf


## Keyring

####### an ISO older than a package signature reads as a bad signature
####### refreshing the live keyring first removes that whole class of failure
run "refresh package db"  pacman -Sy --noconfirm

soft "update keyring"     pacman -S --noconfirm --needed archlinux-keyring


## Base

####### a corrupt download is cached, so a plain retry reuses the same bad
####### file forever and fails identically every time
####### the cache is purged and the mirrors re-ranked between attempts, so a
####### single bad mirror cannot end the run

pacstrap_retry() {
	local attempt=1

	until pacstrap -K /mnt "$@"; do

		if (( attempt >= 3 )); then
			printf '\n  pacstrap failed %s times for: %s\n' "$attempt" "$*" >&2
			printf '  the mirror may be broken, try again later\n\n' >&2
			return 1
		fi

		flag "download was corrupt, purging the cache and switching mirrors"

		rm -f /mnt/var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null || true
		rm -f /var/cache/pacman/pkg/*.pkg.tar.zst     2>/dev/null || true

		reflector --latest 20 --protocol https --sort rate \
			--save /etc/pacman.d/mirrorlist 2>/dev/null || true

		attempt=$(( attempt + 1 ))
		sleep 3
	done
}

pacstrap_retry base linux linux-firmware intel-ucode

pacstrap_retry btrfs-progs cryptsetup networkmanager sudo base-devel git

pacstrap_retry zram-generator snapper snap-pac tpm2-tools

pacstrap_retry limine efibootmgr dosfstools mtools

pacstrap_retry nano vim bash-completion openssh gobject-introspection reflector


## Fstab

genfstab -U /mnt > /mnt/etc/fstab

####### / is mounted by name only, see Fstab in 00-lib for why
####### without this a snapshot restore would boot the old broken system
fstab_root_by_name /mnt/etc/fstab



#    System


section "System"


## Console

arch-chroot /mnt sh -c "printf 'KEYMAP=%s\n' '$KEYMAP' > /etc/vconsole.conf"

arch-chroot /mnt sh -c "printf 'LANG=%s\n' '$LOCALE' > /etc/locale.conf"

arch-chroot /mnt sed -i "s/^#\($LOCALE\)/\1/" /etc/locale.gen

run "generate locale" arch-chroot /mnt locale-gen


## Time

arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

run "sync clock" arch-chroot /mnt hwclock --systohc


## Host

####### written directly, never through hostnamectl
####### arch-chroot bind mounts /run, so hostnamectl in the chroot reaches the
####### live ISO's systemd over dbus, renames the ISO instead of the install,
####### and exits 0, so the fallback that writes this file never ran
printf '%s\n' "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF


## Hooks

arch-chroot /mnt sed -i \
	's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
	/etc/mkinitcpio.conf

run "build initramfs" arch-chroot /mnt mkinitcpio -P


## Network

run "enable networkmanager" arch-chroot /mnt systemctl enable NetworkManager



#    Users


section "Users"


## Root

printf 'root:%s\n' "$ROOT_PASS" | arch-chroot /mnt chpasswd


## User

if ! arch-chroot /mnt id -u "$USERNAME" &>/dev/null; then
	arch-chroot /mnt useradd -m -G wheel "$USERNAME"
fi

printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd

unset ROOT_PASS USER_PASS


## Sudo

####### lecture never, the first sudo of the run otherwise prints a paragraph
####### of advice in the middle of the question block
####### proven with visudo before it counts, a broken file here disables sudo
printf '%%wheel ALL=(ALL:ALL) ALL\nDefaults lecture = never\n' > /mnt/etc/sudoers.d/10-wheel
chmod 440 /mnt/etc/sudoers.d/10-wheel

run "check sudo rules" arch-chroot /mnt visudo -c -f /etc/sudoers.d/10-wheel



#    Bootloader


section "Bootloader"


## Keyfile

cat > /mnt/root/_setup.sh << CHROOTEOF
set -euo pipefail

mkdir -p /etc/cryptsetup-keys.d

dd if=/dev/urandom of=/etc/cryptsetup-keys.d/data.key bs=1024 count=4 status=none

chmod 600 /etc/cryptsetup-keys.d/data.key

####### arch-chroot bind mounts /run, so the tmpfs keyfile is visible here
cryptsetup luksAddKey --key-file /run/rebuild.key \\
	$DATA_PART /etc/cryptsetup-keys.d/data.key

DATA_UUID=\$(blkid -s UUID -o value $DATA_PART)

printf 'cryptdata UUID=%s /etc/cryptsetup-keys.d/data.key luks\n' "\$DATA_UUID" >> /etc/crypttab


####### limine ships no deploy hook of its own, both copies are ours to keep current

mkdir -p /boot/EFI/limine /boot/EFI/BOOT

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

mkdir -p /etc/pacman.d/hooks

cat > /etc/pacman.d/hooks/99-limine-deploy.hook << 'HOOKEOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine to the ESP...
When = PostTransaction
Exec = /bin/sh -c "cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi && cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI"
HOOKEOF


####### limine reads the directory holding its own efi binary first
####### any limine.conf there silently outranks /boot/limine.conf
rm -f /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf


efibootmgr --create --disk $SYSTEM_DISK --part 1 \\
	--label "Arch Linux Limine Boot Loader" \\
	--loader '\\EFI\\limine\\limine_x64.efi' --unicode

LUKS_UUID=\$(blkid -s UUID -o value $SYS_ROOT)

systemd-machine-id-setup


####### the TPM is enrolled here, not later
####### this is the only point in the whole run where the passphrase is
####### already in hand, so nothing has to stop and ask for it
####### a mismatch later just falls back to the passphrase prompt, which is a
####### safe failure rather than a lockout, and the passphrase slot always stays
if [[ -e /dev/tpmrm0 ]]; then
	systemd-cryptenroll --unlock-key-file=/run/rebuild.key \\
		--tpm2-device=auto --tpm2-pcrs=7 $SYS_ROOT \\
		&& echo "TPM enrolled" \\
		|| echo "TPM enrolment failed, the passphrase still works"
else
	echo "no TPM device, skipping"
fi

####### /@ with the slash, the snapshot tool only recognises that spelling
####### subvol=@ and subvol=/@ mount the same thing
printf 'rd.luks.name=%s=cryptsystem root=/dev/mapper/cryptsystem rootflags=subvol=/@ rw\n' \\
	"\$LUKS_UUID" > /etc/kernel/cmdline

####### the boot menu is not written here any more
####### the Menu block below writes it with the same tool 10-base installs
CHROOTEOF


## Run

arch-chroot /mnt bash /root/_setup.sh

rm -f /mnt/root/_setup.sh

####### shred overwrites disk blocks, and tmpfs has none
####### what actually protects the key is that it only ever lived in RAM
rm -f "$KEYTMP"

unset LUKS_PASS


## Menu

####### one tool writes the boot menu, here and on every later change
####### it builds the menu from the real kernel files and the cmdline above,
####### checks the result would start on its own, and only then saves it
####### nested shape: /+Arch Linux is an open folder, Linux is the first
####### thing in it, default_entry 2 points at Linux, quiet stays off
####### the old black screen was default_entry pointing at the folder with
####### quiet hiding why, the check refuses exactly that
install -Dm755 "$REPO/limine-header-fix.sh" /mnt/usr/local/bin/limine-header-fix

printf 'BOOT_MODE=nested\nBOOT_TIMEOUT=%s\n' "$LIMINE_TIMEOUT" > /mnt/etc/rebuild-boot.conf

run "write boot menu" bash "$REPO/limine-header-fix.sh" --root /mnt

bash "$REPO/limine-header-fix.sh" --root /mnt --check || true



#    Handover


section "Handover"


## Repo

####### the whole repo travels with the install so the next stages are local
install -d -o 1000 -g 1000 "/mnt/home/$USERNAME/Rebuild"

cp -r "$REPO/." "/mnt/home/$USERNAME/Rebuild/"

chown -R 1000:1000 "/mnt/home/$USERNAME/Rebuild"

find "/mnt/home/$USERNAME/Rebuild" -name '*.sh' -exec chmod +x {} +

####### git records the executable bit, so the chmod above shows up as a local
####### change to every script, and git pull then refuses to overwrite them
####### telling git to ignore modes makes pulls clean from here on
if [[ -d "/mnt/home/$USERNAME/Rebuild/.git" ]]; then
	arch-chroot /mnt sudo -u "$USERNAME" \
		git -C "/home/$USERNAME/Rebuild" config core.fileMode false || true
fi


## Config

install -o 1000 -g 1000 -m 600 "$CONFIG" "/mnt/home/$USERNAME/.install-config"


## Logs

install -d /mnt/var/log/install

cp "$LOG" /mnt/var/log/install/ 2>/dev/null || true



#    Verify


section "Verify"

check "esp mounted"      mountpoint -q /mnt/boot
check "root mounted"     mountpoint -q /mnt
check "snapshots sib"    sh -c 'findmnt -no SOURCE /mnt/.snapshots | grep -q "@snapshots"'
check "menu starts alone" bash "$REPO/limine-header-fix.sh" --root /mnt --check
check "menu tool copied"  test -x /mnt/usr/local/bin/limine-header-fix
check "menu settings"     test -f /mnt/etc/rebuild-boot.conf
check "kernel present"   test -f /mnt/boot/vmlinuz-linux
check "initramfs present" test -f /mnt/boot/initramfs-linux.img
check "microcode present" test -f /mnt/boot/intel-ucode.img
check "cmdline has luks"  grep -q 'rd.luks.name=' /mnt/boot/limine.conf
check "cmdline names /@"  grep -q 'rootflags=subvol=/@' /mnt/etc/kernel/cmdline
check "fstab / by name"   fstab_root_named /mnt/etc/fstab
check "efi entry made"    sh -c 'efibootmgr | grep -q Limine'
check "no efi conf"      sh -c '! test -f /mnt/boot/EFI/limine/limine.conf'
check "deploy hook"      test -f /mnt/etc/pacman.d/hooks/99-limine-deploy.hook
check "efi binary"       test -f /mnt/boot/EFI/limine/limine_x64.efi
check "fallback binary"  test -f /mnt/boot/EFI/BOOT/BOOTX64.EFI
check "crypttab"         grep -q cryptdata /mnt/etc/crypttab
check "repo copied"      test -f "/mnt/home/$USERNAME/Rebuild/run.sh"

verify_done

stage_done iso



#    End


section "End"

umount -R /mnt

lsblk

printf '\n'
printf '  Remove the USB and reboot.\n'
printf '\n'
printf '  The boot menu shows for %s seconds with Linux highlighted,\n' "$LIMINE_TIMEOUT"
printf '  then starts on its own. If it ever waits instead, press Enter\n'
printf '  on Linux, it is always the second line.\n'
printf '\n'
printf '  Then log in and run:\n'
printf '\n'
printf '    bash ~/Rebuild/run.sh\n'
printf '\n'
printf '  After that first run it is just:\n'
printf '\n'
printf '    rebuild\n'
printf '\n'
