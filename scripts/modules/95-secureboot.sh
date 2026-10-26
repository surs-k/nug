#!/usr/bin/env bash

# Ai - secureboot: the firmware starts only what you signed, with your own
#      keys, so nobody can swap in a changed boot file while the PC is off
#      it needs the firmware in setup mode, which only you can do, so the
#      first run usually ends with that step for you, and the second finishes
#      exit 10 tells rebuild it is waiting on you, so it is not marked done

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Secure Boot" "your own keys, so only what you signed starts"


step "Status"

	# Ai - sbctl answers in JSON, read without needing jq
STATUS="$($SUDO sbctl status --json 2> /dev/null || printf '{}')"
flag() { [[ "$STATUS" == *"\"$1\":true"* || "$STATUS" == *"\"$1\": true"* ]]; }

if flag secure_boot && flag installed; then
	ok "Secure Boot is on, with your keys"
	SB=on
elif flag setup_mode; then
	ok "the firmware is in setup mode, ready for your keys"
	SB=setup
else
	SB=off
fi


step "Keys"

if [[ "$SB" == off ]]; then
	dim "The firmware is not in setup mode yet, that step is yours."
	todo "Secure Boot, part 1 of 2: run  systemctl reboot --firmware-setup
In the firmware, find Secure Boot, choose  Reset to Setup Mode  or  Clear all keys,
save and start Arch. Then run:  rebuild secureboot"
	exit 10
fi

if [[ "$SB" == setup ]]; then
	flag installed || run "make your keys" $SUDO sbctl create-keys
	# Ai - Microsoft's keys are enrolled too: the graphics card's own firmware
	#      is signed by Microsoft, and without them the screen can stay black
	run "enroll your keys" $SUDO sbctl enroll-keys --microsoft
fi


step "Sign"

	# Ai - the boot images and the boot menu, sbctl re-signs them by itself
	#      after every update from now on
for f in /boot/EFI/Linux/*.efi; do
	run "sign ${f##*/}" $SUDO sbctl sign -s "$f"
done
run "sign the boot menu" $SUDO sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
	/usr/lib/systemd/boot/efi/systemd-bootx64.efi
run "install the signed menu" $SUDO bootctl install
run "check every signature" $SUDO sbctl verify


step "Check"

if [[ "$SB" == setup ]]; then
	todo "Secure Boot, part 2 of 2: restart into the firmware ( systemctl reboot --firmware-setup ),
turn Secure Boot on, save. Then run  rebuild secureboot  once more to confirm."
	exit 10
fi
ok "Secure Boot on, every boot file signed"
todo "Optional, now Secure Boot is on: unlock the disk with the TPM and a short PIN
instead of the long passphrase:
  sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes /dev/disk/by-partlabel/cryptsystem
The passphrase keeps working too."
