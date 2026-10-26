#!/usr/bin/env bash

# Ai - rescue, run from the Arch USB when the installed system will not start
#      it unlocks the system disk and offers two ways back:
#        undo     put the system back to a snapshot from before the trouble,
#                 the broken one is kept aside, nothing is deleted
#        shell    open a terminal inside the installed system, to fix by hand
#      your data disk is never touched

LOG=/tmp/nug-rescue.log
export LOG

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

T=/mnt
TOP=/tmp/nug-top

title "Rescue" "from the Arch USB, when the system will not start"


step "Unlock"

(( EUID == 0 )) || die "run it as root, the Arch ISO already is"
quiet loadkeys "$KEYMAP" || true

SYS="$(lsblk -pnro NAME,PARTLABEL | awk '$2 == "cryptsystem" {print $1}' | head -n 1)"
[[ -n "$SYS" ]] || die "no system disk found, it is the partition named cryptsystem"
ok "system disk: $SYS"
DISK="/dev/$(lsblk -no PKNAME "$SYS" | head -n 1)"
ESP="$(lsblk -pnro NAME,PARTLABEL "$DISK" | awk '$2 == "ESP" {print $1}' | head -n 1)"

	# Ai - the installed system, with its boot partition, logs and cache
mount_system() {
	mount -o subvol=/@ /dev/mapper/cryptsystem "$T"
	if [[ -n "$ESP" ]]; then mount "$ESP" "$T/boot"; fi
	mount -o subvol=/@log /dev/mapper/cryptsystem "$T/var/log" 2> /dev/null || true
	mount -o subvol=/@pkg /dev/mapper/cryptsystem "$T/var/cache/pacman/pkg" 2> /dev/null || true
}

if [[ ! -e /dev/mapper/cryptsystem ]]; then
	dim "Type the disk passphrase."
	cryptsetup open "$SYS" cryptsystem < /dev/tty || die "it did not unlock"
fi
mkdir -p "$TOP"
mountpoint -q "$TOP" || mount -o subvolid=5 /dev/mapper/cryptsystem "$TOP"
ok "unlocked"


step "Choose"

printf '\n'
dim "1  undo: go back to a snapshot"
dim "2  shell: a terminal inside the installed system"
printf '\n'
WAY="$(ask "Which" "1")"

if [[ "$WAY" == 2 ]]; then
	mount_system
	dim "Inside now. pacman, mkinitcpio and the rest work as usual. Type exit when done."
	arch-chroot "$T" || true
	umount -R "$T"
	umount "$TOP"
	ok "closed, take out the USB and restart"
	exit 0
fi


step "Snapshots"

	# Ai - newest first, with snapper's own date and description
printf '\n    %s#    date              what%s\n' "$C_DIM" "$C_0"
NUMS=()
while IFS= read -r d; do
	info="$TOP/@snapshots/$d/info.xml"
	[[ -f "$info" && -d "$TOP/@snapshots/$d/snapshot" ]] || continue
	when="$(sed -n 's:.*<date>\(.*\)</date>.*:\1:p' "$info" | cut -c1-16)"
	what="$(sed -n 's:.*<description>\(.*\)</description>.*:\1:p' "$info")"
	printf '    %-4s %-17s %s\n' "$d" "$when" "${what:-timeline}"
	NUMS+=("$d")
done < <(find "$TOP/@snapshots" -mindepth 1 -maxdepth 1 -printf '%f\n' 2> /dev/null | grep -E '^[0-9]+$' | sort -n -r | head -n 25)
(( ${#NUMS[@]} )) || die "no snapshots found"
printf '\n'
dim "snap-pac makes a pair around every update, pick the one before it, the pre."

while true; do
	N="$(ask "Snapshot number" "${NUMS[1]:-${NUMS[0]}}")"
	[[ " ${NUMS[*]} " == *" $N "* ]] && break
	printf '      pick a number from the list\n' > /dev/tty
done


step "Undo"

STAMP="$(date +%F-%H%M)"
printf '\n    The system goes back to snapshot %s.\n' "$N"
printf '    The current one is kept as %s@broken-%s%s, nothing is deleted.\n\n' "$C_B" "$STAMP" "$C_0"
if ! confirm_word UNDO; then
	umount "$TOP"
	printf '\n    Nothing was changed.\n\n'
	exit 0
fi

run "keep the broken system aside" mv "$TOP/@" "$TOP/@broken-$STAMP"
run "put snapshot $N in its place" btrfs subvolume snapshot "$TOP/@snapshots/$N/snapshot" "$TOP/@"

	# Ai - the boot files live outside the snapshot, so they still belong to
	#      the newer system, they are rebuilt from the kernel inside the
	#      snapshot, the same way pacman does after a kernel update, and signed
	#      again, or Secure Boot would refuse them
run "open the restored system" mount_system
run "boot files for the restored kernel" arch-chroot "$T" sh -c \
	'ls -d /usr/lib/modules/*/vmlinuz | sed "s|^/||" | /usr/share/libalpm/scripts/mkinitcpio install'
if [[ -d "$T/var/lib/sbctl/keys" || -d "$T/usr/share/secureboot/keys" ]]; then
	run "sign them for Secure Boot" arch-chroot "$T" sbctl sign-all
fi
umount -R "$T"
umount "$TOP"

todo "Take out the USB and restart. The system is back as it was at snapshot $N."
todo "Once it works, delete the broken copy:  sudo mount -o subvolid=5 /dev/mapper/cryptsystem /mnt
then:  sudo btrfs subvolume delete /mnt/@broken-$STAMP"
finish
