#!/usr/bin/env bash

	# Ai - pc
	#      the laptop's one way to your PC, installed by 80-remote as
	#      /usr/local/bin/pc
	#      pc            a terminal on the PC
	#      pc view       start Sunshine on the PC, open its screen, and stop
	#                    Sunshine again when you close the window
	#      pc off        stop Sunshine on the PC
	#      pc pair       the pairing of Moonlight with Sunshine, once
	#      pc copykey    put this laptop's ssh key on the PC, once
	#      the PC is found by its name on the tailnet, asked of tailscale every
	#      time, so there is no address to remember and no DNS involved
	#      Sunshine on the PC runs only while you ask for it, its own remote
	#      command starts and stops it, and that is what this calls over ssh

set -euo pipefail

CONFIG="$HOME/.install-config"

	# Ai - read, never sourced, it is a file of answers and nothing more
cfg() { sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | tail -n 1; }

PC_NAME="$(cfg PC_NAME)"
PC_USER="$(cfg PC_USER)"
PC_APP="$(cfg PC_APP)"
PC_APP="${PC_APP:-Desktop}"

	# Ai - 1080p at 60 with H.264, which every laptop can decode, set PC_STREAM
	#      in the environment to change it for one run
STREAM="${PC_STREAM:---resolution 1920x1080 --fps 60 --video-codec H.264}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10)

REMOTE=/usr/local/bin/remote


#    Helpers


die() { printf 'pc: %s\n' "$*" >&2; exit 1; }

[[ -n "$PC_NAME" && -n "$PC_USER" ]] || die "no PC name or username in $CONFIG"

command -v tailscale > /dev/null || die "tailscale is not installed"

find_pc() {
	local ip
	ip="$(tailscale ip -4 "$PC_NAME" 2>/dev/null | head -n 1 || true)"
	[[ -n "$ip" ]] || die "cannot find $PC_NAME on the tailnet, is the PC on? check: tailscale status"
	printf '%s' "$ip"
}

sunshine_up() {
	local i
	for i in $(seq 1 20); do
		if timeout 1 bash -c "exec 3<>/dev/tcp/$IP/47989" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

sunshine_on() {
	printf 'starting Sunshine on %s\n' "$PC_NAME"
	ssh "${SSH_OPTS[@]}" "$PC_USER@$IP" "$REMOTE" on \
		|| die "could not start Sunshine on the PC, has its ssh key been added? try: pc copykey"
	trap sunshine_off EXIT
	sunshine_up || die "Sunshine did not answer on the PC within 20 seconds"
}

sunshine_off() {
	ssh "${SSH_OPTS[@]}" "$PC_USER@$IP" "$REMOTE" off > /dev/null 2>&1 || true
}

usage() {
	cat << 'USAGEEOF'

  pc            a terminal on your PC
  pc view       your PC screen, Sunshine is on only while it is open
  pc off        stop Sunshine on the PC
  pc pair       pair Moonlight with the PC, once
  pc copykey    put this laptop's ssh key on the PC, once

USAGEEOF
}


#    Main


case "${1:-}" in

	"")
		IP="$(find_pc)"
		exec ssh "${SSH_OPTS[@]}" "$PC_USER@$IP" ;;

	view)
		command -v moonlight > /dev/null || die "moonlight is not installed, run: rebuild --only 80-remote"
		IP="$(find_pc)"
		sunshine_on
		moonlight stream "$IP" "$PC_APP" $STREAM || true ;;

	off)
		IP="$(find_pc)"
		sunshine_off
		printf 'Sunshine is off\n' ;;

	pair)
		command -v moonlight > /dev/null || die "moonlight is not installed, run: rebuild --only 80-remote"
		IP="$(find_pc)"
		sunshine_on
		printf '\nType the PIN below into Sunshine on the PC, on its PIN tab:\n\n'
		printf '  https://%s:47990\n\n' "$IP"
		printf 'Open that on any device on your tailnet, or on the PC itself.\n\n'
		moonlight pair "$IP" || true ;;

	copykey)
		IP="$(find_pc)"
		KEY="$HOME/.ssh/id_ed25519.pub"
		[[ -f "$KEY" ]] || die "no key at $KEY, run: rebuild --only 80-remote"
		if ssh-copy-id -i "$KEY" -o StrictHostKeyChecking=accept-new "$PC_USER@$IP"; then
			printf '\nDone. Try:  pc\n'
		else
			printf '\nThe PC would not take it over ssh.\n'
			printf 'At the PC, add this one line to ~/.ssh/authorized_keys:\n\n'
			cat "$KEY"
			printf '\n'
		fi ;;

	-h|--help|help)
		usage ;;

	*)
		printf 'unknown command: %s\n' "$1" >&2
		usage >&2
		exit 2 ;;
esac
