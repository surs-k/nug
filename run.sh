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
	35-tailnet
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


## Depends

####### what each stage actually needs, rather than just the one before it
####### the old chain was a straight line, so a failed 40-virt blocked your
####### apps and your self hosting for no real reason
####### 60-uprefs only needs a desktop, it has nothing to do with VMs
declare -A DEPENDS=(
	[10-base]=""
	[20-desktop]="10-base"
	[30-security]="10-base"
	[40-virt]="30-security"
	[50-bkp-net]="30-security"
	[60-uprefs]="20-desktop"
	[70-docker]="20-desktop 30-security"
	[80-remote]="20-desktop 30-security"
	[90-health]="10-base"
	[35-tailnet]="30-security"
)


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


####### each answer is checked on its own rather than behind one flag
####### a single ANSWERED gate meant any question added later was skipped
####### forever on a machine that had already answered the earlier ones,
####### which is why the multihop location was never asked for
need() { [[ -z "${!1:-}" ]]; }

if need WANT_CHAOTIC_REMOVE || need WANT_DOCKER || need WANT_STACKS \
	|| need MULLVAD_ENTRY || need WANT_TAILSCALE || need WANT_OLLAMA \
	|| need WANT_SUNSHINE || need WANT_LIBREWOLF; then

	action "Answer a few questions. Press enter to take each default.

Nothing installs until you are through them."


	## Chaotic

	if need WANT_CHAOTIC_REMOVE; then
		rule
		if yesno "Remove the chaotic-aur repo after HyDE installs" y; then
			save_cfg WANT_CHAOTIC_REMOVE yes
		else
			save_cfg WANT_CHAOTIC_REMOVE no
		fi
	fi


	## Hosting

	if need WANT_DOCKER; then
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
	fi


	## Multihop

	if need MULLVAD_ENTRY; then
		rule
		{
			printf '\n  Multihop enters the VPN at one location and leaves at another.\n'
			printf '  Give a country, or a country and a city, or none.\n\n'
			printf '    us atl   Atlanta        us lax   Los Angeles\n'
			printf '    se       Sweden         ch       Switzerland\n\n'
			printf '  Full list later with: mullvad relay list\n\n'
		} > /dev/tty

		save_cfg MULLVAD_ENTRY "$(ask 'Multihop entry location' 'us atl')"
	fi


	## Tailnet

	if need WANT_TAILSCALE; then
		rule
		{
			printf '\n  Tailscale lets the laptop and phone reach this PC from\n'
			printf '  anywhere, without opening anything to the internet.\n\n'
			printf '  It is also the most fragile part of this setup, because it\n'
			printf '  has to be carved out of the Mullvad tunnel by hand.\n'
			printf '  Nothing else needs it. You can turn it on any time with\n'
			printf '  rebuild --only 35-tailnet\n\n'
		} > /dev/tty

		if yesno "Set up Tailscale remote access now" n; then
			save_cfg WANT_TAILSCALE yes
		else
			save_cfg WANT_TAILSCALE no
		fi
	fi


	## Ollama

	if need WANT_OLLAMA; then
		rule
		if yesno "Install Ollama for local AI models" y; then
			save_cfg WANT_OLLAMA yes
		else
			save_cfg WANT_OLLAMA no
		fi
	fi


	## Sunshine

	if need WANT_SUNSHINE; then
		rule
		if yesno "Set up Sunshine so the laptop can drive this PC" y; then
			save_cfg WANT_SUNSHINE yes
		else
			save_cfg WANT_SUNSHINE no
		fi
	fi


	## Librewolf

	if need WANT_LIBREWOLF; then
		rule
		if yesno "Install LibreWolf as a second browser for local services" y; then
			save_cfg WANT_LIBREWOLF yes
		else
			save_cfg WANT_LIBREWOLF no
		fi
	fi


	printf '\n'
	note "Saved. Only questions without an answer are asked."
	note "Edit $CONFIG to change any answer."
	printf '\n'

else
	note "Every question already has an answer in $CONFIG"
fi




#    Running


section "Running"

DID=0

BROKEN=""

####### a stage is blocked when anything it depends on failed, directly or
####### further back up the chain
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
		record_fail "skipped, $BLOCKER failed first"
		continue
	}

	SH="$REPO/$s.sh"

	if [[ ! -f "$SH" ]]; then
		flag "$s.sh is missing, skipping"
		continue
	fi

	printf '\n'
	printf '%s########################################%s\n' "$C_HEAD" "$C_OFF"
	printf '%s  starting %s%s\n' "$C_HEAD" "$s" "$C_OFF"
	printf '%s########################################%s\n' "$C_HEAD" "$C_OFF"
	printf '\n'

	if bash "$SH"; then
		DID=$(( DID + 1 ))
	else
		####### carry on with anything that does not depend on this
		BROKEN="$BROKEN $s"

		printf '\n'
		printf '  %s[FAIL]%s %s stopped.\n' "$C_FAIL" "$C_OFF" "$s"
		printf '  log  %s/%s.log\n' "$LOGDIR" "$s"
		printf '  Carrying on with whatever does not depend on it.\n'
		printf '\n'
		continue
	fi

	if [[ -n "${REBOOT[$s]:-}" ]]; then
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
	printf '  Read next:\n'
	printf '    Guides/Backups.md   snapshots and rollback\n'
	printf '    Guides/Network.md   when the internet breaks\n'
	printf '    Guides/Selfhost.md  your services\n\n'
	printf '  Reboot once more to land on a settled system.\n\n'
fi

####### the last thing on screen is what still needs attention
show_failures all

RETRY="$(cut -f2 "$FAILLOG" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"

if [[ -n "${RETRY//[[:space:]]/}" ]]; then
	printf '  To have another go at just those:  rebuild --retry\n\n' >&2
fi
