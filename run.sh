#!/usr/bin/env bash

set -Eeuo pipefail

STAGE=run

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Order


## Mode

####### how this run is scoped
####### plain rebuild resumes, the flags are for after you fix something

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
  rebuild --from 50-bkp-net  start there and run everything after it
  rebuild --only 30-security just that one stage
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

## Stages

####### run in this order, the marker name always equals the file name
STAGES=(
	10-base
	20-desktop
	30-security
	40-virt
	50-bkp-net
	60-uprefs
	70-docker
	80-remote
	90-health
)


## Listing

####### an early exit, so asking what is done does not print banners at you
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


## Reboots

####### only one reboot in the whole run
####### 40-virt used to force a second one purely for libvirt and kvm group
####### membership, but groups are only needed when you actually use
####### virt-manager, not by any later stage, so it applies at next login
declare -A REBOOT=(
	[20-desktop]="the desktop and the graphics driver only load after a restart"
)



#    Scope


section "Scope"

####### markers are what make a stage get skipped, so changing scope means
####### clearing the ones in range, which is the rm -f you were typing by hand

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
		BAD="$(cut -f2 "$FAILLOG" 2>/dev/null | awk '{print $1}' | sort -u || true)"
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

####### every question for every remaining stage is asked here, once
####### after this block the run is hands off until a reboot or the end


## Sudo

note "Your password unlocks sudo for the whole run."
printf '\n'

sudo_keepalive

printf '\n'


## Ask

STACK_ALL="searxng,portainer,invidious,comfyui"

####### everything this prints goes to the terminal, not to stdout, because
####### the caller captures stdout to get the answer back
pick_stacks() {
	local reply t bad out parts

	while true; do
		{
			printf '\n  Available services. All of them run on this PC only,\n'
			printf '  reachable from this machine and nowhere else.\n\n'
			printf '    searxng     private search engine, replaces Google\n'
			printf '    portainer   web dashboard for managing Docker\n'
			printf '    invidious   private YouTube backend, feeds FreeTube\n'
			printf '    comfyui     AI image generation, uses your GPU\n\n'
			printf '    all         every one of them\n'
			printf '    none        skip self hosting\n\n'
		} > /dev/tty

		reply="$(ask 'Which ones, comma separated' 'searxng,portainer,invidious')"
		reply="${reply// /}"

		case "$reply" in
			all|ALL)   printf '%s' "$STACK_ALL"; return 0 ;;
			none|NONE) printf 'none';            return 0 ;;
		esac

		bad=0
		out=""
		IFS=',' read -ra parts <<< "$reply"

		for t in "${parts[@]}"; do
			case "$t" in
				searxng|portainer|invidious|comfyui)
					out="${out:+$out,}$t" ;;
				"") ;;
				*)
					printf '  not a service: %s\n' "$t" > /dev/tty
					bad=1 ;;
			esac
		done

		if (( bad == 0 )) && [[ -n "$out" ]]; then
			printf '%s' "$out"
			return 0
		fi

		printf '  try again\n' > /dev/tty
	done
}


if [[ -z "${ANSWERED:-}" ]]; then

	note "A few choices. Press enter to take the default."


	## Chaotic

	rule

	if yesno "Remove the chaotic-aur repo after HyDE installs" y; then
		save_cfg WANT_CHAOTIC_REMOVE yes
	else
		save_cfg WANT_CHAOTIC_REMOVE no
	fi
	printf '\n' > /dev/tty


	## Hosting

	rule

	if yesno "Set up Docker and self hosted services" y; then
		save_cfg WANT_DOCKER yes
		STACKS="$(pick_stacks)"
		save_cfg WANT_STACKS "$STACKS"
		printf '  chosen: %s\n' "$STACKS" > /dev/tty
	else
		save_cfg WANT_DOCKER no
		save_cfg WANT_STACKS none
	fi


	rule

	## Multihop

	{
		printf '\n  Multihop enters the VPN in one country and leaves in another.\n'
		printf '  It needs an entry country. A two letter code, or none.\n'
		printf '  se Sweden, ch Switzerland, de Germany, nl Netherlands\n\n'
	} > /dev/tty

	save_cfg MULLVAD_ENTRY "$(ask 'Multihop entry country' 'se')"


	## Ollama

	rule

	if yesno "Install Ollama for local AI models" y; then
		save_cfg WANT_OLLAMA yes
	else
		save_cfg WANT_OLLAMA no
	fi


	## Sunshine

	rule

	if yesno "Set up Sunshine so the laptop can drive this PC" y; then
		save_cfg WANT_SUNSHINE yes
	else
		save_cfg WANT_SUNSHINE no
	fi


	## Librewolf

	rule

	if yesno "Install LibreWolf as a second browser for local services" y; then
		save_cfg WANT_LIBREWOLF yes
	else
		save_cfg WANT_LIBREWOLF no
	fi


	save_cfg ANSWERED yes

	printf '\n'
	note "Saved. Later runs will not ask again."
	note "Edit $CONFIG to change any answer."
	printf '\n'

else
	note "Answers already saved in $CONFIG"
fi




#    Running


section "Running"

DID=0

for s in "${STAGES[@]}"; do

	if stage_is_done "$s"; then
		printf '  done   %s\n' "$s"
		continue
	fi

	SH="$REPO/$s.sh"

	if [[ ! -f "$SH" ]]; then
		flag "$s.sh is missing, skipping"
		continue
	fi

	printf '\n'
	printf '########################################\n'
	printf '  starting %s\n' "$s"
	printf '########################################\n'
	printf '\n'

	if ! bash "$SH"; then
		printf '\n'
		printf '  %s stopped.\n' "$s"
		printf '  log  %s/%s.log\n' "$LOGDIR" "$s"
		printf '\n'

		####### everything that went wrong across the whole run, not just the
		####### stage that stopped, so one pass of fixing covers all of it
		show_failures all

		printf '  Every stage is safe to run again.\n'
		printf '  rebuild carries on from here, it does not start over.\n'
		printf '\n'

		printf '  To pick up from here:       rebuild\n'
		printf '  To redo this whole stage:   rebuild --only %s\n' "$s"
		printf '  To redo everything skipped: rebuild --retry\n'
		printf '\n'

		exit 1
	fi

	DID=$((DID + 1))

	if [[ -n "${REBOOT[$s]:-}" ]]; then
		printf '\n'
		printf '========================================\n'
		printf '  REBOOT NOW\n'
		printf '========================================\n'
		printf '\n'
		printf '  Why   %s\n' "${REBOOT[$s]}"
		printf '\n'
		printf '  After the restart, run this again:\n'
		printf '\n'
		printf '    rebuild\n'
		printf '\n'
		printf '  It picks up exactly where it stopped.\n'
		printf '\n'
		exit 0
	fi
done



#    End


section "End"

if (( DID == 0 )); then
	printf '  Nothing left to do. Every stage is complete.\n\n'
else
	printf '  Finished %s stage(s). Every stage is complete.\n\n' "$DID"
fi

printf '  Read next:\n'
printf '    Guides/Backups.md   snapshots and rollback\n'
printf '    Guides/Network.md   what to do when the internet breaks\n'
printf '    Guides/Selfhost.md  starting and stopping your services\n'
printf '\n'
printf '  Reboot once more to land on a fully settled system.\n'
printf '\n'

####### the last thing on screen is what still needs attention
show_failures all

BAD="$(cut -f2 "$FAILLOG" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"

if [[ -n "${BAD//[[:space:]]/}" ]]; then
	printf '  Those were skipped, not fatal.\n' >&2
	printf '  To have another go at just those:  rebuild --retry\n\n' >&2
fi
