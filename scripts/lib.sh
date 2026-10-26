#!/usr/bin/env bash

# Ai - lib
#      everything the install scripts share: how they look, how they run a
#      command, how they ask, and how they remember what is done
#      it installs nothing and writes to no disk by itself

set -Eeuo pipefail
shopt -s nullglob


#    Paths

NUG_VERSION="v2.0"

SCRIPTS="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(dirname "$SCRIPTS")"
CONF="$REPO/config"

# shellcheck source=../settings.conf
source "$REPO/settings.conf"

SUDO=""
(( EUID == 0 )) || SUDO="sudo"

	# Ai - dry run prints every change instead of making it, reads still happen
DRY="${DRY:-0}"


#    Look

# Ai - the same three colours as the Changes app, each with one meaning:
#      red wrong, amber worth a look, green fine, cyan is you being asked
#      NO_COLOR or a pipe turns them all off
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	C_BAD=$'\e[31m'  C_WARN=$'\e[33m'  C_GOOD=$'\e[32m'
	C_ASK=$'\e[36m'  C_DIM=$'\e[2m'    C_B=$'\e[1m'      C_0=$'\e[0m'
else
	C_BAD="" C_WARN="" C_GOOD="" C_ASK="" C_DIM="" C_B="" C_0=""
fi

LOG="${LOG:-/tmp/nug-$(basename "$0" .sh).log}"
: >> "$LOG"
exec 3>> "$LOG"

STEP=0
STEPS="${STEPS:-$(grep -c '^step ' "$0" || true)}"
WARNINGS=()
TODOS=()

	# Ai - the top of a script: what it is and how far along you are
	#      under rebuild the module's name is shown by rebuild instead
title() {
	if [[ -n "${NUG_RUN_DIR:-}" ]]; then
		printf '\n==== %s  %s\n' "$(date '+%F %T')" "$1" >&3
		return 0
	fi
	printf '\n  %snug %s%s  ·  %s\n' "$C_B" "$NUG_VERSION" "$C_0" "$1"
	printf '  %s%s%s\n' "$C_DIM" "$2" "$C_0"
	(( DRY == 1 )) && printf '  %sdry run, nothing will be changed%s\n' "$C_WARN" "$C_0"
	printf '\n'
	printf '\n==== %s  %s  %s\n' "$(date '+%F %T')" "$1" "$NUG_VERSION" >&3
}

	# Ai - one numbered step, the count comes from the script itself
step() {
	STEP=$(( STEP + 1 ))
	CURRENT="$1"
	printf '\n  %s[%s/%s]%s %s%s%s\n' "$C_DIM" "$STEP" "$STEPS" "$C_0" "$C_B" "$1" "$C_0"
	printf '\n---- [%s/%s] %s\n' "$STEP" "$STEPS" "$1" >&3
}

ok()   { printf '    %s✓%s %s\n' "$C_GOOD" "$C_0" "$*"; printf 'ok   %s\n' "$*" >&3; }
say()  { printf '    %s\n' "$*"; printf '     %s\n' "$*" >&3; }
dim()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
warn() {
	printf '    %s!%s %s\n' "$C_WARN" "$C_0" "$*"
	printf 'warn %s\n' "$*" >&3
	WARNINGS+=("${CURRENT:-}: $*")
	[[ -n "${NUG_RUN_DIR:-}" ]] && printf '%s: %s\0' "${CURRENT:-}" "$*" >> "$NUG_RUN_DIR/warnings"
	return 0
}
die() {
	printf '\n  %s✗ %s%s\n' "$C_BAD" "$*" "$C_0" >&2
	printf 'FAIL %s\n' "$*" >&3
	exit 1
}

	# Ai - something only you can do, collected and shown together at the end
todo() {
	TODOS+=("$*")
	printf 'todo %s\n' "$*" >&3
	[[ -n "${NUG_RUN_DIR:-}" ]] && printf '%s\0' "$*" >> "$NUG_RUN_DIR/todos"
	return 0
}


#    Run

# Ai - run shows one line per command: a spinner while it works, then a tick
#      and the time it took, the output goes to the log, not the screen
#      on failure the last lines of the log are shown and the script stops
#      soft is the same, but a failure is a warning and the script goes on
#      quiet runs without the line, for small steps that need no tick

_spin() {
	local pid=$1 label=$2 i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	if [[ ! -t 1 ]]; then
		wait "$pid"
		return
	fi
	while kill -0 "$pid" 2> /dev/null; do
		printf '\r    %s%s%s %s' "$C_DIM" "${frames:i++%10:1}" "$C_0" "$label"
		sleep 0.1
	done
	printf '\r\e[K'
	wait "$pid"
}

_exec() {
	local label=$1
	shift
	printf '\n$ %s\n' "$*" >&3
	if (( DRY == 1 )); then
		printf '    %s·%s %s  %s%s%s\n' "$C_DIM" "$C_0" "$label" "$C_DIM" "$*" "$C_0"
		return 0
	fi
	local start=$SECONDS rc=0
	"$@" >&3 2>&3 < /dev/null &
	_spin $! "$label" || rc=$?
	if (( rc == 0 )); then
		local took=$(( SECONDS - start ))
		if (( took >= 5 )); then
			printf '    %s✓%s %s  %s%ss%s\n' "$C_GOOD" "$C_0" "$label" "$C_DIM" "$took" "$C_0"
		else
			printf '    %s✓%s %s\n' "$C_GOOD" "$C_0" "$label"
		fi
	fi
	return "$rc"
}

run() {
	local label=$1 rc=0
	_exec "$@" || rc=$?
	(( rc == 0 )) && return 0
	printf '    %s✗%s %s\n\n' "$C_BAD" "$C_0" "$label"
	tail -n 15 "$LOG" | sed 's/^/      /'
	printf '\n'
	die "$label failed, the full log is $LOG"
}

soft() {
	local label=$1 rc=0
	_exec "$@" || rc=$?
	(( rc == 0 )) && return 0
	warn "$label did not work, see $LOG"
	return 0
}

quiet() {
	printf '\n$ %s\n' "$*" >&3
	(( DRY == 1 )) && return 0
	"$@" >&3 2>&3
}

	# Ai - is it true, for checks that read and never change anything
has() { command -v "$1" > /dev/null 2>&1; }


#    Files

# Ai - every file the install writes goes through put or block, so a dry run
#      can show it, and nothing is ever half written
#      put FILE [MODE] < content         replaces the whole file
#      block FILE NAME < content         replaces only our marked part of it,
#                                        so a rerun never writes it twice
#      the comment marker follows the file: # for most, -- for lua, // for jsonc

put() {
	local file=$1 mode=${2:-644} tmp
	tmp="$(mktemp)"
	cat > "$tmp"
	printf '\n> %s\n' "$file" >&3
	if (( DRY == 1 )); then
		printf '    %s·%s write %s\n' "$C_DIM" "$C_0" "$file"
		cat "$tmp" >&3
		rm -f "$tmp"
		return 0
	fi
	$SUDO mkdir -p "$(dirname "$file")"
	$SUDO install -m "$mode" "$tmp" "$file"
	rm -f "$tmp"
}

	# Ai - put for files in your home, owned by you rather than root
put_mine() {
	local file=$1 mode=${2:-644} tmp
	tmp="$(mktemp)"
	cat > "$tmp"
	printf '\n> %s\n' "$file" >&3
	if (( DRY == 1 )); then
		printf '    %s·%s write %s\n' "$C_DIM" "$C_0" "$file"
		rm -f "$tmp"
		return 0
	fi
	mkdir -p "$(dirname "$file")"
	install -m "$mode" "$tmp" "$file"
	rm -f "$tmp"
}

block() {
	local file=$1 name=$2 c='#' tmp body owner
	case "$file" in
		*.lua) c='--' ;;
		*.jsonc|*.css) c='//' ;;
	esac
	body="$(cat)"
	tmp="$(mktemp)"
	if [[ -f "$file" ]]; then
		sed "\|^$c nug $name start\$|,\|^$c nug $name end\$|d" "$file" > "$tmp"
	fi
	[[ -s "$tmp" && -n "$(tail -c 1 "$tmp")" ]] && printf '\n' >> "$tmp"
	printf '%s nug %s start\n%s\n%s nug %s end\n' "$c" "$name" "$body" "$c" "$name" >> "$tmp"
	owner=root
	[[ "$file" == "$HOME"/* && "$HOME" != /root ]] && owner=me
	if [[ "$owner" == me ]]; then
		put_mine "$file" < "$tmp"
	else
		put "$file" < "$tmp"
	fi
	rm -f "$tmp"
}

	# Ai - fill a template from config/: ${NAME} becomes that variable's value
fill() {
	local src=$1 text name
	text="$(cat "$src")"
	for name in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "$src" | sort -u | tr -d '${}'); do
		text="${text//\$\{$name\}/${!name:-}}"
	done
	printf '%s\n' "$text"
}


#    Theme

# Ai - the design tokens from config/theme.env, plus the forms some programs
#      need: colours without their #, and two sizes worked out from the rest
load_theme() {
	local t
	# shellcheck source=../config/theme.env
	source "$CONF/theme.env"
	for t in BG SURFACE OVERLAY TEXT MUTED ACCENT BAD WARN GOOD; do
		declare -g "${t}_RAW=${!t#\#}"
	done
	GAP_OUT=$(( GAP * 2 ))
	FONT_SIZE_TERM=$(( FONT_SIZE + 1 ))
}


#    Ask

# Ai - every question reads from the keyboard, never from a pipe, and shows
#      its default in brackets, Enter takes it

ask() {
	local q=$1 def=${2:-} a
	if [[ -n "$def" ]]; then
		printf '    %s?%s %s %s[%s]%s ' "$C_ASK" "$C_0" "$q" "$C_DIM" "$def" "$C_0" > /dev/tty
	else
		printf '    %s?%s %s ' "$C_ASK" "$C_0" "$q" > /dev/tty
	fi
	IFS= read -r a < /dev/tty || die "no keyboard input"
	printf '%s' "${a:-$def}"
}

yesno() {
	local q=$1 def=${2:-y} a hint="Y/n"
	[[ "$def" == n ]] && hint="y/N"
	while true; do
		printf '    %s?%s %s %s[%s]%s ' "$C_ASK" "$C_0" "$q" "$C_DIM" "$hint" "$C_0" > /dev/tty
		IFS= read -r a < /dev/tty || die "no keyboard input"
		a="${a:-$def}"
		case "${a,,}" in
			y|yes) return 0 ;;
			n|no)  return 1 ;;
		esac
		printf '      answer y or n\n' > /dev/tty
	done
}

secret() {
	local q=$1 a
	printf '    %s?%s %s ' "$C_ASK" "$C_0" "$q" > /dev/tty
	IFS= read -rs a < /dev/tty || die "no keyboard input"
	printf '\n' > /dev/tty
	printf '%s' "$a"
}

	# Ai - typed twice, a typo in a password nobody can see means a reinstall
secret_twice() {
	local q=$1 a b
	while true; do
		a="$(secret "$q")"
		b="$(secret "$q again")"
		if [[ -z "$a" ]]; then
			printf '      it cannot be empty\n' > /dev/tty
		elif [[ "$a" != "$b" ]]; then
			printf '      those did not match, once more\n' > /dev/tty
		else
			printf '%s' "$a"
			return 0
		fi
	done
}

	# Ai - for anything that erases, the word has to be typed, not just Enter
confirm_word() {
	local word=$1 a
	printf '    %s?%s Type %s%s%s to go ahead, anything else stops: ' "$C_ASK" "$C_0" "$C_B" "$word" "$C_0" > /dev/tty
	IFS= read -r a < /dev/tty || die "no keyboard input"
	[[ "$a" == "$word" ]]
}


#    Network

# Ai - routing and names are tested apart, they break for different reasons
online() {
	local h
	for h in 1.1.1.1 9.9.9.9; do
		ping -4 -c 1 -W 3 "$h" > /dev/null 2>&1 && getent ahostsv4 archlinux.org > /dev/null 2>&1 && return 0
	done
	return 1
}

wait_for() {
	local secs=$1 i
	shift
	for (( i = 0; i < secs; i++ )); do
		"$@" > /dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}


#    Disks

partname() {
	if [[ "$1" =~ [0-9]$ ]]; then
		printf '%sp%s' "$1" "$2"
	else
		printf '%s%s' "$1" "$2"
	fi
}


#    Packages

# Ai - pac installs from the Arch repos, any tries names in order, repo first,
#      then the AUR with yay, for packages that move between the two
#      each skips what is already there, so a rerun costs nothing
#      pac checks first what it would remove, and stops rather than let
#      --noconfirm say yes to a removal nobody saw

pac() {
	local plan
	plan="$($SUDO pacman -S --needed --print-format '%n' "$@" 2>&1 || true)"
	if [[ "$plan" == *"conflict"* || "$plan" == *"removing"* ]]; then
		printf '%s\n' "$plan" >&3
		die "installing $* would remove something, nothing was changed"
	fi
	run "install $*" $SUDO pacman -S --needed --noconfirm "$@"
}

installed() { pacman -Qq "$1" > /dev/null 2>&1; }

any() {
	local label=$1 name
	shift
	for name in "$@"; do
		installed "$name" && { ok "$label already installed"; return 0; }
	done
	for name in "$@"; do
		if pacman -Si "$name" > /dev/null 2>&1; then
			soft "install $label" $SUDO pacman -S --needed --noconfirm "$name"
			installed "$name" && return 0
		fi
	done
	for name in "$@"; do
		if has yay; then
			_exec "build $label ($name)" yay -S --needed --noconfirm --answerdiff=None \
				--answerclean=None --answeredit=None --removemake --sudoloop "$name" && return 0
		fi
	done
	warn "$label did not install under any name: $*"
	return 1
}


#    State

# Ai - a module is done when its marker exists, and only then
STATE="$HOME/.local/state/nug"
done_mark()  { (( DRY == 1 )) || { mkdir -p "$STATE/done"; date '+%F %T' > "$STATE/done/$1"; }; }
is_done()    { [[ -f "$STATE/done/$1" ]]; }

	# Ai - the choices, kept in your home so they survive a reinstall
CHOICES="$HOME/.config/nug/choices"
choice()     { local v; v="$(sed -n "s/^$1=//p" "$CHOICES" 2> /dev/null | tail -n 1)"; printf '%s' "${v:-$2}"; }
set_choice() {
	(( DRY == 1 )) && return 0
	mkdir -p "$(dirname "$CHOICES")"
	touch "$CHOICES"
	sed -i "/^$1=/d" "$CHOICES"
	printf '%s=%s\n' "$1" "$2" >> "$CHOICES"
}


#    End

# Ai - the last screen: what to look at, then what only you can do, numbered
finish() {
	local w t i=1
	printf '\n'
	if (( ${#WARNINGS[@]} > 0 )); then
		printf '  %sWorth a look%s\n' "$C_WARN" "$C_0"
		for w in "${WARNINGS[@]}"; do printf '    %s!%s %s\n' "$C_WARN" "$C_0" "$w"; done
		printf '\n'
	fi
	if (( ${#TODOS[@]} > 0 )); then
		printf '  %sYour turn%s\n' "$C_ASK" "$C_0"
		for t in "${TODOS[@]}"; do
			printf '    %s%s.%s %s\n' "$C_ASK" "$i" "$C_0" "${t//$'\n'/$'\n'       }"
			i=$(( i + 1 ))
		done
		printf '\n'
	fi
	printf '  %sLog: %s%s\n\n' "$C_DIM" "$LOG" "$C_0"
}

	# Ai - an error nobody caught still ends with where it happened and the log
on_error() {
	local rc=$?
	printf '\n  %s✗ stopped in: %s%s\n' "$C_BAD" "${CURRENT:-start}" "$C_0" >&2
	printf '  %sthe log has the details: %s%s\n\n' "$C_DIM" "$LOG" "$C_0" >&2
	exit "$rc"
}
trap on_error ERR
