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

(( EUID == 0 )) || die "This is not running as root." "Rescue changes disks." "Run it from the Arch USB, which is root already."
quiet loadkeys "$KEYMAP" || true

SYS="$(lsblk -pnro NAME,PARTLABEL | awk '$2 == "cryptsystem" {print $1}' | head -n 1)"
[[ -n "$SYS" ]] || die "No system disk was found." \
	"Rescue looks for the partition named cryptsystem, and there is none on any disk this PC can see." \
	"Check the disk is connected, or the install never finished, then run it again."
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

until [[ -e /dev/mapper/cryptsystem ]]; do
	ask_program "Type the disk passphrase" "It unlocks the system disk so it can be read." cryptsetup open "$SYS" cryptsystem \
		|| problem "The system disk did not unlock." "A wrong passphrase, or the keyboard layout, is the usual reason." \
			"Try again, and check Caps Lock." retry
done
mkdir -p "$TOP"
mountpoint -q "$TOP" || mount -o subvolid=5 /dev/mapper/cryptsystem "$TOP"
ok "unlocked"


step "Choose"

dim "Rescue asks what to do, then which snapshot, then once more before it changes anything."

SNAPS=() SNAP_ITEMS=()
WAY=1 N=""

q_way() {
	SUGGESTED=1
	choose "What do you want to do?" "Both leave your data disk alone." "${WAY:-1}" \
		"Undo: put the system back to a snapshot from before the trouble" \
		"Shell: a terminal inside the installed system, to fix it by hand" || return $?
	WAY=$CHOICE
	if (( WAY == 1 )); then answered "Rescue" "undo to a snapshot"; else answered "Rescue" "a shell inside the installed system"; fi
}

	# Ai - newest first, with snapper's own date and description
q_snapshot() {
	local d info when what def=1 i
	if (( WAY == 2 )); then return 20; fi
	SNAPS=() SNAP_ITEMS=()
	while IFS= read -r d; do
		info="$TOP/@snapshots/$d/info.xml"
		[[ -f "$info" && -d "$TOP/@snapshots/$d/snapshot" ]] || continue
		when="$(sed -n 's:.*<date>\(.*\)</date>.*:\1:p' "$info" | cut -c1-16)"
		what="$(sed -n 's:.*<description>\(.*\)</description>.*:\1:p' "$info")"
		SNAPS+=("$d")
		SNAP_ITEMS+=("$(printf '%-5s %-17s %s' "$d" "$when" "${what:-timeline}")")
	done < <(find "$TOP/@snapshots" -mindepth 1 -maxdepth 1 -printf '%f\n' 2> /dev/null | grep -E '^[0-9]+$' | sort -n -r | head -n 25)
	(( ${#SNAPS[@]} )) || die "No snapshots were found." "Without one there is nothing to go back to." \
		"Use the shell choice to fix it by hand, or restore from the backup drive."
	if (( ${#SNAPS[@]} > 1 )); then def=2; fi
	for i in "${!SNAPS[@]}"; do if [[ "${SNAPS[i]}" == "$N" ]]; then def=$(( i + 1 )); fi; done
	SUGGESTED=$(( ${#SNAPS[@]} > 1 ? 2 : 1 ))
	choose "Which snapshot should the system go back to?" \
		"snap-pac makes a pair around every update. Pick the one just before the trouble, the pre of the update that broke it." "$def" \
		"${SNAP_ITEMS[@]}" || return $?
	N="${SNAPS[CHOICE-1]}"
	answered "Snapshot" "number $N"
}

undo_body() {
	printf '    The system goes back to snapshot %s%s%s.\n' "$C_B" "$N" "$C_0"
	printf '    The current one is kept as %s@broken-%s%s, nothing is deleted.\n' "$C_B" "$STAMP" "$C_0"
}

STAMP="$(date +%F-%H%M)"

	# Ai - leaving at any point closes what rescue opened
on_quit() {
	umount -R "$T" 2> /dev/null || true
	umount "$TOP" 2> /dev/null || true
}

q_undo() {
	if (( WAY == 2 )); then return 20; fi
	typed UNDO "Go back to snapshot $N?" "This changes the system disk. Your data disk is not touched." undo_body || return $?
}

QUIT_NOTE="Nothing has been changed yet."
run_questions q_way q_snapshot q_undo

if (( WAY == 2 )); then
	mount_system
	dim "Inside now. pacman, mkinitcpio and the rest work as usual. Type exit when done."
	arch-chroot "$T" || true
	umount -R "$T"
	umount "$TOP"
	ok "closed, take out the USB and restart"
	exit 0
fi


step "Undo"

QUIT_NOTE="The undo may be half done. The broken system is kept aside as @broken-$STAMP, and nothing is deleted. Run rescue.sh again, it goes back to the snapshot you pick."
QUIT_CODE=1
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
