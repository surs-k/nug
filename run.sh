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


## About

####### one line each, printed under the stage name in the big banner
declare -A ABOUT=(
	[10-base]="locale, boot menu, swap, AUR helper"
	[20-desktop]="graphics driver and HyDE"
	[30-security]="Mullvad VPN and the firewall"
	[40-virt]="KVM and the VM network"
	[50-bkp-net]="SSH, snapshots, backups, snapshot boot entries"
	[60-uprefs]="apps, keybinds, monitors"
	[70-docker]="Docker, Ollama, self hosted services"
	[80-remote]="Sunshine, so the laptop can drive this PC"
	[90-health]="health report, alerts, lockdown mode"
	[35-tailnet]="Tailscale remote access, off unless chosen"
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


## Fresh

####### only this run's problems, the rest move to the history file
roll_failures


## Network

####### three stages failing one after another because the network is down
####### is a bad way to find out the network is down

if ! routed; then
	printf '\n  %sNo route out. Nothing here can download anything.%s\n\n' "$C_FAIL" "$C_OFF" >&2
	printf '  Check:  nmcli device status\n' >&2
	printf '          mullvad status\n' >&2
	printf '          ip route\n\n' >&2
	exit 1
fi

if ! resolves; then
	printf '\n  %sRouting works but DNS does not.%s\n\n' "$C_FAIL" "$C_OFF" >&2
	printf '  Check:  resolvectl status\n' >&2
	printf '          mullvad status\n' >&2
	printf '          mullvad dns get\n\n' >&2
	exit 1
fi

####### every question for every remaining stage is asked here, once
####### after this block the run is hands off until a reboot or the end


## Sudo

action "Type your password. It unlocks sudo for the whole run."

sudo_keepalive

printf '\n'


## Ask

STACK_ALL="searxng,portainer,invidious,comfyui"

####### everything this prints goes to the terminal, not to stdout, because
####### the caller captures stdout to get the answer back
pick_stacks() {
	local reply t bad out parts

	while true; do
		act_line "Available services. All of them run on this PC only,"
		act_line "reachable from this machine and nowhere else."
		act_line ""
		act_line "  searxng     private search engine, replaces Google"
		act_line "  portainer   web dashboard for managing Docker"
		act_line "  invidious   private YouTube backend, feeds FreeTube"
		act_line "  comfyui     AI image generation, uses your GPU"
		act_line ""
		act_line "  all         every one of them"
		act_line "  none        skip self hosting"
		act_line ""


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
	|| need WANT_SUNSHINE || need WANT_LIBREWOLF || need WANT_LOCKDOWN; then

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
		act_line "Multihop enters the VPN at one location and leaves at another."
		act_line "Give a country, or a country and a city, or none."
		act_line "us atl   Atlanta        us lax   Los Angeles"
		act_line "se       Sweden         ch       Switzerland"
		act_line "Full list later with: mullvad relay list"


		save_cfg MULLVAD_ENTRY "$(ask 'Multihop entry location' 'us atl')"
	fi


	## Tailnet

	if need WANT_TAILSCALE; then
		rule
		act_line "Tailscale lets the laptop and phone reach this PC from"
		act_line "anywhere, without opening anything to the internet."
		act_line "It is also the most fragile part of this setup, because it"
		act_line "has to be carved out of the Mullvad tunnel by hand."
		act_line "Nothing else needs it. You can turn it on any time with"
		act_line "rebuild --only 35-tailnet"


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


	## Lockdown

	####### asked here now, it used to be asked by 90-health near the very
	####### end, which stopped an unattended run with the summary unprinted
	if need WANT_LOCKDOWN; then
		rule
		act_line "Lockdown mode blocks all traffic whenever the VPN is not"
		act_line "connected, including while it reconnects."
		if yesno "Turn on lockdown mode at the end of the run" y; then
			save_cfg WANT_LOCKDOWN yes
		else
			save_cfg WANT_LOCKDOWN no
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

####### position in the run order, for the banner
stage_number() {
	local i
	for i in "${!STAGES[@]}"; do
		[[ "${STAGES[$i]}" == "$1" ]] && { printf '%s' "$(( i + 1 ))"; return 0; }
	done
	printf '?'
}

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
		record_fail "$s skipped, $BLOCKER failed first"
		continue
	}

	SH="$REPO/$s.sh"

	if [[ ! -f "$SH" ]]; then
		flag "$s.sh is missing, skipping"
		continue
	fi

	####### the big banner, so each stage start can be found while scrolling
	stage_banner "$s" "${ABOUT[$s]:-}" "stage $(stage_number "$s") of ${#STAGES[@]}   $(date +%H:%M)"

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
	printf '    Guides/Bootmenu.md  the boot menu and its escape hatch\n'
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
