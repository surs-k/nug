#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base

[[ -n "${PC_NAME:-}" && -n "${PC_USER:-}" ]] || { printf 'No PC name or username in %s\n' "$CONFIG" >&2; exit 1; }



#    Moonlight


section "Moonlight"

	# Ai - Moonlight is the viewer for Sunshine, which runs on the PC
	#      qt6-wayland lets it open as a normal Wayland window under Hyprland,
	#      and it decodes on the GPU through the driver 20-desktop installed

pac moonlight-qt qt6-wayland



#    Key


section "Key"

	# Ai - one key for this laptop, with no passphrase of its own
	#      it sits on a disk that is encrypted, and the lock screen guards the
	#      session, a second passphrase for every pc would only get it skipped
	#      the PC takes keys only once any key is on it, so this one has to be
	#      added there, pc copykey does that

KEY="$HOME/.ssh/id_ed25519"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ -f "$KEY" ]]; then
	note "ssh key already there"
else
	run "make the ssh key" ssh-keygen -t ed25519 -N "" -C "$USERNAME@$HOSTNAME" -f "$KEY"
fi



#    Command


section "Command"

$SUDO install -m 755 "$SCRIPTS/pc.sh" /usr/local/bin/pc

note "pc installed"

todo "Put this laptop's key on your PC, once:  pc copykey
If the PC refuses passwords it prints one line to add at the PC itself."

todo "Pair Moonlight with Sunshine on the PC, once:  pc pair
It shows a link, open it on any device on your tailnet, and type the PIN in."



#    Verify


section "Verify"

check "moonlight"        command -v moonlight
check "ssh key"          test -f "$KEY"
check "pc command"       test -x /usr/local/bin/pc
check "PC name saved"    grep -q '^PC_NAME=' "$CONFIG"

verify_done

stage_done



#    End


section "End"

printf '  Ready. From a terminal:\n\n'
printf '    pc view     your PC screen\n'
printf '    pc          a terminal on your PC\n\n'
