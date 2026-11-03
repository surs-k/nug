#!/usr/bin/env bash

# Ai - lib
#      everything the install scripts share: how they look, how they run a
#      command, how they ask, and how they remember what is done
#      it installs nothing and writes to no disk by itself
#
#      the screens follow four rules, in every script:
#        a question is one screen with what is decided, why, and numbered
#        choices, plus b back, q quit and l the log, and nothing else
#        a step starts on a clean screen, a heading bar tells where you are
#        an error is one screen too: what happened, why, what to do
#        the raw error sits underneath, dimmed

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

# Ai - three facts about the terminal, found once
#      TTY     a keyboard and a screen to ask on, even when the output is piped
#      SCREEN  it can clear and switch screens: not dumb, not a pipe
#      COLOR   it can colour too, and NO_COLOR is not set
#      the colours mean what they do in the Changes app: red wrong, amber worth
#      a look, green fine, cyan is you being asked, and the heading bar is the
#      only thing on screen with a solid background
TTY=0 SCREEN=0 COLOR=0
if (: < /dev/tty) 2> /dev/null; then TTY=1; fi
if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
	SCREEN=1
	if [[ -z "${NO_COLOR:-}" ]]; then COLOR=1; fi
fi

if (( COLOR == 1 )); then
	C_BAD=$'\e[31m'  C_WARN=$'\e[33m'  C_GOOD=$'\e[32m'
	C_ASK=$'\e[36m'  C_DIM=$'\e[2m'    C_B=$'\e[1m'      C_0=$'\e[0m'
	C_BAR=$'\e[1;97;44m'
else
	C_BAD="" C_WARN="" C_GOOD="" C_ASK="" C_DIM="" C_B="" C_0="" C_BAR=""
fi

	# Ai - the alternate screen, the way less uses it: the question is drawn
	#      on a screen of its own, and the one under it comes back untouched
	#      the Linux console has none, there a question clears the screen
SMCUP="" RMCUP=""
if (( SCREEN == 1 )); then
	SMCUP="$(tput smcup 2> /dev/null || true)"
	RMCUP="$(tput rmcup 2> /dev/null || true)"
fi

LOG="${LOG:-/tmp/nug-$(basename "$0" .sh).log}"
: >> "$LOG"
exec 3>> "$LOG"

STEP=0
STEPS="${STEPS:-$(grep -c '^step ' "$0" || true)}"
WARNINGS=()
TODOS=()

	# Ai - a clean screen, earlier output stays in the scrollback with clear -x
	#      a dry run keeps everything on screen, that is what it is for
clear_x() {
	if (( SCREEN == 1 && DRY == 0 )); then clear -x 2> /dev/null || printf '\e[H\e[2J'; fi
	return 0
}

	# Ai - the heading bar, full width, bold on a solid background, with a blank
	#      line above, nothing else on screen looks like it
	#      without colour it is  ==== Encryption (4 of 12) ====
bar() {
	local name=$1 count=${2:-} cols pad
	if (( COLOR == 1 )); then
		cols="$(tput cols 2> /dev/null || printf 80)"
		pad=$(( cols - 5 - ${#name} - ${#count} ))
		if (( pad < 1 )); then pad=1; fi
		printf '\n%s▌ %s   %s%*s%s\n' "$C_BAR" "$name" "$count" "$pad" "" "$C_0"
	elif [[ -n "$count" ]]; then
		printf '\n==== %s (%s) ====\n' "$name" "$count"
	else
		printf '\n==== %s ====\n' "$name"
	fi
}

	# Ai - the top of a script: what it is and how far along you are
	#      under rebuild the module's name is shown by rebuild instead
title() {
	if [[ -n "${NUG_RUN_DIR:-}" ]]; then
		printf '\n==== %s  %s\n' "$(date '+%F %T')" "$1" >&3
		return 0
	fi
	printf '\n  %snug %s%s  ·  %s\n' "$C_B" "$NUG_VERSION" "$C_0" "$1"
	printf '  %s%s%s\n' "$C_DIM" "$2" "$C_0"
	if (( DRY == 1 )); then printf '  %sdry run, nothing will be changed%s\n' "$C_WARN" "$C_0"; fi
	printf '\n'
	printf '\n==== %s  %s  %s\n' "$(date '+%F %T')" "$1" "$NUG_VERSION" >&3
}

	# Ai - one numbered step on a clean screen, the count comes from the script
	#      itself, under rebuild the bar also says which module it is in
step() {
	local where=$1 count
	STEP=$(( STEP + 1 ))
	CURRENT="$1"
	count="$STEP of $STEPS"
	if [[ -n "${NUG_MODULE:-}" ]]; then
		where="$NUG_MODULE · $1"
		count="$count  ·  module $NUG_MODULE_POS"
	fi
	clear_x
	bar "$where" "$count"
	printf '\n---- [%s/%s] %s\n' "$STEP" "$STEPS" "$1" >&3
}

	# Ai - the lines under a bar are indented and dimmed, only the marks keep
	#      their colour: ✓ fine, ! worth a look, ✗ wrong
ok()   { printf '    %s✓%s %s%s%s\n' "$C_GOOD" "$C_0" "$C_DIM" "$*" "$C_0"; printf 'ok   %s\n' "$*" >&3; }
say()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; printf '     %s\n' "$*" >&3; }
dim()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
warn() {
	printf '    %s!%s %s\n' "$C_WARN" "$C_0" "$*"
	printf 'warn %s\n' "$*" >&3
	WARNINGS+=("${CURRENT:-}: $*")
	if [[ -n "${NUG_RUN_DIR:-}" ]]; then printf '%s: %s\0' "${CURRENT:-}" "$*" >> "$NUG_RUN_DIR/warnings"; fi
	return 0
}

	# Ai - something only you can do, collected and shown together at the end
todo() {
	TODOS+=("$*")
	printf 'todo %s\n' "$*" >&3
	if [[ -n "${NUG_RUN_DIR:-}" ]]; then printf '%s\0' "$*" >> "$NUG_RUN_DIR/todos"; fi
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
		printf '    %s·%s %s%s  %s%s\n' "$C_DIM" "$C_0" "$C_DIM" "$label" "$*" "$C_0"
		return 0
	fi
	local start=$SECONDS rc=0
	"$@" >&3 2>&3 < /dev/null &
	_spin $! "$label" || rc=$?
	if (( rc == 0 )); then
		local took=$(( SECONDS - start ))
		if (( took >= 5 )); then
			printf '    %s✓%s %s%s  %ss%s\n' "$C_GOOD" "$C_0" "$C_DIM" "$label" "$took" "$C_0"
		else
			printf '    %s✓%s %s%s%s\n' "$C_GOOD" "$C_0" "$C_DIM" "$label" "$C_0"
		fi
	fi
	return "$rc"
}

	# Ai - a failed command is one screen: what happened, why it matters, what
	#      to do, and Try again or Quit, the raw error is under it, dimmed
	#      with nobody there to ask, it stops, as it always did
run() {
	local label=$1 rc
	while true; do
		rc=0
		_exec "$@" || rc=$?
		if (( rc == 0 )); then return 0; fi
		printf 'FAIL %s\n' "$label" >&3
		if (( TTY == 0 )); then
			printf '    %s✗%s %s\n\n' "$C_BAD" "$C_0" "$label"
			tail -n 15 "$LOG" | sed 's/^/      /'
			die "$label failed, the full log is $LOG"
		fi
		problem "$label did not work." \
			"Everything after this step needs it, so the install is waiting here." \
			"Try again. If it fails the same way, read the full log and send it." retry
	done
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
	for name in $({ grep -o '\${[A-Z_][A-Z0-9_]*}' "$src" || true; } | sort -u | tr -d '${}'); do
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

# Ai - every question is one screen, drawn on its own, the way less is:
#        what is being decided, why it matters, numbered choices, one line each,
#        the suggested one marked and taken by Enter, and nothing else on it
#        no key has to be remembered, Ctrl+C leaves, and says what that leaves
#      a wrong answer keeps the screen and says in one line what was wrong
#      after the answer the screen goes back and one line says what was chosen
#      answers come back in CHOICE or ANSWER, never on stdout, because
#      quitting has to end the script itself, and a subshell cannot do that
#      return 0 means answered, 20 means this question does not apply

QUIT_NOTE="Nothing has been changed yet."
QUIT_CODE=0
CHOICE=0
SUGGESTED=""
ANSWER=""
PICKED=()
SCREEN_OPEN=0

	# Ai - a script can define on_quit to clean up what it opened
ui_open() {
	if (( TTY == 0 )); then die "there is no keyboard to ask on"; fi
	if (( SCREEN == 1 )); then
		printf '%s\e[H\e[2J' "$SMCUP" > /dev/tty
	else
		printf '\n' > /dev/tty
	fi
	SCREEN_OPEN=1
}

ui_close() {
	if (( SCREEN == 1 && SCREEN_OPEN == 1 )); then printf '%s' "${RMCUP:-$'\e[H\e[2J'}" > /dev/tty; fi
	SCREEN_OPEN=0
}
trap 'ui_close' EXIT
trap 'ui_quit 130' INT

ui_log() {
	[[ -r "$LOG" ]] || return 0
	if has less; then less "$LOG" < /dev/tty > /dev/tty || true; else more "$LOG" < /dev/tty > /dev/tty || true; fi
		# Ai - less leaves the alternate screen when it ends, and takes ours with
		#      it, so the question's own screen is opened again
	if (( SCREEN == 1 )); then printf '%s\e[H\e[2J' "$SMCUP" > /dev/tty; fi
}

ui_quit() {
	local code=${1:-$QUIT_CODE}
	ui_close
	printf '\n  %s\n\n' "$(printf '%s' "$QUIT_NOTE" | fold -s -w 70 | sed '2,$s/^/  /')"
	if declare -F on_quit > /dev/null; then on_quit; fi
	exit "$code"
}

	# Ai - the head of a question: what is decided, then why, dimmed
ui_head() {
	printf '\n%s\n' "$(printf '%s' "$1" | fold -s -w 76 | sed "s/^/  ${C_B}/; s/\$/${C_0}/")"
	if [[ -n "${2:-}" ]]; then printf '%s\n' "$(printf '%s' "$2" | fold -s -w 76 | sed "s/^/  ${C_DIM}/; s/\$/${C_0}/")"; fi
	printf '\n'
}

ui_wrong() { printf '    %s✗%s %s\n' "$C_BAD" "$C_0" "$1" > /dev/tty; }

ui_read() {
	local prompt=$1 mode=${2:-plain}
	printf '\n  %s?%s %s ' "$C_ASK" "$C_0" "$prompt" > /dev/tty
	if [[ "$mode" == secret ]]; then
		IFS= read -rs READ < /dev/tty || die "no keyboard input"
		printf '\n' > /dev/tty
	else
		IFS= read -r READ < /dev/tty || die "no keyboard input"
	fi
}

# choose TITLE WHY DEFAULT ITEM...
#   DEFAULT is the number Enter takes, 0 for none, it is marked (suggested)
#   when you come back to a question, DEFAULT is your last answer, then the
#   program's own suggestion is set in SUGGESTED, and each is marked as what it is
choose() {
	local title=$1 why=$2 def=$3 i a n sug=${SUGGESTED:-$3}
	SUGGESTED=""
	shift 3
	local items=("$@")
	n=${#items[@]}
	ui_open
	while true; do
		{
			ui_head "$title" "$why"
			for (( i = 1; i <= n; i++ )); do
				printf '    %s%2d%s  %s' "$C_ASK" "$i" "$C_0" "${items[i-1]}"
				if (( i == sug )); then
					printf '  %s(suggested)%s' "$C_DIM" "$C_0"
				elif (( i == def )); then
					printf '  %s(your last answer)%s' "$C_DIM" "$C_0"
				fi
				printf '\n'
			done
		} > /dev/tty
		while true; do
			ui_read "Your choice" ; a="${READ// /}"
			if [[ -z "$a" && "$def" -gt 0 ]]; then a=$def; fi
			if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
				CHOICE=$a
				ui_close
				return 0
			fi
			ui_wrong "pick a number from 1 to $n"
		done
	done
}

# text TITLE WHY RULES EXAMPLE DEFAULT CHECK [plain|secret|twice]
#   a typed answer, the rules and an example are shown before you type
#   CHECK is a function that gets the answer and, when it is wrong, prints in
#   one line what is wrong and returns 1, secret hides what is typed and
#   twice asks again to be sure, a single b or q is never a valid answer,
#   so it always means back or quit
text() {
	local title=$1 why=$2 rules=$3 example=$4 def=$5 check=${6:-} mode=${7:-plain} a again reason
	ui_open
	while true; do
		{
			ui_head "$title" "$why"
			if [[ -n "$rules" ]]; then printf '    Rules    %s\n' "$rules"; fi
			if [[ -n "$example" ]]; then printf '    Example  %s\n' "$example"; fi
		} > /dev/tty
		while true; do
			if [[ -n "$def" ]]; then ui_read "Type it, Enter takes $def" ; else ui_read "Type it" "$([[ "$mode" == plain ]] || printf secret)"; fi
			a="$READ"
			if [[ -z "$a" && -n "$def" ]]; then a=$def; fi
			if [[ -z "$a" ]]; then ui_wrong "it cannot be empty"; continue; fi
			if [[ -n "$check" ]] && ! reason="$("$check" "$a")"; then ui_wrong "$reason"; continue; fi
			if [[ "$mode" == twice ]]; then
				ui_read "Type it again, to be sure" secret ; again="$READ"
				if [[ "$again" != "$a" ]]; then ui_wrong "those did not match, once more"; continue; fi
			fi
			ANSWER=$a
			ui_close
			return 0
		done
	done
}

# pick TITLE WHY ITEM...
#   for a long list where you may take several: type numbers, 2-5 for a
#   range, all, or just Enter to take none, n and p turn the pages
#   the taken ones come back in PICKED, as item numbers, 1 is the first
pick() {
	local title=$1 why=$2 i a n page=0 rows first last tok x y
	shift 2
	local items=("$@")
	n=${#items[@]}
	PICKED=()
	ui_open
	while true; do
		rows=$(( $(tput lines 2> /dev/null || printf 24) - 17 ))
		if (( rows < 6 )); then rows=6; fi
		first=$(( page * rows + 1 ))
		last=$(( first + rows - 1 ))
		if (( last > n )); then last=$n; fi
		{
			ui_head "$title" "$why"
			for (( i = first; i <= last; i++ )); do printf '    %s%3d%s  %s\n' "$C_ASK" "$i" "$C_0" "${items[i-1]}"; done
			if (( n > rows )); then
				printf '\n    %s%d to %d of %d,%s ' "$C_DIM" "$first" "$last" "$n" "$C_0"
				printf '%sn%s next page, %sp%s page before\n' "$C_ASK" "$C_0" "$C_ASK" "$C_0"
			fi
			printf '\n    %sall%s  take every one, or type numbers like  2 5 7-9,  Enter takes none\n' "$C_ASK" "$C_0"
		} > /dev/tty
		while true; do
			ui_read "Which ones"; a="$READ"
			case "${a// /}" in
				[nN]) if (( last < n )); then page=$(( page + 1 )); break; fi; ui_wrong "this is the last page"; continue ;;
				[pP]) if (( page > 0 )); then page=$(( page - 1 )); break; fi; ui_wrong "this is the first page"; continue ;;
			esac
			PICKED=()
			if [[ "${a,,}" == all ]]; then
				for (( i = 1; i <= n; i++ )); do PICKED+=("$i"); done
				ui_close
				return 0
			fi
			x=0
			for tok in $a; do
				if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
					PICKED+=("$tok")
				elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= BASH_REMATCH[2] && BASH_REMATCH[2] <= n )); then
					y=${BASH_REMATCH[1]}
					while (( y <= BASH_REMATCH[2] )); do PICKED+=("$y"); y=$(( y + 1 )); done
				else
					ui_wrong "\"$tok\" is not a number from 1 to $n, a range like 2-5, or all"
					x=1
					break
				fi
			done
			if (( x == 1 )); then continue; fi
			ui_close
			return 0
		done
	done
}

# typed WORD TITLE WHY BODY
#   the screen before something that cannot be undone: BODY is a function
#   that prints what will happen, the WORD has to be typed, b goes back
typed() {
	local word=$1 title=$2 why=$3 body=$4 a
	ui_open
	while true; do
		{
			ui_head "$title" "$why"
			"$body"
			printf '\n    %s%s%s  type it to go ahead\n' "$C_ASK" "$word" "$C_0"
		} > /dev/tty
		while true; do
			ui_read "Type $word to go ahead" ; a="$READ"
			if [[ "$a" == "$word" ]]; then ui_close; return 0; fi
			ui_wrong "type $word exactly as shown"
		done
	done
}

# problem WHAT WHY TODO [retry] [skip]
#   an error is one screen: what happened, why it matters, what to do, then
#   numbered choices, Try again, Skip when it is safe, Read the full log, Quit,
#   the raw end of the log sits under it, dimmed
#   returns 0 for Try again, 1 for Skip, Quit ends the script with 1
problem() {
	local what=$1 why=$2 act=$3 retry=${4:-} skip=${5:-} a n=0 raw
	local -a keys=() items=()
	trap - ERR
	raw="$(tail -n 8 "$LOG" 2> /dev/null | cut -c1-110 || true)"
	if (( TTY == 0 )); then
		printf '\n  %s✗ %s%s\n' "$C_BAD" "$what" "$C_0" >&2
		printf '  %s%s%s\n\n' "$C_DIM" "$raw" "$C_0" >&2
		exit 1
	fi
	if [[ -n "$retry" ]]; then keys+=(retry); items+=("Try again"); fi
	if [[ -n "$skip" ]]; then keys+=(skip); items+=("Skip this and go on, it is safe to"); fi
	keys+=(log quit)
	items+=("Read the full log, then come back here" "Quit")
	n=${#keys[@]}
	QUIT_CODE=1
	ui_open
	while true; do
		{
			printf '\n  %s✗ %s%s\n' "$C_BAD" "$what" "$C_0"
			printf '  %s\n' "$why"
			printf '  %s%s%s\n\n' "$C_B" "$act" "$C_0"
			for (( a = 1; a <= n; a++ )); do printf '    %s%d%s  %s\n' "$C_ASK" "$a" "$C_0" "${items[a-1]}"; done
			printf '\n%s' "$C_DIM"
			printf 'Quitting: %s\n' "$QUIT_NOTE" | fold -s -w 72 | sed 's/^/  /'
			printf '\n%s\n' "$raw" | sed 's/^/  /'
			printf '%s' "$C_0"
		} > /dev/tty
		while true; do
			ui_read "Your choice"; a="${READ// /}"
			if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )); then
				case "${keys[a-1]}" in
					log)  ui_log; break ;;
					quit) ui_quit 1 ;;
				esac
				ui_close
				trap on_error ERR
				if [[ "${keys[a-1]}" == retry ]]; then return 0; fi
				return 1
			fi
			ui_wrong "pick a number from 1 to $n"
		done
	done
}

	# Ai - sudo asks for the password once and keeps it for the whole run
need_sudo() {
	if (( DRY == 1 || EUID == 0 )); then return 0; fi
	if sudo -n true 2> /dev/null; then return 0; fi
	until ask_program "Your password, once" "The parts that change the system use sudo. It asks once, then keeps it for the whole run." sudo -v; do
		problem "sudo did not accept the password." "Everything that changes the system needs it." "Try again, check Caps Lock first." retry
	done
}

	# Ai - one line on the screen that comes back, saying what was chosen
answered() {
	ok "$1: $2"
}

	# Ai - questions in order, a question that does not apply returns 20
	#      and is skipped
run_questions() {
	local fn rc
	for fn in "$@"; do
		rc=0
		"$fn" || rc=$?
		if (( rc != 0 && rc != 20 )); then return "$rc"; fi
	done
}

	# Ai - for a program that asks by itself, cryptsetup or sudo: the screen
	#      says what it is for first, then the program types its own prompt
	#      returns 1 if the program failed, the caller offers Try again
ask_program() {
	local what=$1 why=$2
	shift 2
	ui_open
	{
		ui_head "$what" "$why"
		printf '    %sThe passphrase is typed into the next line, nothing shows as you type.%s\n\n' "$C_DIM" "$C_0"
	} > /dev/tty
	if "$@" < /dev/tty > /dev/tty 2>&1; then
		ui_close
		return 0
	fi
	ui_close
	return 1
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
	local plan=""
	if (( DRY == 0 )); then plan="$($SUDO pacman -S --needed --print-format '%n' "$@" 2>&1 || true)"; fi
	if [[ "$plan" == *"conflict"* || "$plan" == *"removing"* ]]; then
		printf '%s\n' "$plan" >&3
		die "Installing $* would remove something." "pacman said it conflicts with what is installed, and a silent yes could remove a program you use." \
			"Nothing was changed. Read the full log for the conflict, then remove or keep it by hand and run it again."
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
	if (( DRY == 1 )); then
		_exec "install $label" pacman -S --needed --noconfirm "$1"
		return 0
	fi
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

# Ai - one more screen where only you are needed: what to look at, then what
#      only you can do, numbered, on a clean screen so nothing else is there
finish() {
	local w t i=1
	if (( ${#WARNINGS[@]} + ${#TODOS[@]} > 0 )); then clear_x; fi
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

# Ai - a failed check, a missing disk: one screen, quit is the only way on
#      DIE WHAT [WHY] [TODO]
die() {
	local what=$1 why=${2:-"Nothing after this point ran."} act=${3:-"Fix what it says, then run it again."}
	printf 'FAIL %s\n' "$what" >&3
	problem "$what" "$why" "$act"
	exit 1
}

	# Ai - an error nobody caught still gets its screen, where it happened and the log
on_error() {
	local rc=$?
	trap - ERR
	problem "It stopped in: ${CURRENT:-the start}." \
		"A command failed that nobody planned for. What ran before it is done, nothing after it ran." \
		"Run it again, it goes on from here. If it stops again, read the full log and send it."
	exit "$rc"
}
trap on_error ERR
