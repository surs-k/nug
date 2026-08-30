#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# Check

set -Eeuo pipefail

if [[ ! -f "$CONFIG" ]]; then
	read -rp "Hostname [machineherald]: " h
	read -rp "Username [logic]: " u
	printf 'HOSTNAME="%s"\nUSERNAME="%s"\n' \
		"${h:-machineherald}" "${u:-logic}" > "$CONFIG"
	source "$CONFIG"
fi

if [[ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)" != "64" ]]; then
    echo "Not booted in UEFI (64-bit) mode - this script requires UEFI. Aborting."
    exit 1
fi

loadkeys "$KEYMAP"

timedatectl set-ntp true

ping -c2 archlinux.org

read -rp "Type YES to continue: " CONFIRM
	[[ "$CONFIRM" == "YES" ]] || exit 1

lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS

echo
echo
echo =============================
echo
echo

echo "System disk (WILL BE WIPED): $SYSTEM_DISK"

echo "Data disk   (WILL BE WIPED): $DATA_DISK"

read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1





#    Partitions 


### CHECK

require_disk "$SYSTEM_DISK"
require_disk "$DATA_DISK"


### SYSTEM_DISK

sgdisk --zap-all "$SYSTEM_DISK"
sgdisk -n1:0:+4G -t1:EF00 -c1:"EFI"         "$SYSTEM_DISK"
sgdisk -n2:0:0   -t2:8300 -c2:"cryptsystem" "$SYSTEM_DISK"


### DATA_DISK

sgdisk --zap-all "$DATA_DISK"
sgdisk -n1:0:0 -t1:8300 -c1:"cryptdata" "$DATA_DISK"

partprobe "$SYSTEM_DISK" "$DATA_DISK"
sleep 2

SYS_ESP="$SYSPART1"
SYS_ROOT="$SYSPART2"
DATA_PART="$DATAPART1"


### Encrypt

clear > /dev/tty
echo SYS Encryption setup
echo Set Password
retry cryptsetup luksFormat --type luks2 "$SYS_ROOT"

clear > /dev/tty
echo SYS Encryption open
echo Retype Password
retry cryptsetup open "$SYS_ROOT" cryptsystem

clear > /dev/tty
echo Data Encryption setup 
echo Set Password
retry cryptsetup luksFormat --type luks2 "$DATA_PART"

clear > /dev/tty
echo Data Encryption open 
echo Retype Password
retry cryptsetup open "$DATA_PART" cryptdata
clear > /dev/tty


### Format

mkfs.fat -F32 "$SYS_ESP"
mkfs.btrfs -L system /dev/mapper/cryptsystem
mkfs.btrfs -L data   /dev/mapper/cryptdata


### Subvolumes

mount /dev/mapper/cryptsystem /mnt
btrfs subvolume create /mnt/@
umount /mnt

mount /dev/mapper/cryptdata /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@games
btrfs subvolume create /mnt/@vms
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@ai
umount /mnt


### Mount

mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/cryptsystem /mnt
mount --mkdir "$SYS_ESP" /mnt/boot

mount --mkdir -o compress=zstd:1,noatime,subvol=@home  /dev/mapper/cryptdata /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@games /dev/mapper/cryptdata /mnt/games

mkdir -p /mnt/var/lib/libvirt/images
mount -o noatime,subvol=@vms /dev/mapper/cryptdata /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/libvirt/images

mkdir -p /mnt/var/lib/docker
mount -o compress=zstd:1,noatime,subvol=@docker /dev/mapper/cryptdata /mnt/var/lib/docker

mkdir -p /mnt/home/ai
mount -o compress=zstd:1,noatime,subvol=@ai /dev/mapper/cryptdata /mnt/home/ai

clear > /dev/tty
lsblk

echo
echo
echo =============================
echo
echo

findmnt | grep /mnt

read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1



#    Installs 



reflector --latest 10 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist

pacstrap -K /mnt base linux linux-firmware intel-ucode

pacstrap -K /mnt btrfs-progs cryptsetup networkmanager sudo base-devel git

pacstrap -K /mnt zram-generator snapper snap-pac tpm2-tools

pacstrap -K /mnt limine efibootmgr dosfstools mtools

pacstrap -K /mnt nano bash-completion openssh gobject-introspection

genfstab -U /mnt > /mnt/etc/fstab



# Chroot

arch-chroot /mnt pacman -Q limine efibootmgr btrfs-progs cryptsetup

arch-chroot /mnt ls /usr/lib/initcpio/install/sd-encrypt

arch-chroot /mnt sh -c "echo 'KEYMAP=colemak' > /etc/vconsole.conf"

arch-chroot /mnt sed -i \
  's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
  /etc/mkinitcpio.conf
  
arch-chroot /mnt mkinitcpio -P

## Network

arch-chroot /mnt systemctl enable NetworkManager



# Users 


read -rp "Hostname [CHANGEME]: " h

[[ "$HOSTNAME" != CHANGEME ]] || { echo "Set a hostname" >&2; exit 1; }


read -rp "Username [CHANGEME]: " u

[[ "$USERNAME" != CHANGEME ]] || { echo "Set a username" >&2; exit 1; }


echo Set Root Passwd
retry arch-chroot /mnt passwd

if ! arch-chroot /mnt id -u "$USERNAME" &>/dev/null; then
	arch-chroot /mnt useradd -m -G wheel "$USERNAME"
fi

clear > /dev/tty
echo Set User Passwd
retry arch-chroot /mnt passwd "$USERNAME"

clear > /dev/tty
echo ENTER ENCRYPTION PASSWD

arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers


# Bootloader



cat > /mnt/root/_setup.sh << CHROOTEOF
set -euo pipefail

retry() {
    until "\$@"; do
        echo "That attempt failed. Trying again." >&2
    done
}

mkdir -p /etc/cryptsetup-keys.d

dd if=/dev/urandom of=/etc/cryptsetup-keys.d/data.key bs=1024 count=4

chmod 600 /etc/cryptsetup-keys.d/data.key

retry cryptsetup luksAddKey $DATA_PART /etc/cryptsetup-keys.d/data.key

DATA_UUID=\$(blkid -s UUID -o value $DATA_PART)

echo "cryptdata UUID=\$DATA_UUID /etc/cryptsetup-keys.d/data.key luks" >> /etc/crypttab

mkdir -p /boot/EFI/limine
mkdir -p /boot/EFI/BOOT

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI


find /boot -iname "*.efi"

efibootmgr --create --disk $SYSTEM_DISK --part 1 \
    --label "Arch Linux Limine Boot Loader" --loader '\EFI\limine\limine_x64.efi' --unicode
efibootmgr -v

LUKS_UUID=\$(blkid -s UUID -o value $SYS_ROOT)

cat > /boot/EFI/limine/limine.conf << ENTRYEOF
timeout: 1
/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux.img
    cmdline: rd.luks.name=\$LUKS_UUID=cryptsystem root=/dev/mapper/cryptsystem rootflags=subvol=@ rw
ENTRYEOF
CHROOTEOF

arch-chroot /mnt bash /root/_setup.sh
rm /mnt/root/_setup.sh


# End

cp /var/log/install/iso.log /mnt/var/log/

cp "$CONFIG" /mnt/home/"$USERNAME"/.install-config
	sudo chown 1000:1000 /mnt/home/"$USERNAME"/.install-config

umount -R /mnt

lsblk

echo "Reboot"




