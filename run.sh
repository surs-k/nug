#!/usr/bin/env bash

set -Eeuo pipefail

STAGE=run

source "$(dirname "$(readlink -f "$0")")/lib/common.sh"


#    Order


section "Order"


## Stages

####### run in this order, marker name always equals the directory name
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


## Scripts

declare -A SCRIPT=(
	[10-base]=bs.sh
	[20-desktop]=de.sh
	[30-security]=sec.sh
	[40-virt]=virt.sh
	[50-bkp-net]=bkp.sh
	[60-uprefs]=prefs.sh
	[70-docker]=dk.sh
	[80-remote]=rem.sh
	[90-health]=hl.sh
)


## Reboots

####### a reboot is required after these, everything else chains straight on
declare -A REBOOT=(
	[20-desktop]="the desktop and the graphics driver only load after a restart"
	[40-virt]="your user was added to the libvirt and kvm groups"
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

	{
		printf '\n  HyDE adds chaotic-aur, a large third party package repo.\n'
		printf '  Removing it means packages come only from official Arch\n'
		printf '  repos and the AUR you build yourself.\n\n'
	} > /dev/tty

	if yesno "Remove the chaotic-aur repo after HyDE installs" y; then
		save_cfg WANT_CHAOTIC_REMOVE yes
	else
		save_cfg WANT_CHAOTIC_REMOVE no
	fi


	## Hosting

	{
		printf '\n  Self hosting runs services on this PC instead of using\n'
		printf '  someone elses servers.\n\n'
	} > /dev/tty

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

	{
		printf '\n  Ollama runs AI language models on your own GPU, offline.\n'
		printf '  Models are large, they go on the data disk.\n\n'
	} > /dev/tty

	if yesno "Install Ollama for local AI models" y; then
		save_cfg WANT_OLLAMA yes
	else
		save_cfg WANT_OLLAMA no
	fi


	## Sunshine

	{
		printf '\n  Sunshine streams this PC to your laptop over Tailscale,\n'
		printf '  so the laptop acts as a screen for this machine.\n\n'
	} > /dev/tty

	if yesno "Set up Sunshine so the laptop can drive this PC" y; then
		save_cfg WANT_SUNSHINE yes
	else
		save_cfg WANT_SUNSHINE no
	fi


	## Librewolf

	{
		printf '\n  Mullvad Browser stays your default. LibreWolf is a second\n'
		printf '  browser for your own services, which Mullvad Browser\n'
		printf '  deliberately refuses to stay logged into.\n\n'
	} > /dev/tty

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


## Secrets

####### account numbers and passwords are never written to the config file
####### the stages that need them prompt at the moment they are used
printf '\n'
note "Two logins happen later and cannot be pre-answered:"
note "  Mullvad wants an account number"
note "  Tailscale opens a browser link"
printf '\n'

confirm



#    Running


section "Running"

DID=0

for s in "${STAGES[@]}"; do

	if stage_is_done "$s"; then
		printf '  done   %s\n' "$s"
		continue
	fi

	SH="$REPO/$s/${SCRIPT[$s]}"

	if [[ ! -f "$SH" ]]; then
		flag "$s missing ${SCRIPT[$s]}, skipping"
		continue
	fi

	printf '\n'
	printf '########################################\n'
	printf '  starting %s\n' "$s"
	printf '########################################\n'
	printf '\n'

	chmod +x "$SH"

	if ! "$SH"; then
		printf '\n'
		printf '  %s failed.\n' "$s"
		printf '  log  %s/%s.log\n' "$LOGDIR" "$s"
		printf '\n'
		printf '  Every stage is safe to run again.\n'
		printf '  Fix the cause, then run ./run.sh once more.\n'
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
		printf '    cd ~/Rebuild && ./run.sh\n'
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
