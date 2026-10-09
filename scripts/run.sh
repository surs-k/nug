#!/usr/bin/env bash

set -Eeuo pipefail

STAGE=run

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Order


## Mode

	# Ai - how this run is scoped
	#      plain rebuild resumes, the flags are for after you fix something

MODE=resume
TARGET=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--from)  MODE=from;  TARGET="${2:-}"; shift 2 ;;
		--only)  MODE=only;  TARGET="${2:-}"; shift 2 ;;
		--retry) MODE=retry; shift ;;
		--all)   MODE=all;   shift ;;
		--list)  MODE=list;  shift ;;
		-h|--help)
			cat << 'HELPEOF'

  rebuild                    carry on from the first unfinished stage
  rebuild --from 50-snapshots start there and run everything after it
  rebuild --only 30-security  just that one stage
  rebuild --retry            re-run every stage that reported a problem
  rebuild --all              start over from the beginning
  rebuild --list             show what is done and what is not

  Stages are safe to run again. Package installs skip what is already
  there, and every section checks before it acts, so a rerun costs
  time rather than correctness.

HELPEOF
			exit 0 ;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			printf 'Try: rebuild --help\n' >&2
			exit 1 ;;
	esac
done


## Stages

	# Ai - run in this order, the marker name always equals the file name
STAGES=(
	10-base
	20-desktop
	30-security
	35-tailnet
	50-snapshots
	80-remote
	90-health
)


## About

	# Ai - one line each, printed under the stage name in the big banner
declare -A ABOUT=(
	[10-base]="locale, boot menu, swap, power"
	[20-desktop]="graphics, Hyprland, lock screen"
	[30-security]="the firewall"
	[35-tailnet]="Tailscale, the way to your PC"
	[50-snapshots]="snapshots around updates"
	[80-remote]="Moonlight and the pc command"
	[90-health]="health report"
)


## Listing

	# Ai - an early exit, so asking what is done does not print banners at you
if [[ "$MODE" == list ]]; then
	printf '\n'
	for st in "${STAGES[@]}"; do
		if stage_is_done "$st"; then
			printf '  done     %s\n' "$st"
		else
			printf '  pending  %s\n' "$st"
		fi
	done
	printf '\n'
	exit 0
fi


section "Order"


## Depends

	# Ai - what each stage actually needs, rather than just the one before it
	#      a failed 35-tailnet, which needs a login on your phone, stops nothing
	#      else, none of the other stages talk to the tailnet
declare -A DEPENDS=(
	[10-base]=""
	[20-desktop]="10-base"
	[30-security]="10-base"
	[35-tailnet]="30-security"
	[50-snapshots]="10-base"
	[80-remote]="10-base"
	[90-health]="10-base"
)


## Reboots

	# Ai - no reboot in the middle of the run
	#      the desktop is started by the next boot, and every stage after it
	#      works from the console, so there is nothing to wait for
declare -A REBOOT=()



#    Scope


section "Scope"

	# Ai - markers are what make a stage get skipped, so changing scope means
	#      clearing the ones in range, which is the rm -f you were typing by hand

clear_marker() { rm -f "$MARKERS/$1"; }

valid_stage() {
	local st
	for st in "${STAGES[@]}"; do
		[[ "$st" == "$1" ]] && return 0
	done
	return 1
}

case "$MODE" in

	all)
		for st in "${STAGES[@]}"; do clear_marker "$st"; done
		note "starting over, every stage will run" ;;

	from)
		valid_stage "$TARGET" || { printf 'Not a stage: %s\n' "$TARGET" >&2; exit 1; }
		HIT=0
		for st in "${STAGES[@]}"; do
			[[ "$st" == "$TARGET" ]] && HIT=1
			(( HIT )) && clear_marker "$st"
		done
		note "starting at $TARGET and running everything after it" ;;

	only)
		valid_stage "$TARGET" || { printf 'Not a stage: %s\n' "$TARGET" >&2; exit 1; }
		for st in "${STAGES[@]}"; do
			[[ "$st" == "$TARGET" ]] || touch "$MARKERS/$st"
		done
		clear_marker "$TARGET"
		note "running only $TARGET" ;;

	retry)
			# Ai - notes are not problems, so they never make a stage run again
		BAD="$(grep -v '^aside' "$FAILLOG" 2>/dev/null | cut -f2 | awk '{print $1}' | sort -u || true)"
		if [[ -z "${BAD//[[:space:]]/}" ]]; then
			printf '\n  Nothing reported a problem. Nothing to retry.\n\n'
			exit 0
		fi
		for st in $BAD; do
			valid_stage "$st" && { clear_marker "$st"; note "will retry $st"; }
		done
		: > "$FAILLOG" ;;

esac



#    Answers


section "Answers"


## Fresh

	# Ai - only this run's problems, the rest move to the history file
roll_failures

roll_todos


## Network

	# Ai - three stages failing one after another because the network is down
	#      is a bad way to find out the network is down

if ! routed; then
	printf '\n  %sNo route out. Nothing here can download anything.%s\n\n' "$C_FAIL" "$C_OFF" >&2
	printf '  Join Wi-Fi:  nmtui\n' >&2
	printf '  Check:       nmcli device status\n' >&2
	printf '               ip route\n\n' >&2
	exit 1
fi

if ! resolves; then
	printf '\n  %sRouting works but DNS does not.%s\n\n' "$C_FAIL" "$C_OFF" >&2
	printf '  Check:  resolvectl status\n' >&2
	printf '          cat /etc/resolv.conf\n\n' >&2
	exit 1
fi

	# Ai - every question for every remaining stage is asked here, once
	#      after this block the run is hands off until a reboot or the end


## Sudo

action "Type your password. It unlocks sudo for the whole run."

sudo_keepalive


## Ask

	# Ai - the only questions left are about the PC this laptop talks to
	#      asked once here and kept in the config, the installer already asked
	#      the rest
need() { [[ -z "${!1:-}" ]]; }

if need PC_NAME || need PC_USER; then

	action "Two questions about your PC. Press enter to take each default.

Nothing installs until you are through them."

	if need PC_NAME; then
		act_next
		act_line "The name your PC has on the tailnet."
		act_line "It is the PC's hostname, shown by:  tailscale status"
		act_line ""
		save_cfg PC_NAME "$(ask 'PC name' 'hollowtower')"
	fi

	if need PC_USER; then
		act_next
		act_line "Your username on the PC."
		act_line ""
		save_cfg PC_USER "$(ask 'PC username' "$USERNAME")"
	fi

	act_close
	note "Saved. Edit $CONFIG to change either."
	printf '\n'

else
	note "Every question already has an answer in $CONFIG"
fi

source "$CONFIG"



#    Running


section "Running"

DID=0

BROKEN=""

	# Ai - tells a stage it runs under run.sh, which prints the todo list
	#      itself at the end instead of the stage printing it
export REBUILD_RUN=1

	# Ai - position in the run order, for the banner
stage_number() {
	local i
	for i in "${!STAGES[@]}"; do
		[[ "${STAGES[$i]}" == "$1" ]] && { printf '%s' "$(( i + 1 ))"; return 0; }
	done
	printf '?'
}

	# Ai - a stage is blocked when anything it depends on failed, directly or
	#      further back up the chain
blocked_by() {
	local stage=$1 dep
	for dep in ${DEPENDS[$stage]:-}; do
		if contains " $BROKEN " " $dep "; then
			printf '%s' "$dep"
			return 0
		fi
		local up
		up="$(blocked_by "$dep")" && { printf '%s' "$up"; return 0; }
	done
	return 1
}

for s in "${STAGES[@]}"; do

	if stage_is_done "$s"; then
		printf '  %s[ok]%s   %s already done\n' "$C_OK" "$C_OFF" "$s"
		continue
	fi

	BLOCKER="$(blocked_by "$s")" && {
		printf '  %s[skip]%s %s needs %s, which failed\n' \
			"$C_DIM" "$C_OFF" "$s" "$BLOCKER"
		record_fail "$s skipped, $BLOCKER failed first"
		continue
	}

	SH="$SCRIPTS/$s.sh"

	if [[ ! -f "$SH" ]]; then
		flag "$s.sh is missing, skipping"
		continue
	fi

		# Ai - the big banner, so each stage start can be found while scrolling
	stage_banner "$s" "${ABOUT[$s]:-}" "stage $(stage_number "$s") of ${#STAGES[@]}   $(date +%H:%M)"

	if bash "$SH"; then
		DID=$(( DID + 1 ))
	else
			# Ai - carry on with anything that does not depend on this
		BROKEN="$BROKEN $s"

		printf '\n'
		printf '  %s[FAIL]%s %s stopped.\n' "$C_FAIL" "$C_OFF" "$s"
		printf '  log  %s/%s.log\n' "$LOGDIR" "$s"
		printf '  Carrying on with whatever does not depend on it.\n'
		printf '\n'
		continue
	fi

	if [[ -n "${REBOOT[$s]:-}" ]]; then
		show_todos
		action "Reboot now.

Why   ${REBOOT[$s]}

After the restart, run:   rebuild"
		exit 0
	fi
done



#    End


section "End"

if (( DID == 0 )); then
	printf '  Nothing left to do.\n\n'
else
	printf '  Finished %s stage(s).\n\n' "$DID"
fi

if [[ -n "${BROKEN//[[:space:]]/}" ]]; then
	printf '  These did not finish: %s\n\n' "$BROKEN"
	printf '  Everything that could still run, did.\n'
	printf '  Fix what you can, then:   rebuild\n\n'
else
	printf '  Reboot to start the desktop.\n\n'
	printf '  Then, from a terminal:\n'
	printf '    pc view     your PC screen\n'
	printf '    pc          a terminal on your PC\n\n'
fi

	# Ai - the last thing on screen is what still needs attention
show_failures all

RETRY="$(grep -v '^aside' "$FAILLOG" 2>/dev/null | cut -f2 | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"

if [[ -n "${RETRY//[[:space:]]/}" ]]; then
	printf '  To have another go at just those:  rebuild --retry\n\n' >&2
fi

	# Ai - the very last thing, after the problems, so it is what you see
show_todos
