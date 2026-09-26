#!/usr/bin/env bash

	# Ai - Rebuild v7.4 shared library
	#      every stage sources this as its first action
	#      nothing here installs a package or writes to a disk


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

	# Ai - every script sits in scripts, one level below the repo
	#      SCRIPTS is that folder, REPO is the repo itself, where configs,
	#      stacks and guides live, and the stage is the file name
SCRIPTS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

REPO="$(dirname "$SCRIPTS")"

STAGE="${STAGE:-$(basename "$0" .sh)}"


## Root

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"



#    Logging


## File

LOGDIR="${LOGDIR:-$HOME/.rebuild/logs}"
mkdir -p "$LOGDIR"

LOG="$LOGDIR/$STAGE.log"

	# Ai - fd 3 is the log
	#      stdout stays a real terminal so prompts and progress bars survive
exec 3>>"$LOG"

printf '\n===== %s  %s =====\n' "$STAGE" "$(date -Is)" >&3


## Failures

	# Ai - every failure lands here, from any path, and stays there
	#      this file is what gets printed at the end of a stage and at the end of
	#      the whole run, including when a stage dies part way through
FAILLOG="$LOGDIR/failures.txt"
FAILHIST="$LOGDIR/failures-history.txt"

	# Ai - run.sh rolls this over before the stages start
	#      it used to accumulate forever, so problems fixed weeks ago kept
	#      reappearing in the summary with nothing to say they were old
roll_failures() {
	if [[ -s "$FAILLOG" ]]; then
		{
			printf '\n===== %s =====\n' "$(date -Is)"
			cat "$FAILLOG"
		} >> "$FAILHIST"
	fi
	: > "$FAILLOG"
}

touch "$FAILLOG"


## Later

	# Ai - anything you have to do by hand that did not hold the run up
	#      a YOUR TURN block printed mid stage scrolled past before it was
	#      read, so these are kept and printed as the very last thing
TODOLOG="$LOGDIR/todo.txt"

touch "$TODOLOG"

roll_todos() { : > "$TODOLOG"; }

todo() {
	{
		printf '=== %s\n' "$STAGE"
		printf '%s\n' "$*"
	} >> "$TODOLOG"
	printf 'LATER: %s\n' "$*" >&3
}

	# Ai - the tag is what separates "skipped this, carried on" from
	#      "this is where the script stopped"
record_fail() {
	printf '%s\t%-12s %s\n' "${2:-soft}" "$STAGE" "$1" >> "$FAILLOG"
}


## Colour

	# Ai - colour never carries meaning on its own, it is always paired with a
	#      word in brackets
	#      roughly one in twelve men has red green colour blindness, and red
	#      green is exactly the fail/ok pairing a terminal reaches for first
	#      NO_COLOR, a dumb terminal, or piping to a file all turn it off
	#      orange is a problem the run carried on past, red is one that stopped it

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
	C_OK=$'\033[32m'
	C_WARN=$'\033[38;5;208m'
	C_FAIL=$'\033[31m'
	C_HEAD=$'\033[1;36m'
	C_ACT=$'\033[1;35m'
	C_DIM=$'\033[2m'
	C_BIG=$'\033[1;96m'
	C_OFF=$'\033[0m'
else
	C_OK=''; C_WARN=''; C_FAIL=''; C_HEAD=''; C_ACT=''; C_DIM=''; C_BIG=''; C_OFF=''
fi


## Action

	# Ai - anything that needs you to do something by hand
	#      deliberately a different shape and colour from every other block, so
	#      it registers from the corner of your eye without being read
ACT_IS_OPEN=0
ACT_LINES=0

act_open() {
	(( ACT_IS_OPEN )) && return 0
	ACT_IS_OPEN=1
	ACT_LINES=0

	printf '\n' > /dev/tty
	printf '%s>>>>>>>>>>>>>>>>>  YOUR TURN  >>>>>>>>>>>>>>>>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
	printf '%s>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
}

act_rule() {
	printf '%s>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
}

	# Ai - one blank marker line, room inside a single subject
act_gap() {
	printf '%s>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
}

	# Ai - between two short subjects: blank, arrow line, blank
	#      nothing when no block is open, a fresh block header is gap enough
act_split() {
	(( ACT_IS_OPEN )) || return 0
	act_gap
	act_rule
	act_gap
}

	# Ai - after a long subject, the same with one more blank for extra room
act_break() {
	(( ACT_IS_OPEN )) || return 0
	act_gap
	act_rule
	act_gap
	act_gap
}

	# Ai - the start of the next subject: a gap inside an open block, or a new
	#      block when none is open, pass big after a long subject
act_next() {
	if (( ! ACT_IS_OPEN )); then
		act_open
	elif [[ "${1:-small}" == big ]]; then
		act_break
	else
		act_split
	fi
}

	# Ai - no automatic rules, spacing is placed deliberately or not at all
act_line() {
	printf '%s>>%s  %s\n' "$C_ACT" "$C_OFF" "$*" > /dev/tty
}

	# Ai - anything piped in gets wrapped, so a disk listing stays inside the
	#      block instead of sitting outside it as loose text
act_feed() {
	local line
	while IFS= read -r line; do
		printf '%s>>%s  %s\n' "$C_ACT" "$C_OFF" "$line" > /dev/tty
	done
}

act_close() {
	(( ACT_IS_OPEN )) || return 0
	ACT_IS_OPEN=0

	printf '%s>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
	printf '%s>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>%s\n' "$C_ACT" "$C_OFF" > /dev/tty
	printf '\n' > /dev/tty
}

	# Ai - the first line should always be an instruction, not context
	#      act_text only prints, every gap around it is placed by the caller
act_text() {
	local line

	act_open

	while IFS= read -r line; do
		act_line "$line"
		ACT_LINES=$(( ACT_LINES + 1 ))
	done <<< "$*"

	printf 'ACTION NEEDED: %s\n' "$*" >&3
}

	# Ai - the same, with a small gap before it when it follows another one
action() {
	if (( ACT_IS_OPEN && ACT_LINES > 0 )); then
		act_split
	fi

	act_text "$@"
}

## Todos

	# Ai - one block, one gap per item, the file path last so it can be
	#      found again after the screen has moved on
show_todos() {
	local line

	[[ -s "$TODOLOG" ]] || return 0

	act_open
	act_line "Finish these by hand. None of them held the run up."

	while IFS= read -r line; do
		if [[ "$line" == "=== "* ]]; then
			act_break
		else
			act_line "$line"
		fi
	done < "$TODOLOG"

	act_gap
	act_line "kept at  $TODOLOG"
	act_close
}


## Say

say()  { act_close; printf '%s\n'   "$*"; printf '%s\n'   "$*" >&3; }

note() { act_close; printf '  %s\n' "$*"; printf '  %s\n' "$*" >&3; }

pass() {
	act_close
	printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$*"
	printf 'OK %s\n' "$*" >&3
}

info() {
	act_close
	printf '  %s[info]%s %s\n' "$C_DIM" "$C_OFF" "$*"
	printf 'INFO %s\n' "$*" >&3
}

flag() {
	act_close
	printf '  %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2
	printf 'WARN %s\n' "$*" >&3
	record_fail "$*"
}

	# Ai - worth knowing, but nothing on this PC is broken: an outside service
	#      refusing this VPN address, or a choice you made showing its effect
	#      listed apart from the problems, and never a reason to retry
aside() {
	act_close
	printf '  %s[note]%s %s\n' "$C_DIM" "$C_OFF" "$*" >&2
	printf 'NOTE %s\n' "$*" >&3
	record_fail "$*" aside
}

blank() { printf '                                                            \r'; }



#    Progress


## Count

STEPS="$(grep -c '^#    ' "$0" 2>/dev/null || true)"
STEPS="${STEPS:-0}"
STEP=0


## Banner

	# Ai - the section name is kept, so a failure can say where it happened
SECTION=""

section() {
	act_close
	STEP=$((STEP + 1))
	SECTION="$1"
	printf '\n'
	printf '%s========================================%s\n' "$C_HEAD" "$C_OFF"
	printf '%s %-28s %2s / %-2s%s\n' "$C_HEAD" "$1" "$STEP" "$STEPS" "$C_OFF"
	printf '%s========================================%s\n' "$C_HEAD" "$C_OFF"
	printf '\n'
	printf '\n--- %s ---\n' "$1" >&3
}


## Stage

	# Ai - the start of every stage, letters five rows tall across a full width
	#      band, so a stage can be found by eye while scrolling back
	#      X is a filled cell and a dot an empty one, the solid block is put in
	#      at print time so this file stays plain ASCII
	#      the block characters exist in the console font too, so this also
	#      shows on the text console before the desktop is installed

BIG_FULL=$'\xe2\x96\x88'
BIG_LOW=$'\xe2\x96\x84'
BIG_HIGH=$'\xe2\x96\x80'

declare -A BIG=(
	[A]='.XXX.|X...X|XXXXX|X...X|X...X'
	[B]='XXXX.|X...X|XXXX.|X...X|XXXX.'
	[C]='.XXXX|X....|X....|X....|.XXXX'
	[D]='XXXX.|X...X|X...X|X...X|XXXX.'
	[E]='XXXXX|X....|XXXX.|X....|XXXXX'
	[F]='XXXXX|X....|XXXX.|X....|X....'
	[G]='.XXXX|X....|X..XX|X...X|.XXXX'
	[H]='X...X|X...X|XXXXX|X...X|X...X'
	[I]='XXX|.X.|.X.|.X.|XXX'
	[J]='..XXX|....X|....X|X...X|.XXX.'
	[K]='X...X|X..X.|XXX..|X..X.|X...X'
	[L]='X....|X....|X....|X....|XXXXX'
	[M]='X...X|XX.XX|X.X.X|X...X|X...X'
	[N]='X...X|XX..X|X.X.X|X..XX|X...X'
	[O]='.XXX.|X...X|X...X|X...X|.XXX.'
	[P]='XXXX.|X...X|XXXX.|X....|X....'
	[Q]='.XXX.|X...X|X.X.X|X..X.|.XX.X'
	[R]='XXXX.|X...X|XXXX.|X..X.|X...X'
	[S]='.XXXX|X....|.XXX.|....X|XXXX.'
	[T]='XXXXX|..X..|..X..|..X..|..X..'
	[U]='X...X|X...X|X...X|X...X|.XXX.'
	[V]='X...X|X...X|X...X|.X.X.|..X..'
	[W]='X...X|X...X|X.X.X|XX.XX|X...X'
	[X]='X...X|.X.X.|..X..|.X.X.|X...X'
	[Y]='X...X|.X.X.|..X..|..X..|..X..'
	[Z]='XXXXX|...X.|..X..|.X...|XXXXX'
	[0]='.XXX.|X..XX|X.X.X|XX..X|.XXX.'
	[1]='.X.|XX.|.X.|.X.|XXX'
	[2]='XXXX.|....X|.XXX.|X....|XXXXX'
	[3]='XXXX.|....X|.XXX.|....X|XXXX.'
	[4]='X...X|X...X|XXXXX|....X|....X'
	[5]='XXXXX|X....|XXXX.|....X|XXXX.'
	[6]='.XXX.|X....|XXXX.|X...X|.XXX.'
	[7]='XXXXX|....X|...X.|..X..|..X..'
	[8]='.XXX.|X...X|.XXX.|X...X|.XXX.'
	[9]='.XXX.|X...X|.XXXX|....X|.XXX.'
	[dash]='....|....|XXXX|....|....'
	[sp]='...|...|...|...|...'
)

BIG_ROWS=()
BIG_WIDTH=0

big_render() {
	local text=${1^^} ch i n
	local -a rows=('' '' '' '' '') cells

	for (( i = 0; i < ${#text}; i++ )); do
		ch=${text:i:1}
		case "$ch" in
			[A-Z0-9]) ;;
			-) ch=dash ;;
			*) ch=sp ;;
		esac
		IFS='|' read -r -a cells <<< "${BIG[$ch]:-${BIG[sp]}}"
		for n in 0 1 2 3 4; do
			rows[n]+="${cells[n]}."
		done
	done

	BIG_ROWS=()
	BIG_WIDTH=$(( ${#rows[0]} - 1 ))
	for n in 0 1 2 3 4; do
		ch=${rows[n]%.}
		ch=${ch//X/$BIG_FULL}
		BIG_ROWS+=("${ch//./ }")
	done
}

	# Ai - the real width when there is a terminal to ask, 80 when there is not
term_cols() {
	local r c
	if read -r r c < <(stty size 2>/dev/null < /dev/tty) \
		&& [[ "$c" =~ ^[0-9]+$ ]] && (( c > 20 )); then
		printf '%s' "$c"
	else
		printf '80'
	fi
}

stage_banner() {
	local name=$1 about=${2:-} where=${3:-}
	local cols bar row

	act_close

	cols="$(term_cols)"
	cols=$(( cols - 1 ))
	printf -v bar '%*s' "$cols" ''

	big_render "$name"

	printf '\n\n%s%s%s\n\n' "$C_BIG" "${bar// /$BIG_LOW}" "$C_OFF"

		# Ai - the tall letters already say the name, the line under them only
		#      says what the stage does and where it sits
		#      too narrow for the letters, the name takes their place instead
	if (( BIG_WIDTH + 4 <= cols )); then
		for row in "${BIG_ROWS[@]}"; do
			printf '  %s%s%s\n' "$C_BIG" "$row" "$C_OFF"
		done
		printf '\n'
	else
		printf '  %s%s%s\n\n' "$C_BIG" "${name^^}" "$C_OFF"
	fi

	printf '  %s' "$about"
	[[ -n "$where" ]] && printf '   %s%s%s' "$C_DIM" "$where" "$C_OFF"
	printf '\n'

	printf '%s%s%s\n\n' "$C_BIG" "${bar// /$BIG_HIGH}" "$C_OFF"

	printf '\n##### STAGE %s  %s  %s #####\n' "$name" "$about" "$(date -Is)" >&3
}



#    Running


## Verbose

VERBOSE="${REBUILD_VERBOSE:-0}"


## Why

	# Ai - the last helper that failed writes down what it was doing here
	#      a stop otherwise reaches the error trap as a bare return line, which
	#      is how the summary ended up saying only: return "$rc"
WHY=""


## Spin

	# Ai - the spinner line itself, output goes to the log
	#      a spinner alone cannot tell you whether this is a minute or ten,
	#      the count can
spin() {
	local label=$1; shift
	local frames='|/-\' i=0 pid start=$SECONDS rc=0

	"$@" >&3 2>&1 &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		printf '\r  [%s]    %s   %ss' \
			"${frames:i++%4:1}" "$label" "$(( SECONDS - start ))"
		sleep 0.2
	done
	wait "$pid" || rc=$?
	ELAPSED=$(( SECONDS - start ))
	printf '\r'
	blank

	return "$rc"
}


## Quiet

	# Ai - run hides output and shows one spinner line
	#      never give run an interactive command, it has no terminal
run() {
	act_close
	local label=$1; shift
	local rc=0 ELAPSED=0

	WHY=""
	printf 'RUN %s\n' "$*" >&3

	if [[ "$VERBOSE" == 1 ]]; then
		printf '  ..     %s\n' "$label"
		"$@" || rc=$?
	else
		spin "$label" "$@" || rc=$?
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

			# Ai - put the error on screen
			#      a path to a log file is not a message, it is homework
		printf '\n  what it actually said:\n\n' >&2
		tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
		printf '\n  full log  %s\n\n' "$LOG" >&2

		WHY="$label failed, exit $rc"
	fi

	return "$rc"
}


## Try

	# Ai - the same spinner, but a failure is one dim line and no log dump
	#      for a step that has another way to go when this one does not work
	#      a silent build looked like a hang, this shows it is still going
try() {
	local label=$1; shift
	local rc=0 ELAPSED=0

	printf 'TRY %s\n' "$*" >&3

	if [[ "$VERBOSE" == 1 ]]; then
		printf '  ..     %s\n' "$label"
		"$@" || rc=$?
	else
		spin "$label" "$@" || rc=$?
	fi

	if (( rc == 0 )); then
		printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
	else
		printf '  %s..%s     %s did not work, trying another way\n' "$C_DIM" "$C_OFF" "$label"
		printf 'TRY FAILED %s exit %s\n' "$*" "$rc" >&3
	fi

	return "$rc"
}


## Soft

	# Ai - same as run but a failure is advisory
soft() {
	local label=$1; shift
	if ! run "$label" "$@"; then
		flag "$label did not succeed, continuing"
		WHY=""
	fi
}


## Report

	# Ai - printed at the end of every stage and again at the end of the run
	#      duplicates are collapsed, because re-running a stage appends again
	#      each kind of problem gets its own banner in its own colour, so the
	#      orange block and the red block read apart at a glance
fail_block() {
	local colour=$1 title=$2 lines=$3

	[[ -n "${lines//[[:space:]]/}" ]] || return 0

	printf '\n' >&2
	printf '%s========================================%s\n' "$colour" "$C_OFF" >&2
	printf '%s %s%s\n' "$colour" "$title" "$C_OFF" >&2
	printf '%s========================================%s\n\n' "$colour" "$C_OFF" >&2
	printf '%s\n' "$lines" | sed 's/^/    /' >&2
}

show_failures() {
	local scope=${1:-all}
	local raw softs stops asides where=""

	[[ -s "$FAILLOG" ]] || return 0

	if [[ "$scope" == stage ]]; then
		raw="$(grep -P "\t$STAGE " "$FAILLOG" 2>/dev/null | awk '!seen[$0]++' || true)"
		where="   $STAGE"
	else
		raw="$(awk '!seen[$0]++' "$FAILLOG" 2>/dev/null || true)"
	fi

	[[ -n "${raw//[[:space:]]/}" ]] || return 0

	softs="$(printf '%s\n' "$raw" | sed -n 's/^soft\t//p' || true)"
	stops="$(printf '%s\n' "$raw" | sed -n 's/^stop\t//p' || true)"
	asides="$(printf '%s\n' "$raw" | sed -n 's/^aside\t//p' || true)"

	fail_block "$C_WARN" "SKIPPED, THE RUN CARRIED ON$where" "$softs"
	fail_block "$C_FAIL" "STOPPED THE SCRIPT$where" "$stops"

	if [[ -n "${asides//[[:space:]]/}" ]]; then
		printf '\n  %sWORTH KNOWING, nothing is broken%s\n\n' "$C_HEAD" "$C_OFF" >&2
		printf '%s\n' "$asides" | sed 's/^/    /' >&2
	fi

	printf '\n  full list  %s\n\n' "$FAILLOG" >&2
}


## Refresh

	# Ai - never called on a schedule, only when an install has already failed
	#      -Sy on its own is the thing that causes partial upgrades, so the
	#      refresh has to be a full -Syu or it makes the system worse
	#      a kernel upgrade mid run removes the running kernel's modules, which
	#      breaks anything that loads one until a reboot, so that gets flagged

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

	# Ai - stderr is copied into the log while stdout stays a terminal
	#      the progress bar needs a real terminal, the error needs to be findable
pac() {
	local start=$SECONDS plan

	printf '\n  packages   %s\n\n' "$*"
	printf 'pacman -S %s\n' "$*" >&3

		# Ai - --noconfirm answers every prompt with the default, which includes
		#      "yes, remove that" on a conflict
		#      a dry run first means an unexpected removal stops the stage
		#      instead of quietly happening while nobody is watching
	plan="$(capture $SUDO pacman -S --needed --print-format '%n' "$@")"

	if contains "$plan" "removing" || contains "$plan" "conflicts"; then
		flag "this install wants to remove or replace something, stopping"
		printf '%s\n' "$plan" | sed 's/^/    /' >&2
		WHY="installing $* would have removed something"
		return 1
	fi

	if $SUDO pacman -S --needed --noconfirm "$@" 2> >(tee -a "$LOG" >&2); then
		printf '\n  done in %ss\n' "$(( SECONDS - start ))"
		return 0
	fi

		# Ai - every mirror answering 404 for one filename means the local
		#      database is older than the mirrors, not that the network is down
		#      retrying the same request cannot fix that, only a refresh can

		# Ai - only the retry is announced here, the list gets a line only if
		#      the retry fails too, a problem that fixed itself is not one
	info "install failed, refreshing the database once and trying again"

	refresh_db

	$SUDO pacman -S --needed --noconfirm "$@" 2> >(tee -a "$LOG" >&2)
}


## Aur

aur() {
	printf '\n  aur build  %s\n\n' "$*"
	printf 'yay -S %s\n' "$*" >&3
		# Ai - --noconfirm alone is not enough, yay still stops to ask whether
		#      you want to see the diff, view the PKGBUILD or edit it, and the
		#      default answer to those is not always the one that continues
	local rc=0

	WHY=""

	yay -S --needed --noconfirm --answerdiff=None --answerclean=None \
		--answeredit=None --removemake "$@" 2> >(tee -a "$LOG" >&2) || rc=$?

		# Ai - an AUR build that fails otherwise reaches the summary as the whole
		#      yay command line, which says everything except which package
	(( rc == 0 )) || WHY="building $* from the AUR failed, exit $rc"

	return "$rc"
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

	# Ai - marker name always equals the file name, no hand typed strings
stage_done()    { touch "$MARKERS/${1:-$STAGE}"; }

stage_is_done() { [[ -f "$MARKERS/${1:-$STAGE}" ]]; }

require_stage() {
	[[ -f "$MARKERS/$1" ]] || { printf 'Run %s first\n' "$1" >&2; exit 1; }
}


#    Config


## Defaults

	# Ai - HOSTNAME is also a bash variable, so it is set here and only
	#      overwritten by the config file, never by the environment
HOSTNAME="CHANGEME"
USERNAME="CHANGEME"
KEYMAP="colemak"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
RETRY_LIMIT=10
TUNNEL_MTU=1420

	# Ai - seconds the boot menu shows before starting on its own
	#      three while the nested menu was unproven, one now that it has started
	#      Linux on its own on the real machine
	#      an arrow key still stops the count, it is just a smaller window
LIMINE_TIMEOUT=1


## Load

CONFIG="$HOME/.install-config"

[[ -f "$CONFIG" ]] && source "$CONFIG"

export USERNAME


## Save

	# Ai - never save a password, a passphrase or an account number here
save_cfg() {
	local k=$1 v=$2
	touch "$CONFIG"
	chmod 600 "$CONFIG"
	sed -i "/^$k=/d" "$CONFIG"
	printf '%s=%q\n' "$k" "$v" >> "$CONFIG"
}



#    Text


## Match

	# Ai - capture then match
	#      a pipeline into grep -q can take SIGPIPE and return 141 under pipefail
contains() { [[ "$1" == *"$2"* ]]; }


## Capture

	# Ai - capture returns the error text when a command fails or is missing
	#      so a non empty result does NOT mean success, and treating it as a
	#      value is how an error string ended up in a docker env file
capture() { "$@" 2>&1 || true; }


## Tailnet

	# Ai - empty unless there is a real tailnet address, checked by shape
tailnet_ip() {
	command -v tailscale > /dev/null 2>&1 || return 1

	local ip
	ip="$(tailscale ip -4 2>/dev/null || true)"
	ip="${ip//[[:space:]]/}"

	[[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1

	printf '%s' "$ip"
}



#    Asking


## Line

	# Ai - the prompt itself gets the marker, so a question never appears as a
	#      bare line with nothing saying it is still your turn
act_prompt() { printf '%s>>%s  %s' "$C_ACT" "$C_OFF" "$*"; }

ask() {
	local prompt=$1 default=${2:-} reply
	if [[ -n "$default" ]]; then
		read -rp "$(act_prompt "$prompt [$default]: ")" reply < /dev/tty
		printf '%s' "${reply:-$default}"
	else
		read -rp "$(act_prompt "$prompt: ")" reply < /dev/tty
		printf '%s' "$reply"
	fi
}


## Yes

	# Ai - the capital letter is the default, that is the whole convention
yesno() {
	local prompt=$1 default=${2:-n} hint reply

	if [[ "$default" == [yY]* ]]; then
		hint="(Y/n)"
	else
		hint="(y/N)"
	fi

	read -rp "$(act_prompt "$prompt $hint: ")" reply < /dev/tty

	reply="${reply:-$default}"

	[[ "$reply" == [yY]* ]]
}


## Confirm

	# Ai - YES in capitals says yes, anything else returns false so the caller
	#      can ask again instead of ending the whole run
confirmed() {
	local reply
	read -rp "$(act_prompt "${1:-Type YES to continue}: ")" reply < /dev/tty
	[[ "$reply" == YES ]]
}


## Secret

secret() {
	local prompt=$1 reply
	read -rsp "$(act_prompt "$prompt: ")" reply < /dev/tty
	printf '\n' > /dev/tty
	printf '%s' "$reply"
}


## Twice

	# Ai - every password is typed twice, a typo you cannot see is a reinstall
secret_twice() {
	local label=$1 a b
	while true; do
		a="$(secret "$label")"
		b="$(secret "$label again")"

		if [[ -z "$a" ]]; then
			act_line "Empty, type it again."
			continue
		fi

		if [[ "$a" == "$b" ]]; then
			printf '%s' "$a"
			return 0
		fi

		act_line "Those did not match, type it again."
	done
}



#    Helpers


## Online

	# Ai - a slow ping in a VM is almost never the internet
	#      ping resolves AAAA first and then sits waiting on an ipv6 route that
	#      does not exist, so ipv4 is forced and every probe gets a deadline
	#      routing and name resolution are tested separately, because they break
	#      for different reasons and need different fixes

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
			WHY="gave up after ${tries}s waiting for: $*"
			return 1
		fi
		sleep 1
	done
}


## Sudo

KEEPALIVE_PID=""

sudo_keepalive() {
	[[ -n "$SUDO" ]] || return 0
		# Ai - the prompt carries the block marker, so it reads as part of the block
	sudo -v -p "$(act_prompt 'Password for %p: ')"
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
		read -rp "$(act_prompt "$prompt")" dev < /dev/tty || { printf 'No input\n' >&2; exit 1; }
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


## Fstab

	# Ai - genfstab pins every btrfs mount by id as well as by name
	#      only the / line matters, a restore swaps in a new subvolume under the
	#      name @ with a new id, and a snapshot boot mounts another id again
	#      so / keeps the name alone, the other mounts never move
fstab_root_by_name() {
	local f=$1 old new
	old="$(cat "$f")"
	new="$(awk 'BEGIN { OFS = "\t" }
		$1 !~ /^#/ && $2 == "/" && $3 == "btrfs" {
			gsub(/,subvolid=[0-9]+/, "", $4)
			gsub(/subvolid=[0-9]+,/, "", $4)
		}
		{ print }' "$f")"
	[[ "$new" == "$old" ]] && return 0
	printf '%s\n' "$new" | $SUDO tee "$f" > /dev/null
}

fstab_root_named() {
	local r
	r="$(awk '$1 !~ /^#/ && $2 == "/"' "$1")"
	[[ -n "$r" ]] && ! contains "$r" "subvolid="
}


## Require

require_disk() {
	[[ -b "$1" ]] || { printf 'Not a block device: %s\n' "$1" >&2; exit 1; }
}



#    Verify


## State

FAILED=0

	# Ai - set once a stop is in the failure list, so it is never listed twice
STOP_RECORDED=0


## Check

check() {
	local label=$1; shift
	if "$@" >&3 2>&1; then
		printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
	else
		printf '  %s[FAIL]%s could not confirm: %s\n' "$C_FAIL" "$C_OFF" "$label" >&2
		record_fail "could not confirm: $label"
		FAILED=1
	fi
}


## Warn

warn() {
	local label=$1; shift
	if "$@" >&3 2>&1; then
		printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$label"
	else
		printf '  %s[warn]%s could not confirm: %s\n' "$C_WARN" "$C_OFF" "$label" >&2
		record_fail "could not confirm: $label"
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
		# Ai - captured first, before anything below can clobber it
	local rc=$?

	if [[ -n "$KEEPALIVE_PID" ]]; then
		kill "$KEEPALIVE_PID" 2>/dev/null || true
	fi

		# Ai - this runs whether the stage finished or died, which is the whole
		#      point, a stage that stops half way still has to tell you what
		#      went wrong before it stopped
	act_close

		# Ai - a deliberate exit never passes through the error trap first, so the
		#      stop is written down here, before the stage summary is printed
	if (( rc != 0 && STOP_RECORDED == 0 )); then
		STOP_RECORDED=1
		if (( FAILED )); then
			record_fail "stopped at Verify, a check listed above failed" stop
		elif (( rc == 130 )); then
			record_fail "stopped in ${SECTION:-setup}, interrupted with Ctrl+C" stop
		else
			record_fail "stopped in ${SECTION:-setup}, the reason is printed just above the stop" stop
		fi
	fi

		# Ai - run.sh prints the full list itself as its last word, repeating its
		#      own part here would push that list up the screen
	if [[ "$STAGE" != run || "$rc" != 0 ]]; then
		show_failures stage
	fi

	if [[ "$STAGE" != run && -z "${REBUILD_RUN:-}" ]]; then
		show_todos
	fi

	return "$rc"
}

trap cleanup EXIT


## Error

	# Ai - every failure path shows the error, not only the ones inside run()
	#      only the first stop is written down, anything after it is fallout
on_err() {
	local rc=$?
	local what="$BASH_COMMAND"
	local where="${SECTION:-setup}"

	(( STOP_RECORDED )) && return "$rc"

	case "$what" in
		exit*)
				# Ai - the exit handler already wrote this one down
			return "$rc" ;;
		return*)
				# Ai - a helper that failed has already put its output on screen,
				#      only the name of the step is missing
			STOP_RECORDED=1
			what="${WHY:-a step failed with exit $rc}"
			printf '\n  STOPPED  %s, in %s\n\n' "$what" "$where" >&2
			record_fail "$what, in $where" stop
			return "$rc" ;;
	esac

	STOP_RECORDED=1

	printf '\n  FAIL %s line %s, in %s\n' "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "$where" >&2
	printf '  cmd  %s\n' "$what" >&2

	printf '\n  what it actually said:\n\n' >&2
	tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
	printf '\n  full log  %s\n\n' "$LOG" >&2

	record_fail "$what, in $where" stop

	return "$rc"
}

trap on_err ERR
