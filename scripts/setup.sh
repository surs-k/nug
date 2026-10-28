#!/usr/bin/env bash

# Ai - setup, run as `rebuild` once the PC starts from its own disk
#      it sets up everything after the base system, one module at a time,
#      in order, and remembers what is done, so a rerun continues where it
#      stopped and a finished module is skipped
#
#      rebuild                 every module not done yet
#      rebuild status          what is done, what is next
#      rebuild NAME ...        run these modules again, done or not
#      rebuild apps            the apps, on or off
#      rebuild apps on NAME    turn one on, off works the same
#      rebuild compare         what the old system had that this one lacks, bring it over
#      rebuild --dry-run ...   show what would happen, change nothing

ARGS=()
for a in "$@"; do
	if [[ "$a" == --dry-run ]]; then export DRY=1; else ARGS+=("$a"); fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

STEPS=0
LOG="$HOME/.local/state/nug/logs/rebuild-$(date +%F-%H%M).log"
mkdir -p "$(dirname "$LOG")"
export LOG

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

(( EUID != 0 )) || die "run rebuild as yourself, not as root, it asks for sudo when it needs it"


#    Modules

# Ai - name, what it does, and whether it is optional
#      the order matters: the network before anything that downloads, the
#      desktop before what lives on it, Secure Boot last, it needs you at
#      the firmware
MODULES=(
	"system|packages, updates, swap and housekeeping|core"
	"network|VPN, private DNS and the firewall|core"
	"desktop|Hyprland, the bar, login, sound and the look|core"
	"recovery|snapshots, daily backups, the backup command|core"
	"remote|Tailscale, SSH and streaming to the laptop|core"
	"apps|your apps, chosen in rebuild apps|core"
	"gaming|Steam, Proton tools, MangoHud and GameMode|optional"
	"hosting|Podman and Ollama for local AI|optional"
	"changes|the Changes app and the hourly problem check|core"
	"secureboot|Secure Boot with your own keys|core"
)

mod_file() { local f; for f in "$SCRIPTS"/modules/*-"$1".sh; do printf '%s' "$f"; return 0; done; return 1; }

wanted() {
	[[ "$2" == core ]] && return 0
	[[ "$(choice "module_$1" "")" == on ]]
}


#    Commands

status() {
	local row name what kind mark
	printf '\n  %snug %s%s  ·  rebuild status\n\n' "$C_B" "$NUG_VERSION" "$C_0"
	for row in "${MODULES[@]}"; do
		IFS='|' read -r name what kind <<< "$row"
		if ! wanted "$name" "$kind"; then
			mark="${C_DIM}off ${C_0}"
		elif is_done "$name"; then
			mark="${C_GOOD}done${C_0}"
		else
			mark="${C_WARN}next${C_0}"
		fi
		printf '    %s  %-11s %s%s%s\n' "$mark" "$name" "$C_DIM" "$what" "$C_0"
	done
	printf '\n    %srebuild NAME runs one again, rebuild apps picks your apps%s\n\n' "$C_DIM" "$C_0"
}

case "${1:-}" in
	status|list) status; exit 0 ;;
	apps)        shift; exec bash "$SCRIPTS/apps.sh" "$@" ;;
	compare)     shift; exec bash "$SCRIPTS/compare.sh" "$@" ;;
	-h|--help|help)
		sed -n '/^#      rebuild/s/^#      /  /p' "$0"
		exit 0 ;;
esac

	# Ai - the modules to run: the names given, or every one not done yet
TODO=()
if (( $# > 0 )); then
	for n in "$@"; do
		mod_file "$n" > /dev/null || die "no module called $n, see: rebuild status"
		TODO+=("$n")
	done
else
	for row in "${MODULES[@]}"; do
		IFS='|' read -r name _ kind <<< "$row"
		if wanted "$name" "$kind" && ! is_done "$name"; then TODO+=("$name"); fi
	done
fi

title "Setup" "everything after the base system"


#    Questions

# Ai - every question is asked here, before anything runs, and only once,
#      an answer is kept for every later run

	# Ai - the optional modules, asked the first time only
for row in "${MODULES[@]}"; do
	IFS='|' read -r name what kind <<< "$row"
	[[ "$kind" == optional && -z "$(choice "module_$name" "")" ]] || continue
	def=y
	if [[ "$name" == hosting ]]; then def=n; fi
	if yesno "Set up ${name}: $what" "$def"; then
		set_choice "module_$name" on
		if (( $# == 0 )); then TODO+=("$name"); fi
	else
		set_choice "module_$name" off
	fi
done

	# Ai - the Mullvad number, kept in memory only and handed to the network
	#      module, never written anywhere
if [[ " ${TODO[*]} " == *" network "* ]] && ! { has mullvad && mullvad account get 2> /dev/null | grep -qi 'mullvad account'; }; then
	printf '\n'
	dim "Your Mullvad account number logs this PC in. It is not saved anywhere."
	dim "Press Enter to skip, you can log in from the Mullvad app later."
	MULLVAD_NUMBER="$(secret "Mullvad account number")"
	export MULLVAD_NUMBER
fi

if (( ${#TODO[@]} == 0 )); then
	ok "everything is done already"
	dim "rebuild status shows the list, rebuild NAME runs one again"
	printf '\n'
	exit 0
fi

	# Ai - in the order of the list, whatever order they were typed in
ORDERED=()
for row in "${MODULES[@]}"; do
	name="${row%%|*}"
	if [[ " ${TODO[*]} " == *" $name "* ]]; then ORDERED+=("$name"); fi
done

printf '\n'
dim "To do: ${ORDERED[*]}"
dim "Your password once, for sudo. Then it runs on its own."
if (( DRY == 0 )); then sudo -v || die "sudo did not accept the password"; fi

	# Ai - sudo stays awake for the whole run, and stops when rebuild does
if (( DRY == 0 )); then
	( while kill -0 $$ 2> /dev/null; do sudo -n -v 2> /dev/null; sleep 50; done ) &
	KEEPALIVE=$!
	trap 'kill $KEEPALIVE 2> /dev/null || true' EXIT
fi


#    Run

NUG_RUN_DIR="$(mktemp -d)"
export NUG_RUN_DIR

i=1
for name in "${ORDERED[@]}"; do
	what="$(printf '%s\n' "${MODULES[@]}" | sed -n "s/^$name|\([^|]*\)|.*/\1/p")"
	printf '\n  %s━━ %s of %s  %s%s  %s%s%s\n' "$C_DIM" "$i" "${#ORDERED[@]}" "$C_0$C_B" "${name^}" "$C_0$C_DIM" "$what" "$C_0"
	rc=0
	bash "$(mod_file "$name")" || rc=$?
	if (( rc == 10 )); then
		# Ai - waiting on something only you can do, it is in Your turn below
		printf '    %s… waiting on you, see Your turn at the end%s\n' "$C_WARN" "$C_0"
	elif (( rc != 0 )); then
		printf '\n  %s✗ %s stopped.%s Fix what it says above, then run rebuild again.\n' "$C_BAD" "${name^}" "$C_0"
		printf '  %sIt continues from %s, nothing done before is repeated.%s\n\n' "$C_DIM" "$name" "$C_0"
		exit 1
	else
		done_mark "$name"
	fi
	i=$(( i + 1 ))
done

done_mark setup


#    End

if [[ -f "$NUG_RUN_DIR/warnings" ]]; then mapfile -d '' WARNINGS < "$NUG_RUN_DIR/warnings"; fi
if [[ -f "$NUG_RUN_DIR/todos" ]]; then mapfile -d '' TODOS < "$NUG_RUN_DIR/todos"; fi
rm -rf "$NUG_RUN_DIR"

printf '\n  %s✓ Setup finished.%s\n' "$C_GOOD" "$C_0"
finish
