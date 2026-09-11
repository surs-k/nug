#!/usr/bin/env bash

####### Rebuild v6.0 shared library
####### every stage sources this as its first action
####### nothing here installs a package or writes to a disk


set -Eeuo pipefail


#    Guard


## Punct

for _f in "$0" "${BASH_SOURCE[0]}"; do
	if LC_ALL=C.UTF-8 grep -nP '[\x{201C}\x{201D}\x{2018}\x{2019}\x{2014}\x{2013}]' "$_f"; then
		printf 'Smart punctuation in %s\n' "$_f" >&2
		exit 1
	fi
done
unset _f


## Shell

[[ -n "${BASH_VERSINFO:-}" ]] || { printf 'Run with bash\n' >&2; exit 1; }



#    Paths


## Repo

####### everything lives in one directory now, so the repo is simply the
####### directory this script sits in, and the stage is the file name
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

ROOT="$REPO"

STAGE="${STAGE:-$(basename "$0" .sh)}"


## Root

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"



#    Logging


## File

LOGDIR="${LOGDIR:-$HOME/.rebuild/logs}"
mkdir -p "$LOGDIR"

LOG="$LOGDIR/$STAGE.log"

####### fd 3 is the log
####### stdout stays a real terminal so prompts and progress bars survive
exec 3>>"$LOG"

printf '\n===== %s  %s =====\n' "$STAGE" "$(date -Is)" >&3


## Failures

####### every failure lands here, from any path, and stays there
####### this file is what gets printed at the end of a stage and at the end of
####### the whole run, including when a stage dies part way through
FAILLOG="$LOGDIR/failures.txt"

touch "$FAILLOG"

####### the tag is what separates "skipped this, carried on" from
####### "this is where the script stopped"
record_fail() {
	printf '%s\t%-12s %s\n' "${2:-soft}" "$STAGE" "$1" >> "$FAILLOG"
}


## Colour

####### colour never carries meaning on its own, it is always paired with a
####### word in brackets
####### roughly one in twelve men has red green colour blindness, and red
####### green is exactly the fail/ok pairing a terminal reaches for first
####### NO_COLOR, a dumb terminal, or piping to a file all turn it off

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
	C_OK=$'\033[32m'
	C_WARN=$'\033[33m'
	C_FAIL=$'\033[31m'
	C_HEAD=$'\033[1;36m'
	C_DIM=$'\033[2m'
	C_OFF=$'\033[0m'
else
	C_OK=''; C_WARN=''; C_FAIL=''; C_HEAD=''; C_DIM=''; C_OFF=''
fi


## Say

say()  { printf '%s\n'   "$*"; printf '%s\n'   "$*" >&3; }

note() { printf '  %s\n' "$*"; printf '  %s\n' "$*" >&3; }

info() {
	printf '  %s[info]%s %s\n' "$C_DIM" "$C_OFF" "$*"
	printf 'INFO %s\n' "$*" >&3
}

flag() {
	printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2
	printf 'WARN %s\n' "$*" >&3
	record_fail "$*"
}

blank() { printf '                                                            \r'; }



#    Progress


## Count

STEPS="$(grep -c '^#    ' "$0" 2>/dev/null || true)"
STEPS="${STEPS:-0}"
STEP=0


## Banner

section() {
	STEP=$((STEP + 1))
	printf '\n'
	printf '%s========================================%s\n' "$C_HEAD" "$C_OFF"
	printf '%s %-28s %2s / %-2s%s\n' "$C_HEAD" "$1" "$STEP" "$STEPS" "$C_OFF"
	printf '%s========================================%s\n' "$C_HEAD" "$C_OFF"
	printf '\n'
	printf '\n--- %s ---\n' "$1" >&3
}



#    Running


## Verbose

VERBOSE="${REBUILD_VERBOSE:-0}"


## Quiet

####### run hides output and shows one spinner line
####### never give run an interactive command, it has no terminal
run() {
	local label=$1; shift
	local rc=0 ELAPSED=0

	printf 'RUN %s\n' "$*" >&3

	if [[ "$VERBOSE" == 1 ]]; then
		printf '  ..     %s\n' "$label"
		"$@" || rc=$?
	else
		local frames='|/-\' i=0 pid start=$SECONDS
		"$@" >&3 2>&1 &
		pid=$!
		while kill -0 "$pid" 2>/dev/null; do
			####### a spinner alone cannot tell you whether this is a minute
			####### or ten, the count can
			printf '\r  [%s]    %s   %ss' \
				"${frames:i++%4:1}" "$label" "$(( SECONDS - start ))"
			sleep 0.2
		done
		wait "$pid" || rc=$?
		ELAPSED=$(( SECONDS - start ))
		printf '\r'
		blank
	fi

	if (( rc == 0 )); then
		if (( ELAPSED > 10 )); then
			printf '  %s[ok]%s   %s   %s%ss%s\n' \
				"$C_OK" "$C_OFF" "$label" "$C_DIM" "$ELAPSED" "$C_OFF"
		else
			printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
		fi
	else
		printf '  %s[FAIL]%s %s   exit %s\n' "$C_FAIL" "$C_OFF" "$label" "$rc" >&2
		printf 'FAILED %s exit %s\n' "$*" "$rc" >&3

		####### put the error on screen
		####### a path to a log file is not a message, it is homework
		printf '\n  what it actually said:\n\n' >&2
		tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
		printf '\n  full log  %s\n\n' "$LOG" >&2
	fi

	return "$rc"
}


## Soft

####### same as run but a failure is advisory
soft() {
	local label=$1; shift
	run "$label" "$@" || flag "$label did not succeed, continuing"
}


## Report

####### printed at the end of every stage and again at the end of the run
####### duplicates are collapsed, because re-running a stage appends again
show_failures() {
	local scope=${1:-all}
	local raw softs stops title

	[[ -s "$FAILLOG" ]] || return 0

	if [[ "$scope" == stage ]]; then
		raw="$(grep -P "\t$STAGE " "$FAILLOG" 2>/dev/null | awk '!seen[$0]++' || true)"
		title="PROBLEMS IN $STAGE"
	else
		raw="$(awk '!seen[$0]++' "$FAILLOG" 2>/dev/null || true)"
		title="EVERYTHING THAT HAD A PROBLEM"
	fi

	[[ -n "${raw//[[:space:]]/}" ]] || return 0

	softs="$(printf '%s\n' "$raw" | sed -n 's/^soft\t//p' || true)"
	stops="$(printf '%s\n' "$raw" | sed -n 's/^stop\t//p' || true)"

	printf '\n' >&2
	printf '========================================\n' >&2
	printf ' %s\n' "$title" >&2
	printf '========================================\n' >&2

	if [[ -n "${softs//[[:space:]]/}" ]]; then
		printf '\n  SKIPPED, the run carried on\n\n' >&2
		printf '%s\n' "$softs" | sed 's/^/    /' >&2
	fi

	if [[ -n "${stops//[[:space:]]/}" ]]; then
		printf '\n  STOPPED THE SCRIPT\n\n' >&2
		printf '%s\n' "$stops" | sed 's/^/    /' >&2
	fi

	printf '\n  full list  %s\n\n' "$FAILLOG" >&2
}


## Refresh

####### never called on a schedule, only when an install has already failed
####### -Sy on its own is the thing that causes partial upgrades, so the
####### refresh has to be a full -Syu or it makes the system worse
####### a kernel upgrade mid run removes the running kernel's modules, which
####### breaks anything that loads one until a reboot, so that gets flagged

refresh_db() {
	local before after

	before="$(pacman -Q linux 2>/dev/null || true)"

	$SUDO pacman -Syu --noconfirm 2> >(tee -a "$LOG" >&2) \
		|| flag "database refresh did not finish cleanly"

	after="$(pacman -Q linux 2>/dev/null || true)"

	if [[ -n "$before" && "$before" != "$after" ]]; then
		flag "the kernel was upgraded during this run"
		flag "reboot before continuing, module loading will fail until you do"
	fi
}


## Pacman

####### stderr is copied into the log while stdout stays a terminal
####### the progress bar needs a real terminal, the error needs to be findable
pac() {
	local start=$SECONDS plan

	printf '\n  packages   %s\n\n' "$*"
	printf 'pacman -S %s\n' "$*" >&3

	####### --noconfirm answers every prompt with the default, which includes
	####### "yes, remove that" on a conflict
	####### a dry run first means an unexpected removal stops the stage
	####### instead of quietly happening while nobody is watching
	plan="$(capture $SUDO pacman -S --needed --print-format '%n' "$@")"

	if contains "$plan" "removing" || contains "$plan" "conflicts"; then
		flag "this install wants to remove or replace something, stopping"
		printf '%s\n' "$plan" | sed 's/^/    /' >&2
		return 1
	fi

	if $SUDO pacman -S --needed --noconfirm "$@" 2> >(tee -a "$LOG" >&2); then
		printf '\n  done in %ss\n' "$(( SECONDS - start ))"
		return 0
	fi

	####### every mirror answering 404 for one filename means the local
	####### database is older than the mirrors, not that the network is down
	####### retrying the same request cannot fix that, only a refresh can
	flag "install failed, refreshing the database once and trying again"

	refresh_db

	$SUDO pacman -S --needed --noconfirm "$@" 2> >(tee -a "$LOG" >&2)
}


## Aur

aur() {
	printf '\n  aur build  %s\n\n' "$*"
	printf 'yay -S %s\n' "$*" >&3
	yay -S --needed --noconfirm "$@" 2> >(tee -a "$LOG" >&2)
}


## Flatpak

flat() {
	printf '\n  flatpak    %s\n\n' "$*"
	printf 'flatpak install %s\n' "$*" >&3
	$SUDO flatpak install -y --noninteractive flathub "$@" 2> >(tee -a "$LOG" >&2)
}


## Present

installed() { pacman -Qq "$1" &>/dev/null; }



#    State


## Markers

MARKERS="$HOME/.install-state"
mkdir -p "$MARKERS"

####### marker name always equals the file name, no hand typed strings
stage_done()    { touch "$MARKERS/${1:-$STAGE}"; }

stage_is_done() { [[ -f "$MARKERS/${1:-$STAGE}" ]]; }

require_stage() {
	[[ -f "$MARKERS/$1" ]] || { printf 'Run %s first\n' "$1" >&2; exit 1; }
}


#    Config


## Defaults

####### HOSTNAME is also a bash variable, so it is set here and only
####### overwritten by the config file, never by the environment
HOSTNAME="CHANGEME"
USERNAME="CHANGEME"
KEYMAP="colemak"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
RETRY_LIMIT=10
TUNNEL_MTU=1420
LIMINE_TIMEOUT=1


## Load

CONFIG="$HOME/.install-config"

[[ -f "$CONFIG" ]] && source "$CONFIG"

export USERNAME


## Save

####### never save a password, a passphrase or an account number here
save_cfg() {
	local k=$1 v=$2
	touch "$CONFIG"
	chmod 600 "$CONFIG"
	sed -i "/^$k=/d" "$CONFIG"
	printf '%s=%q\n' "$k" "$v" >> "$CONFIG"
}



#    Text


## Match

####### capture then match
####### a pipeline into grep -q can take SIGPIPE and return 141 under pipefail
contains() { [[ "$1" == *"$2"* ]]; }


## Capture

capture() { "$@" 2>&1 || true; }



#    Asking


## Line

ask() {
	local prompt=$1 default=${2:-} reply
	if [[ -n "$default" ]]; then
		read -rp "  $prompt [$default]: " reply < /dev/tty
		printf '%s' "${reply:-$default}"
	else
		read -rp "  $prompt: " reply < /dev/tty
		printf '%s' "$reply"
	fi
}


## Divider

####### a question needs room around it or it reads as part of the last answer
rule() {
	printf '\n' > /dev/tty
	printf '  ----------------------------------------\n' > /dev/tty
	printf '\n' > /dev/tty
}


## Yes

####### the capital letter is the default, that is the whole convention
yesno() {
	local prompt=$1 default=${2:-n} hint reply

	if [[ "$default" == [yY]* ]]; then
		hint="(Y/n)"
	else
		hint="(y/N)"
	fi

	read -rp "  $prompt $hint: " reply < /dev/tty

	reply="${reply:-$default}"

	[[ "$reply" == [yY]* ]]
}


## Confirm

confirm() {
	local reply
	read -rp "  Type YES to continue: " reply < /dev/tty
	[[ "$reply" == YES ]] || exit 1
}


## Secret

secret() {
	local prompt=$1 reply
	read -rsp "  $prompt: " reply < /dev/tty
	printf '\n' > /dev/tty
	printf '%s' "$reply"
}


## Twice

####### every password is typed twice, a typo you cannot see is a reinstall
secret_twice() {
	local label=$1 a b
	while true; do
		a="$(secret "$label")"
		b="$(secret "$label again")"

		if [[ -z "$a" ]]; then
			printf '  empty, try again\n' >&2
			continue
		fi

		if [[ "$a" == "$b" ]]; then
			printf '%s' "$a"
			return 0
		fi

		printf '  those did not match, try again\n' >&2
	done
}



#    Helpers


## Online

####### a slow ping in a VM is almost never the internet
####### ping resolves AAAA first and then sits waiting on an ipv6 route that
####### does not exist, so ipv4 is forced and every probe gets a deadline
####### routing and name resolution are tested separately, because they break
####### for different reasons and need different fixes

PING_HOSTS=(1.1.1.1 9.9.9.9 8.8.8.8)

DNS_HOST="${DNS_HOST:-archlinux.org}"

routed() {
	local h
	for h in "${PING_HOSTS[@]}"; do
		ping -4 -c1 -W2 "$h" &> /dev/null && return 0
	done
	return 1
}

resolves() { getent ahostsv4 "$DNS_HOST" &> /dev/null; }

online() {
	if ! routed; then
		printf '  no route out, check the network adapter\n' >&2
		return 1
	fi

	if ! resolves; then
		printf '  routing works but DNS does not, check /etc/resolv.conf\n' >&2
		return 1
	fi

	return 0
}


## Retry

retry() {
	local attempt=1 reply
	until "$@"; do
		if (( attempt >= RETRY_LIMIT )); then
			printf '\n  failed %s times:\n    %s\n' "$RETRY_LIMIT" "$*" >&2
			read -rp "  Continue anyway? YES or NO: " reply < /dev/tty
			[[ "$reply" == YES ]] && return 0
			exit 1
		fi
		printf '  attempt %s failed, retrying\n' "$attempt" >&2
		attempt=$(( attempt + 1 ))
		sleep 2
	done
}


## Wait

wait_for() {
	local tries=$1; shift
	local n=0
	until "$@"; do
		n=$((n + 1))
		if (( n >= tries )); then
			printf '  timeout after %ss: %s\n' "$tries" "$*" >&2
			printf 'TIMEOUT after %ss waiting for: %s\n' "$tries" "$*" >&3
			return 1
		fi
		sleep 1
	done
}


## Sudo

KEEPALIVE_PID=""

sudo_keepalive() {
	[[ -n "$SUDO" ]] || return 0
	sudo -v
	(
		while true; do
			sudo -n true 2>/dev/null || true
			sleep 50
			kill -0 "$$" 2>/dev/null || exit 0
		done
	) &
	KEEPALIVE_PID=$!
}



#    Disks


## Suffix

partsuffix() { [[ "$1" =~ [0-9]$ ]] && printf p || printf ''; }


## Name

partname() { printf '%s%s%s' "$1" "$(partsuffix "$1")" "$2"; }


## Pick

pick_disk() {
	local prompt=$1 dev
	while true; do
		read -rp "  $prompt" dev < /dev/tty || { printf 'No input\n' >&2; exit 1; }
		[[ "$dev" == /dev/* ]] || dev="/dev/$dev"
		if [[ ! -b "$dev" ]]; then
			printf '  not a block device: %s\n' "$dev" >&2
		elif [[ "$(lsblk -dno TYPE "$dev")" != disk ]]; then
			printf '  not a whole disk: %s\n' "$dev" >&2
		else
			printf '%s' "$dev"
			return 0
		fi
	done
}


## Require

require_disk() {
	[[ -b "$1" ]] || { printf 'Not a block device: %s\n' "$1" >&2; exit 1; }
}



#    Verify


## State

FAILED=0


## Check

check() {
	local label=$1; shift
	if "$@" >&3 2>&1; then
		printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
	else
		printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$label" >&2
		record_fail "check failed: $label"
		FAILED=1
	fi
}


## Warn

warn() {
	local label=$1; shift
	if "$@" >&3 2>&1; then
		printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
	else
		printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$label" >&2
		record_fail "$label"
	fi
}


## Done

verify_done() {
	if (( FAILED == 0 )); then
		printf '\n  all checks passed\n\n'
	else
		printf '\n  verification failed\n  log %s\n\n' "$LOG" >&2
		exit 1
	fi
}



#    Traps


## Exit

cleanup() {
	####### captured first, before anything below can clobber it
	local rc=$?

	if [[ -n "$KEEPALIVE_PID" ]]; then
		kill "$KEEPALIVE_PID" 2>/dev/null || true
	fi

	####### this runs whether the stage finished or died, which is the whole
	####### point, a stage that stops half way still has to tell you what
	####### went wrong before it stopped
	show_failures stage

	return "$rc"
}

trap cleanup EXIT


## Error

####### every failure path shows the error, not only the ones inside run()
####### wait_for and plain commands were reaching this trap and printing a
####### path to a log file instead of the reason
on_err() {
	local rc=$?

	printf '\n  FAIL %s line %s\n' "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" >&2
	printf '  cmd  %s\n' "$BASH_COMMAND" >&2

	printf '\n  what it actually said:\n\n' >&2
	tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
	printf '\n  full log  %s\n\n' "$LOG" >&2

	record_fail "$BASH_COMMAND" stop

	return "$rc"
}

trap on_err ERR
