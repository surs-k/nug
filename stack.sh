#!/usr/bin/env bash

####### stack
####### starts and stops the self hosted services by name
####### nothing starts by itself any more, see Guides/Selfhost.md
####### installed by 70-docker as /usr/local/bin/stack

set -euo pipefail

STACKS_DIR="${STACKS_DIR:-/srv/rebuild/stacks}"

####### portainer is a single container, not a compose folder
PLAIN="portainer"


#    Usage


usage() {
	cat << 'USAGEEOF'

  stack list             what exists and what is running
  stack up <name>        start it
  stack down <name>      stop it
  stack restart <name>   stop it, start it
  stack logs <name>      follow its output, Ctrl+C to stop watching

  names come from /srv/rebuild/stacks, plus portainer

USAGEEOF
}


#    Helpers


SUDO=""
[[ $EUID -ne 0 ]] && SUDO=sudo

####### every name that has a folder, plus the plain containers
names() {
	local d
	for d in "$STACKS_DIR"/*/; do
		[[ -f "$d/compose.yaml" ]] && basename "$d"
	done
	printf '%s\n' $PLAIN
}

is_plain() {
	local p
	for p in $PLAIN; do
		[[ "$1" == "$p" ]] && return 0
	done
	return 1
}

####### compose needs both files when there is a tailnet one, and the .env
####### in the folder already names them, so the folder is the way in
compose() {
	local name=$1; shift
	( cd "$STACKS_DIR/$name" && $SUDO docker compose "$@" )
}

known() {
	local n
	for n in $(names); do
		[[ "$n" == "$1" ]] && return 0
	done
	printf 'no such service: %s\n\n' "$1" >&2
	printf 'try one of: %s\n\n' "$(names | tr '\n' ' ')" >&2
	return 1
}

running() {
	local out
	out="$($SUDO docker ps --format '{{.Names}}' 2>/dev/null || true)"
	[[ $'\n'"$out"$'\n' == *$'\n'"$1"$'\n'* ]]
}

exists() {
	local out
	out="$($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
	[[ $'\n'"$out"$'\n' == *$'\n'"$1"$'\n'* ]]
}


#    Commands


## Up

####### start is for containers that already exist, up creates them the first
####### time, so both are needed and only one of them is right at any moment
up() {
	local name=$1

	if is_plain "$name"; then
		exists "$name" || { printf '%s does not exist yet, run: rebuild --only 70-docker\n' "$name" >&2; return 1; }
		$SUDO docker start "$name" > /dev/null
	elif [[ -n "$(compose "$name" ps -aq 2>/dev/null)" ]]; then
		compose "$name" start
	else
		compose "$name" up -d
	fi

	printf '%s is up\n' "$name"
}


## Down

down() {
	if is_plain "$1"; then
		$SUDO docker stop "$1" > /dev/null
	else
		compose "$1" stop
	fi

	printf '%s is down\n' "$1"
}


## List

list() {
	local n state

	printf '\n'

	for n in $(names); do
		if running "$n"; then
			state="running"
		elif exists "$n"; then
			state="stopped"
		else
			state="not made yet"
		fi
		printf '  %-12s %s\n' "$n" "$state"
	done

	printf '\n  start one with:  stack up <name>\n\n'
}


#    Main


case "${1:-}" in
	list|ls|"")      list ;;
	up|start)        known "${2:-}" && up "$2" ;;
	down|stop)       known "${2:-}" && down "$2" ;;
	restart)         known "${2:-}" && down "$2" && up "$2" ;;
	logs)
		known "${2:-}" || exit 1
		if is_plain "$2"; then
			$SUDO docker logs -f "$2"
		else
			compose "$2" logs -f
		fi ;;
	-h|--help|help)  usage ;;
	*)
		printf 'unknown command: %s\n' "$1" >&2
		usage >&2
		exit 2 ;;
esac
