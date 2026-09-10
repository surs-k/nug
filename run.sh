#!/usr/bin/env bash

set -Eeuo pipefail

STAGE=run

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Order


section "Order"


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


## Reboots

####### only one reboot in the whole run
####### 40-virt used to force a second one purely for libvirt and kvm group
####### membership, but groups are only needed when you actually use
####### virt-manager, not by any later stage, so it applies at next login
declare -A REBOOT=(
	[20-desktop]="the desktop and the graphics driver only load after a restart"
)



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
		printf '  Fix what you can, then run rebuild once more.\n'
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
