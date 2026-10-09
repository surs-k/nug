#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"

stage_banner "iso" "partitions, encryption, base system, boot menu" "installer   $(date +%H:%M)"


#    Answers


section "Answers"

	# Ai - every question in the whole install lives in this one block
	#      after the last password nothing else is asked until the end
	#      subjects are split by an arrow line, with one extra blank line
	#      after a long subject, as laid out in the v7.0 review

act_text "Everything you type is in this section.

After the last password the install runs on its own."


## Firmware

if [[ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || true)" != "64" ]]; then
	printf 'Not booted in 64 bit UEFI mode. Aborting.\n' >&2
	exit 1
fi


## Leftovers

	# Ai - if an earlier attempt stopped partway it left mappers open and /mnt
	#      mounted, and the retry would then fail on device busy rather than
	#      simply starting over

mountpoint -q /mnt && umount -R /mnt

for m in cryptsystem; do
	if [[ -e "/dev/mapper/$m" ]]; then
		cryptsetup close "$m" 2>/dev/null || true
		note "closed a leftover $m from an earlier attempt"
	fi
done


## Clock

	# Ai - no loadkeys here, you load your layout before starting because you
	#      type the commands in it, and every password after uses that same one

timedatectl set-ntp true


## Network

	# Ai - a laptop usually has Wi-Fi only, and the installer does not join it
	#      by itself, so when there is no way out yet it is asked for here
	#      iwctl asks for the passphrase itself, so it never appears in a command
	#      line, and an empty name skips this and goes on to the retry below

wifi_device() {
	local d
	for d in /sys/class/net/*/wireless; do
		[[ -d "$d" ]] && { basename "$(dirname "$d")"; return 0; }
	done
	return 1
}

join_wifi() {
	local dev ssid

	dev="$(wifi_device)" || return 0

	act_next
	act_line "No network yet. Join your Wi-Fi."
	act_line ""

	iwctl station "$dev" scan > /dev/null 2>&1 || true
	sleep 3
	iwctl station "$dev" get-networks 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | act_feed || true
	act_line ""

	while true; do
		ssid="$(ask 'Wi-Fi name, empty to skip')"
		[[ -n "$ssid" ]] || return 0
		iwctl station "$dev" connect "$ssid" && break
		act_line "Did not connect, try again."
	done

	sleep 3
}

if ! online &> /dev/null; then
	join_wifi
fi

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


## Disk

	# Ai - one disk, the external SSD, and everything on it is erased
	#      the installer USB is found and never accepted, erasing it would erase
	#      the thing this install is running from
	#      the wipe is confirmed right here, while the choice is still on screen
	#      anything but YES asks for the disk again

LIVE_SRC="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
LIVE_DISK=""

if [[ -n "$LIVE_SRC" ]]; then
	LIVE_PARENT="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null | head -n 1 || true)"
	LIVE_DISK="/dev/${LIVE_PARENT:-${LIVE_SRC#/dev/}}"
fi

while true; do
	act_next big
	act_line "Pick the SSD. IT IS COMPLETELY ERASED."
	act_line ""
	lsblk -o NAME,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS | act_feed
	act_line ""
	if [[ -n "$LIVE_DISK" ]]; then
		act_line "The installer USB is $LIVE_DISK, it cannot be picked."
		act_line ""
	fi

	SYSTEM_DISK="$(pick_disk 'SSD: ')"

	if [[ -n "$LIVE_DISK" && "$SYSTEM_DISK" == "$LIVE_DISK" ]]; then
		act_line ""
		act_line "That is the installer USB, pick the SSD."
		continue
	fi

	act_next
	act_line "Check this, then type YES."
	act_line ""
	act_line "SSD  $SYSTEM_DISK  $(lsblk -dno SIZE "$SYSTEM_DISK")  $(lsblk -dno MODEL "$SYSTEM_DISK")  WILL BE WIPED"
	act_line ""

	confirmed "Type YES to go ahead, anything else to pick again" && break

	act_line ""
	act_line "Nothing erased."
done

require_disk "$SYSTEM_DISK"


## Passwords

act_next big
act_text "Set three passwords, each typed twice.

The disk passphrase is asked at every boot, pick one you can type quickly."
act_line ""

LUKS_PASS="$(secret_twice 'Disk passphrase')"

act_next

ROOT_PASS="$(secret_twice 'Root password')"

act_next

USER_PASS="$(secret_twice "Password for $USERNAME")"

act_close

note "Hands off from here."



#    Partitions


section "Partitions"


## Disk

	# Ai - 1 GiB is the boot partition, the kernel and its initramfs and
	#      nothing else, there are no snapshot boot entries on this machine

run "wipe the SSD"      sgdisk --zap-all "$SYSTEM_DISK"
run "efi partition"     sgdisk -n1:0:+1G -t1:EF00 -c1:"EFI"         "$SYSTEM_DISK"
run "root partition"    sgdisk -n2:0:0   -t2:8300 -c2:"cryptsystem" "$SYSTEM_DISK"

run "reread table"      partprobe "$SYSTEM_DISK"


## Names

SYS_ESP="$(partname "$SYSTEM_DISK" 1)"
SYS_ROOT="$(partname "$SYSTEM_DISK" 2)"

udevadm settle

wait_for 10 test -b "$SYS_ESP"
wait_for 10 test -b "$SYS_ROOT"

	# Ai - an old install on the SSD leaves signatures inside the new partitions
run "clear old signatures" wipefs --all "$SYS_ESP" "$SYS_ROOT"



#    Encrypt


section "Encrypt"

	# Ai - the passphrase goes to a file on /run, which is a tmpfs and never
	#      touches a disk
	#      not on stdin, because a backgrounded job cannot reliably inherit a pipe
	#      not as an argument, because arguments are visible in the process table

KEYTMP=/run/rebuild.key

( umask 077; printf '%s' "$LUKS_PASS" > "$KEYTMP" )

KEYSUM="$(sha256sum "$KEYTMP" | cut -d' ' -f1)"


## Cost

	# Ai - the argon2 memory cost is pinned rather than benchmarked
	#      left to benchmark, luksFormat sizes the cost against whatever RAM is
	#      free at that instant, and every later unlock has to allocate that same
	#      amount again
	#      256 MiB is strong for a disk passphrase and fits any laptop you will
	#      run this on, including a small test VM

LUKSFMT=(
	--type luks2
	--batch-mode
	--pbkdf argon2id
	--pbkdf-memory 262144
	--iter-time 2000
)


## Guard

	# Ai - confirm the key file is byte for byte what we wrote, before each use
keyguard() {
	local now
	now="$(sha256sum "$KEYTMP" | cut -d' ' -f1)"
	[[ "$now" == "$KEYSUM" ]] \
		|| { printf 'The key file changed underneath us, stopping\n' >&2; exit 1; }
}


## Disk

encrypt_disk() {
	local part=$1 name=$2

	keyguard

	run "format $name"  cryptsetup luksFormat "${LUKSFMT[@]}" --key-file "$KEYTMP" "$part"

		# Ai - prove the passphrase actually opens it before going further, so a
		#      mismatch surfaces at the step that caused it rather than later
	run "verify $name"  cryptsetup open --test-passphrase --key-file "$KEYTMP" "$part"

	run "open $name"    cryptsetup open --batch-mode --key-file "$KEYTMP" "$part" "$name"
}

encrypt_disk "$SYS_ROOT"  cryptsystem



#    Filesystems


section "Filesystems"


## Format

run "format esp"         mkfs.fat -F32 "$SYS_ESP"
run "format system"      mkfs.btrfs -f -L system /dev/mapper/cryptsystem


## Subvols

	# Ai - @snapshots is a sibling of @, never nested inside it
	#      nested snapshots are destroyed by their own rollback
	#      @home is its own subvolume, so rolling the system back never touches
	#      your files
run "mount system top"   mount /dev/mapper/cryptsystem /mnt
run "create @"           btrfs subvolume create /mnt/@
run "create @snapshots"  btrfs subvolume create /mnt/@snapshots
run "create @home"       btrfs subvolume create /mnt/@home
run "unmount system top" umount /mnt


## Mount

OPTS="compress=zstd:1,noatime"

mount -o "$OPTS,subvol=@" /dev/mapper/cryptsystem /mnt

mount --mkdir -o "$OPTS,subvol=@snapshots" /dev/mapper/cryptsystem /mnt/.snapshots

mount --mkdir "$SYS_ESP" /mnt/boot

mount --mkdir -o "$OPTS,subvol=@home" /dev/mapper/cryptsystem /mnt/home

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

	# Ai - an ISO older than a package signature reads as a bad signature
	#      refreshing the live keyring first removes that whole class of failure
run "refresh package db"  pacman -Sy --noconfirm

soft "update keyring"     pacman -S --noconfirm --needed archlinux-keyring


## Microcode

	# Ai - the CPU decides which package, an Intel one is no use on an AMD chip
UCODE=""

case "$(sed -n 's/^vendor_id[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)" in
	GenuineIntel) UCODE=intel-ucode ;;
	AuthenticAMD) UCODE=amd-ucode ;;
esac

if [[ -n "$UCODE" ]]; then
	note "microcode: $UCODE"
else
	note "unknown CPU vendor, no microcode package"
fi


## Base

	# Ai - a corrupt download is cached, so a plain retry reuses the same bad
	#      file forever and fails identically every time
	#      the cache is purged and the mirrors re-ranked between attempts, so a
	#      single bad mirror cannot end the run

pacstrap_retry() {
	local attempt=1

	until pacstrap -K /mnt "$@"; do

		if (( attempt >= 3 )); then
			printf '\n  pacstrap failed %s times for: %s\n' "$attempt" "$*" >&2
			printf '  the mirror may be broken, try again later\n\n' >&2
			return 1
		fi

			# Ai - announced, not listed, a retry that works leaves nothing to fix
		info "download was corrupt, purging the cache and switching mirrors"

		rm -f /mnt/var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null || true
		rm -f /var/cache/pacman/pkg/*.pkg.tar.zst     2>/dev/null || true

		reflector --latest 20 --protocol https --sort rate \
			--save /etc/pacman.d/mirrorlist 2>/dev/null || true

		attempt=$(( attempt + 1 ))
		sleep 3
	done
}

pacstrap_retry base linux linux-firmware ${UCODE:+"$UCODE"}

pacstrap_retry btrfs-progs cryptsetup networkmanager wpa_supplicant wireless-regdb sudo git

pacstrap_retry zram-generator snapper snap-pac

pacstrap_retry limine efibootmgr dosfstools mtools

pacstrap_retry nano bash-completion openssh reflector


## Fstab

genfstab -U /mnt > /mnt/etc/fstab

	# Ai - / is mounted by name only, see Fstab in 00-lib for why
	#      without this a snapshot restore would boot the old broken system
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

	# Ai - written directly, never through hostnamectl
	#      arch-chroot bind mounts /run, so hostnamectl in the chroot reaches the
	#      live ISO's systemd over dbus, renames the ISO instead of the install,
	#      and exits 0, so the fallback that writes this file never ran
printf '%s\n' "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF


## Hooks

	# Ai - no autodetect, so the initramfs carries every storage and USB driver
	#      autodetect keeps only what the machine it was built on uses, and an
	#      SSD that is moved to another port or another laptop then fails to boot
	#      no kms either, the passphrase prompt is text and needs no graphics
	#      one image is enough, with no autodetect it is already the generic one
arch-chroot /mnt sed -i \
	's/^HOOKS=.*/HOOKS=(base systemd microcode modconf keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
	/etc/mkinitcpio.conf

arch-chroot /mnt sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux.preset

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

	# Ai - lecture never, the first sudo of the run otherwise prints a paragraph
	#      of advice in the middle of the question block
	#      proven with visudo before it counts, a broken file here disables sudo
printf '%%wheel ALL=(ALL:ALL) ALL\nDefaults lecture = never\n' > /mnt/etc/sudoers.d/10-wheel
chmod 440 /mnt/etc/sudoers.d/10-wheel

run "check sudo rules" arch-chroot /mnt visudo -c -f /etc/sudoers.d/10-wheel



#    Bootloader


section "Bootloader"


## Setup

	# Ai - no TPM on this machine, the SSD can move between laptops and a key
	#      sealed to one TPM only opens it in that one, the passphrase is the key
	#      efibootmgr is allowed to fail, some laptops refuse a boot entry for a
	#      USB disk, and the fallback path below boots without one
cat > /mnt/root/_setup.sh << CHROOTEOF
set -euo pipefail


	# Ai - limine ships no deploy hook of its own, both copies are ours to keep current

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


	# Ai - limine reads the directory holding its own efi binary first
	#      any limine.conf there silently outranks /boot/limine.conf
rm -f /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf


efibootmgr --create --disk $SYSTEM_DISK --part 1 \\
	--label "Arch Linux Limine Boot Loader" \\
	--loader '\\EFI\\limine\\limine_x64.efi' --unicode \\
	|| echo "no boot entry made, the fallback path still boots"

LUKS_UUID=\$(blkid -s UUID -o value $SYS_ROOT)

systemd-machine-id-setup

	# Ai - /@ with the slash, the snapshot tool only recognises that spelling
	#      subvol=@ and subvol=/@ mount the same thing
printf 'rd.luks.name=%s=cryptsystem root=/dev/mapper/cryptsystem rootflags=subvol=/@ rw\n' \\
	"\$LUKS_UUID" > /etc/kernel/cmdline

	# Ai - the boot menu is not written here
	#      the Menu block below writes it with the same tool 10-base installs
CHROOTEOF


## Run

arch-chroot /mnt bash /root/_setup.sh

rm -f /mnt/root/_setup.sh

	# Ai - shred overwrites disk blocks, and tmpfs has none
	#      what actually protects the key is that it only ever lived in RAM
rm -f "$KEYTMP"

unset LUKS_PASS


## Menu

	# Ai - one tool writes the boot menu, here and on every later change
	#      it builds the menu from the real kernel files and the cmdline above,
	#      checks the result would start on its own, and only then saves it
	#      nested shape: /+Arch Linux is an open folder, Linux is the first
	#      thing in it, default_entry 2 points at Linux, quiet stays off
	#      the old black screen was default_entry pointing at the folder with
	#      quiet hiding why, the check refuses exactly that
install -Dm755 "$SCRIPTS/limine-header-fix.sh" /mnt/usr/local/bin/limine-header-fix

printf 'BOOT_MODE=nested\nBOOT_TIMEOUT=%s\n' "$LIMINE_TIMEOUT" > /mnt/etc/rebuild-boot.conf

run "write boot menu" bash "$SCRIPTS/limine-header-fix.sh" --root /mnt

bash "$SCRIPTS/limine-header-fix.sh" --root /mnt --check || true



#    Handover


section "Handover"


## Repo

	# Ai - the whole repo travels with the install so the next stages are local
install -d -o 1000 -g 1000 "/mnt/home/$USERNAME/rebuild"

cp -r "$REPO/." "/mnt/home/$USERNAME/rebuild/"

chown -R 1000:1000 "/mnt/home/$USERNAME/rebuild"

find "/mnt/home/$USERNAME/rebuild" -name '*.sh' -exec chmod +x {} +

	# Ai - git records the executable bit, so the chmod above shows up as a local
	#      change to every script, and git pull then refuses to overwrite them
	#      telling git to ignore modes makes pulls clean from here on
if [[ -d "/mnt/home/$USERNAME/rebuild/.git" ]]; then
	arch-chroot /mnt sudo -u "$USERNAME" \
		git -C "/home/$USERNAME/rebuild" config core.fileMode false || true
fi


## Config

install -o 1000 -g 1000 -m 600 "$CONFIG" "/mnt/home/$USERNAME/.install-config"


## Wifi

	# Ai - the installer's Wi-Fi is iwd and the installed system uses
	#      NetworkManager, so each saved network is written out again in
	#      NetworkManager's format, otherwise the first boot is offline and the
	#      next step has nothing to download with
	#      iwd names a file after the network, and a name with anything but
	#      letters, digits, space, dash or underscore is = then hex
	#      a network that cannot be carried is skipped, nmtui joins it later

IWD_DIR="${IWD_DIR:-/var/lib/iwd}"
NM_OUT="${NM_OUT:-/mnt/etc/NetworkManager/system-connections}"

iwd_name() {
	local raw=$1 hex out="" i

	if [[ "$raw" == =* ]]; then
		hex="${raw#=}"
		for (( i = 0; i < ${#hex}; i += 2 )); do
			out+="$(printf "\\x${hex:i:2}")"
		done
		printf '%s' "$out"
	else
		printf '%s' "$raw"
	fi
}

carry_wifi() {
	local f base ssid psk file count=0

	[[ -d "$IWD_DIR" ]] || return 0

	install -d -m 700 "$NM_OUT"

	for f in "$IWD_DIR"/*.psk "$IWD_DIR"/*.open; do
		[[ -f "$f" ]] || continue

		base="$(basename "$f")"
		base="${base%.*}"
		ssid="$(iwd_name "$base")"

		[[ -n "$ssid" ]] || continue

		psk=""

		if [[ "$f" == *.psk ]]; then
			psk="$(sed -n 's/^Passphrase=//p' "$f" | head -n 1)"
			[[ -n "$psk" ]] || psk="$(sed -n 's/^PreSharedKey=//p' "$f" | head -n 1)"
			[[ -n "$psk" ]] || continue
		fi

		file="$NM_OUT/$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9._-' '_').nmconnection"

		{
			printf '[connection]\n'
			printf 'id=%s\n' "$ssid"
			printf 'uuid=%s\n' "$(cat /proc/sys/kernel/random/uuid)"
			printf 'type=wifi\n'
			printf 'autoconnect=true\n\n'
			printf '[wifi]\n'
			printf 'mode=infrastructure\n'
			printf 'ssid=%s\n\n' "$ssid"
			if [[ -n "$psk" ]]; then
				printf '[wifi-security]\n'
				printf 'key-mgmt=wpa-psk\n'
				printf 'psk=%s\n\n' "$psk"
			fi
			printf '[ipv4]\n'
			printf 'method=auto\n\n'
			printf '[ipv6]\n'
			printf 'addr-gen-mode=default\n'
			printf 'method=auto\n'
		} > "$file"

		chmod 600 "$file"

		count=$(( count + 1 ))
	done

	if (( count > 0 )); then
		note "Wi-Fi carried over: $count saved network(s)"
	else
		info "no saved Wi-Fi to carry over, join it with nmtui on the first boot"
	fi
}

carry_wifi


## Logs

install -d /mnt/var/log/install

cp "$LOG" /mnt/var/log/install/ 2>/dev/null || true



#    Verify


section "Verify"

check "esp mounted"      mountpoint -q /mnt/boot
check "root mounted"     mountpoint -q /mnt
check "home mounted"     mountpoint -q /mnt/home
check "snapshots sib"    sh -c 'findmnt -no SOURCE /mnt/.snapshots | grep -q "@snapshots"'
check "menu starts alone" bash "$SCRIPTS/limine-header-fix.sh" --root /mnt --check
check "menu tool copied"  test -x /mnt/usr/local/bin/limine-header-fix
check "menu settings"     test -f /mnt/etc/rebuild-boot.conf
check "kernel present"   test -f /mnt/boot/vmlinuz-linux
check "initramfs present" test -f /mnt/boot/initramfs-linux.img
check "no autodetect"    sh -c '! grep -q "^HOOKS=.*autodetect" /mnt/etc/mkinitcpio.conf'
if [[ -n "$UCODE" ]]; then
	check "microcode present" test -f "/mnt/boot/$UCODE.img"
fi
check "cmdline has luks"  grep -q 'rd.luks.name=' /mnt/boot/limine.conf
check "cmdline names /@"  grep -q 'rootflags=subvol=/@' /mnt/etc/kernel/cmdline
check "fstab / by name"   fstab_root_named /mnt/etc/fstab
check "no efi conf"      sh -c '! test -f /mnt/boot/EFI/limine/limine.conf'
check "deploy hook"      test -f /mnt/etc/pacman.d/hooks/99-limine-deploy.hook
check "efi binary"       test -f /mnt/boot/EFI/limine/limine_x64.efi
check "fallback binary"  test -f /mnt/boot/EFI/BOOT/BOOTX64.EFI
check "repo copied"      test -f "/mnt/home/$USERNAME/rebuild/scripts/run.sh"

	# Ai - only a note, some laptops refuse a boot entry for a USB disk and the
	#      fallback binary above is what boots them
warn  "efi entry made"    sh -c 'efibootmgr | grep -q Limine'

verify_done

stage_done iso



#    End


section "End"

umount -R /mnt

lsblk

printf '\n'
printf '  Remove the installer USB, leave the SSD in, and reboot.\n'
printf '  Secure Boot has to be off, Limine is not signed.\n'
printf '\n'
printf '  Then log in and run:\n'
printf '\n'
printf '    bash ~/rebuild/scripts/run.sh\n'
printf '\n'
printf '  After that first run it is just:\n'
printf '\n'
printf '    rebuild\n'
printf '\n'
