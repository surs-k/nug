#!/usr/bin/env bash

	# Ai - installs
	#      every install you can skip, in one list, and no questions
	#      rebuild installs                 the list
	#      rebuild installs off NAME ...    skip them
	#      rebuild installs on NAME ...     take them again
	#      rebuild install NAME             turn it on and install it now
	#      the choices are WANT_ lines in ~/.install-config, and they stay
	#      through a reinstall because the home folder does

	# Ai - not a stage, so a leftover todo list is not printed after the list
REBUILD_RUN=1

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"

	# Ai - this is a settings command, not a stage, so the stage traps are dropped
	#      a typo in a name would otherwise be written down as a failed stage
trap - EXIT ERR


#    Catalog


## Rows

	# Ai - group, name, default, stage, how to tell it is here, what it is
	#      the stage is the script that installs it, and the one rebuild install runs
	#      how to tell: pkg is pacman, flat is flatpak, cmd is a command, file is
	#      a path, none is nothing to look for
	#      the name is the word you type, and in the config a dash becomes an
	#      underscore, mullvad-browser is WANT_MULLVAD_BROWSER
CATALOG=(
	"Apps|signal|yes|60-uprefs|pkg:signal-desktop|Signal messenger"
	"Apps|obsidian|yes|60-uprefs|pkg:obsidian|Obsidian notes"
	"Apps|1password|yes|60-uprefs|cmd:1password|1Password"
	"Apps|codium|yes|60-uprefs|cmd:codium|VSCodium editor"
	"Apps|claude|yes|60-uprefs|cmd:claude-desktop|Claude desktop"
	"Apps|steam|yes|60-uprefs|pkg:steam|Steam and gamescope"
	"Apps|brightness|yes|60-uprefs|cmd:wluma|Auto brightness"
	"Browsers|mullvad-browser|yes|60-uprefs|cmd:mullvad-browser|Mullvad Browser"
	"Browsers|librewolf|yes|60-uprefs|cmd:librewolf|LibreWolf browser"
	"Flatpak|freetube|yes|60-uprefs|flat:io.freetubeapp.FreeTube|FreeTube"
	"Flatpak|vesktop|yes|60-uprefs|flat:dev.vencord.Vesktop|Vesktop, Discord"
	"Flatpak|krita|yes|60-uprefs|flat:org.kde.krita|Krita drawing"
	"Flatpak|flatseal|yes|60-uprefs|flat:com.github.tchx84.Flatseal|Flatseal permissions"
	"System|virt|yes|40-virt|pkg:virt-manager|Virtual machines, KVM"
	"System|sunshine|yes|80-remote|cmd:sunshine|Sunshine remote desktop"
	"System|tailscale|no|35-tailnet|cmd:tailscale|Tailscale remote access"
	"System|chaotic-remove|yes|20-desktop|none:|Remove chaotic-aur repo"
	"Hosting|docker|yes|70-docker|pkg:docker|Docker"
	"Hosting|ollama|yes|70-docker|cmd:ollama|Ollama local AI"
	"Hosting|searxng|yes|70-docker|file:/srv/rebuild/stacks/searxng/compose.yaml|SearXNG private search"
	"Hosting|portainer|yes|70-docker|none:|Portainer dashboard"
	"Hosting|invidious|yes|70-docker|file:/srv/rebuild/stacks/invidious/compose.yaml|Invidious for FreeTube"
	"Hosting|comfyui|no|70-docker|file:/srv/rebuild/stacks/comfyui/compose.yaml|ComfyUI image AI"
	"Hosting|jellyfin|no|70-docker|file:/srv/rebuild/stacks/jellyfin/compose.yaml|Jellyfin media"
)


## Lookup

	# Ai - fills G, N, D, ST, CK and WH for one name, fails for a name that is not here
cat_row() {
	local row
	for row in "${CATALOG[@]}"; do
		if [[ "$(cut -d'|' -f2 <<< "$row")" == "$1" ]]; then
			IFS='|' read -r G N D ST CK WH <<< "$row"
			return 0
		fi
	done
	return 1
}


## Stacks

	# Ai - the services are not WANT_ lines of their own, 70-docker reads one
	#      comma list, so they are switched by editing that list
is_stack() {
	case "$1" in
		searxng|portainer|invidious|comfyui|jellyfin) return 0 ;;
	esac
	return 1
}

STACK_ORDER=(searxng portainer invidious comfyui jellyfin)

stacks_now() {
	local s="${WANT_STACKS:-}"

	if [[ -z "$s" ]]; then
		s="searxng,portainer,invidious"
	fi

	case "$s" in
		all|ALL)   s="searxng,portainer,invidious,comfyui,jellyfin" ;;
		none|NONE) s="" ;;
	esac

	printf '%s' "$s"
}

	# Ai - the config name of one install
var_of() {
	local v="WANT_${1^^}"
	printf '%s' "${v//-/_}"
}


## State

	# Ai - prints on or off
state_of() {
	local v val

	if is_stack "$1"; then
		if contains ",$(stacks_now)," ",$1,"; then
			printf on
		else
			printf off
		fi
		return 0
	fi

	v="$(var_of "$1")"
	val="${!v:-$D}"

	if [[ "$val" == yes ]]; then
		printf on
	else
		printf off
	fi
}

	# Ai - the config is read again after every save, two stacks in one
	#      command would otherwise each start from the old list
set_state() {
	local n=$1 val=$2 list new t

	if is_stack "$n"; then
		list="$(stacks_now)"
		new=""

		for t in "${STACK_ORDER[@]}"; do
			if [[ "$t" == "$n" ]]; then
				if [[ "$val" == yes ]]; then
					new="${new:+$new,}$t"
				fi
			elif contains ",$list," ",$t,"; then
				new="${new:+$new,}$t"
			fi
		done

		save_cfg WANT_STACKS "${new:-none}"
	else
		save_cfg "$(var_of "$n")" "$val"
	fi

	source "$CONFIG"
}


## Here

	# Ai - is it on this PC right now, yes, no, or a dash when there is nothing to look at
here() {
	local kind=${1%%:*} what=${1#*:}

	case "$kind" in
		pkg)  if pacman -Qq "$what" &> /dev/null; then printf yes; else printf no; fi ;;
		flat) if flatpak info "$what" &> /dev/null; then printf yes; else printf no; fi ;;
		cmd)  if command -v "$what" &> /dev/null; then printf yes; else printf no; fi ;;
		file) if [[ -e "$what" ]]; then printf yes; else printf no; fi ;;
		*)    printf -- '-' ;;
	esac
}


## Docker

	# Ai - ollama and the services live in the docker stage, and that stage
	#      stops at the top when docker is off, so they need it on
needs_docker() {
	local n=$1

	if [[ "$n" == ollama ]] || is_stack "$n"; then
		if [[ "$(D=yes; state_of docker)" == off ]]; then
			set_state docker yes
			note "docker was off, $n lives in its stage, so it is on now"
		fi
	fi
}



#    List


## Show

show_list() {
	local row grp="" on_n=0 off_n=0 skipped="" st h col

	printf '\n  %-39s %-7s %s\n' "Installs" "choice" "on PC"

	for row in "${CATALOG[@]}"; do
		IFS='|' read -r G N D ST CK WH <<< "$row"

		if [[ "$G" != "$grp" ]]; then
			printf '\n  %s\n' "$G"
			grp="$G"
		fi

		st="$(state_of "$N")"
		h="$(here "$CK")"

		if [[ "$st" == on ]]; then
			col="$C_OK"
			on_n=$(( on_n + 1 ))
		else
			col="$C_WARN"
			off_n=$(( off_n + 1 ))
			skipped="${skipped:+$skipped }$N"
		fi

		printf '    %-16s %-24s %s%-4s%s    %s\n' "$N" "$WH" "$col" "$st" "$C_OFF" "$h"
	done

	printf '\n  Always installed: base system, desktop, VPN and firewall,\n'
	printf '  snapshots and backups, health checks\n'

	printf '\n  %s on, %s skipped\n' "$on_n" "$off_n"

	if [[ -n "$skipped" ]]; then
		printf '  skipped: %s\n' "$skipped"
	fi

	printf '\n  Skip:      rebuild installs off NAME NAME\n'
	printf '  Take:      rebuild installs on NAME\n'
	printf '  Install:   rebuild install NAME\n\n'
}


## Brief

	# Ai - the one line run.sh prints before it starts, so a skip is seen before it happens
brief() {
	local row on_n=0 off_n=0 skipped=""

	for row in "${CATALOG[@]}"; do
		IFS='|' read -r G N D ST CK WH <<< "$row"

		if [[ "$(state_of "$N")" == on ]]; then
			on_n=$(( on_n + 1 ))
		else
			off_n=$(( off_n + 1 ))
			skipped="${skipped:+$skipped, }$N"
		fi
	done

	if (( off_n == 0 )); then
		note "Installs   $on_n on, none skipped"
	else
		note "Installs   $on_n on, $off_n skipped: $skipped"
	fi

	note "Change     rebuild installs"
}



#    Change


## Seed

	# Ai - every install gets its line in the config, so the choices can be
	#      read there and a new default later never changes an old choice
	#      only a line that is missing is written
seed() {
	local row v

	for row in "${CATALOG[@]}"; do
		IFS='|' read -r G N D ST CK WH <<< "$row"

		is_stack "$N" && continue

		v="$(var_of "$N")"

		if [[ -z "${!v:-}" ]]; then
			save_cfg "$v" "$D"
		fi
	done

	if [[ -z "${WANT_STACKS:-}" ]]; then
		save_cfg WANT_STACKS "searxng,portainer,invidious"
	fi

	source "$CONFIG"
}


## Names

	# Ai - every name is checked before any is changed, so a typo in the last
	#      one does not leave the first ones done
check_names() {
	local n bad=0

	for n in "$@"; do
		if ! cat_row "$n"; then
			printf '  not an install: %s\n' "$n" >&2
			bad=1
		fi
	done

	if (( bad )); then
		printf '  nothing was changed, the names are in:  rebuild installs\n\n' >&2
		exit 1
	fi
}


## Switch

switch() {
	local way=$1; shift
	local val n

	val=yes
	[[ "$way" == off ]] && val=no

	if [[ $# -eq 0 ]]; then
		printf '\n  Name at least one, the names are in:  rebuild installs\n\n' >&2
		exit 1
	fi

	check_names "$@"

	printf '\n'

	for n in "$@"; do
		cat_row "$n"

		set_state "$n" "$val"

		[[ "$val" == yes ]] && needs_docker "$n"

		note "$n   $way"

		if [[ "$val" == no && "$(here "$CK")" == yes ]]; then
			note "         already on this PC, skipping does not remove it"
		fi

		if [[ "$val" == yes && "$(here "$CK")" == no ]] && stage_is_done "$ST"; then
			note "         not on this PC yet:  rebuild install $n"
		fi
	done

	printf '\n'
}


## Now

install_now() {
	local n=${1:-}

	if [[ -z "$n" ]]; then
		printf '\n  Name the install, the names are in:  rebuild installs\n\n' >&2
		exit 1
	fi

	check_names "$n"
	cat_row "$n"

	set_state "$n" yes

	printf '\n'
	needs_docker "$n"
	note "$n   on"

	if ! stage_is_done "$ST"; then
		note "$ST has not run yet, it installs $n when it does"
		note "carry on with:  rebuild"
		printf '\n'
		exit 0
	fi

	note "running $ST"
	printf '\n'

		# Ai - the marker is what makes a stage run again, and no other stage
		#      has lost its marker, so this is the only one that runs
	rm -f "$MARKERS/$ST"

	exec bash "$SCRIPTS/run.sh"
}



#    Usage


usage() {
	cat << 'USAGEEOF'

  rebuild installs                 every install, on or off, and whether it is here
  rebuild installs off NAME ...    skip them
  rebuild installs on NAME ...     take them again
  rebuild install NAME             turn it on and install it now

  Nothing asks a question. A skipped install stays skipped until you
  take it, and the choice stays through a reinstall.

USAGEEOF
}



#    Run


case "${1:-list}" in
	list)            show_list ;;
	off|on)          switch "$@" ;;
	install)         install_now "${2:-}" ;;
	brief)           brief ;;
	seed)            seed ;;
	-h|--help|help)  usage ;;
	*)
		printf '\n  Not a command: %s\n' "$1" >&2
		usage >&2
		exit 1 ;;
esac
