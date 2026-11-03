#!/usr/bin/env bash

# Ai - compare, run as `rebuild compare`
#      what v1 had that this PC does not, read from the copy of v1 that
#      prep.sh left on the data disk as @old-system, and a way to bring each
#      thing over to the place it belongs, so nothing is moved by hand
#
#      rebuild compare              the list, then pick what to bring over
#      rebuild compare bring ID ... bring over these, the ids are in the list
#      rebuild compare delete       delete the copy of v1, once you are done
#
#      apps and the settings you changed by hand are also saved in this repo,
#      so a reinstall keeps them, files that hold something private are not

STEPS=3
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

OLD="${OLD_SYSTEM:-/mnt/data-root/@old-system}"
ROOT=/mnt/data-root
SCAN=(python3 -I "$SCRIPTS/compare.py")
PACKAGES="$CONF/packages.list"
CARRIED="$CONF/carried"

(( EUID != 0 )) || die "run it as yourself, not as root, it asks for sudo when it needs it"


#    The old system

# Ai - the copy lives on the data disk, whose root is mounted at /mnt/data-root,
#      a received snapshot is read only, so reading it can change nothing
open_old() {
	if [[ ! -d "$OLD/etc" ]] && ! mountpoint -q "$ROOT"; then
		quiet $SUDO mount "$ROOT" || die "the data disk's root did not mount at $ROOT"
	fi
	[[ -d "$OLD/etc" ]] || die "there is no copy of v1 on the data disk, prep.sh makes it on the old install"
}


#    Bring over

# Ai - one id is one thing: package:NAME, config:/etc/..., stray:/usr/..., local:/opt/...
bring_package() {
	local name=$1
	any "$name" "$name" || return 0
	if (( DRY == 0 )) && ! grep -qsx "$name" "$PACKAGES" 2> /dev/null; then
		printf '%s\n' "$name" >> "$PACKAGES"
		ok "$name is in config/packages.list, so a reinstall keeps it"
	fi
}

# Ai - a setting file goes to the same path, and into the repo so rebuild owns
#      it from then on, unless anyone could not read it, a wifi password
#      would end up on GitHub, so that stays on this PC only
bring_config() {
	local path=$1 src owner mode keep=1
	src="$OLD$path"
	[[ -e "$src" || -L "$src" ]] || { warn "$path is not in the copy of v1 any more"; return 0; }
	owner="$($SUDO "${SCAN[@]}" owner "$path" --old "$OLD" 2> /dev/null || true)"
	if [[ -n "$owner" ]] && ! installed "$owner"; then
		warn "$path belongs to $owner, bring that over first"
		return 0
	fi
	run "copy $path" $SUDO bash -c 'mkdir -p "$(dirname "$2")" && cp -a "$1" "$2"' _ "$src" "$path"
	mode="$($SUDO stat -c %a "$src")"
	if [[ ! -f "$src" || -L "$src" ]]; then keep=0; fi
	if (( (8#$mode & 8#004) == 0 )); then keep=0; fi
	if [[ "$path" =~ (\.key|\.pem|\.p12|secret|password|shadow|\.nmconnection)$ ]]; then keep=0; fi
	if (( keep == 1 )) && (( $($SUDO stat -c %s "$src" 2> /dev/null || echo 0) < 1048576 )); then
		if (( DRY == 0 )); then
			mkdir -p "$(dirname "$CARRIED$path")"
			install -m "$mode" "$src" "$CARRIED$path"
		fi
		ok "$path is in config/carried, so a reinstall keeps it"
	else
		dim "$path stays on this PC only, it is private or large"
	fi
}

# Ai - files and folders outside home, the same path, merged into what is there
bring_tree() {
	local path=$1 src
	src="$OLD$path"
	[[ -e "$src" || -L "$src" ]] || { warn "$path is not in the copy of v1 any more"; return 0; }
	if [[ -d "$src" && ! -L "$src" ]]; then
		run "copy $path" $SUDO bash -c 'mkdir -p "$2" && cp -a "$1/." "$2/"' _ "$src" "$path"
	else
		run "copy $path" $SUDO bash -c 'mkdir -p "$(dirname "$2")" && cp -a "$1" "$2"' _ "$src" "$path"
	fi
	dim "$path stays on this PC only, a reinstall would need the copy of v1 again"
}

bring() {
	local id kind
	for id in "$@"; do
		kind="${id%%:*}"
		case "$kind" in
			package)      bring_package "${id#*:}" ;;
			config)       bring_config "${id#*:}" ;;
			stray|local)  bring_tree "${id#*:}" ;;
			*)            warn "do not know what $id is" ;;
		esac
	done
}


#    Delete

forget_body() {
	printf '    %s%s%s is deleted, %s on the data disk\n' "$C_BAD" "$OLD" "$C_0" "$(du -sh "$OLD" 2> /dev/null | cut -f1)"
}

forget() {
	open_old
	if ! typed delete "Delete the copy of v1?" \
		"It is gone for good, and what you did not bring over cannot be recovered." forget_body; then
		dim "nothing was deleted"
		return 0
	fi
	run "delete the copy of v1" $SUDO btrfs subvolume delete "$OLD"
	quiet $SUDO rm -f /persist/state/old-system.done
	ok "the copy of v1 is gone"
}


#    Commands

case "${1:-}" in
	bring)
		shift
		(( $# > 0 )) || die "bring what? the ids are in the list: rebuild compare"
		title "Compare" "bring things over from v1"
		step "Old system"
		open_old
		ok "the copy of v1 is there"
		need_sudo
		step "Bring over"
		bring "$@"
		step "Done"
		ok "brought over"
		finish
		exit 0 ;;
	delete)
		title "Compare" "delete the copy of v1"
		step "Old system"
		need_sudo
		step "Delete"
		forget
		step "Done"
		finish
		exit 0 ;;
	""|list) ;;
	-h|--help|help)
		sed -n '/^#      rebuild/s/^#      /  /p' "$0"
		exit 0 ;;
	*) die "no such command: $1, see: rebuild compare help" ;;
esac

title "Compare" "what v1 had that this PC does not"


step "Old system"

open_old
ok "the copy of v1 is there"
	# Ai - read as root, some settings files are readable by nobody else
need_sudo
dim "reading it, this takes a minute"


step "What is missing"

LINES="$($SUDO "${SCAN[@]}" scan --lines --old "$OLD")"
IDS=() ITEMS=()
declare -A COUNT=([package]=0 [config]=0 [stray]=0 [local]=0)

# Ai - four groups, each in words that say what it is, numbered across all,
#      so a group is a range: apps 1-3, settings 4-7
for kind in package config stray local; do
	case "$kind" in
		package) tag="app     " ;;
		config)  tag="setting " ;;
		stray)   tag="file    " ;;
		local)   tag="program " ;;
	esac
	while IFS=$'\t' read -r id k t why waits; do
		[[ "$k" == "$kind" ]] || continue
		IDS+=("$id")
		COUNT[$kind]=$(( COUNT[$kind] + 1 ))
		if [[ -n "$waits" ]]; then
			ITEMS+=("$tag$t  ${C_DIM}$why, needs $waits first$C_0")
		else
			ITEMS+=("$tag$t  ${C_DIM}$why$C_0")
		fi
	done <<< "$LINES"
done
N=${#IDS[@]}

if (( N == 0 )); then
	ok "nothing is missing, this PC has everything v1 had"
	todo "When you are sure, delete the copy of v1:  rebuild compare delete"
	finish
	exit 0
fi
ok "${COUNT[package]} apps, ${COUNT[config]} settings, ${COUNT[stray]} files outside home, ${COUNT[local]} programs"
dim "Files this install writes itself are left alone, v1's version would undo what v2 set on purpose."


step "Bring over"

	# Ai - the screen lists everything, so nothing has to be remembered
LAST_A=${COUNT[package]}
LAST_S=$(( LAST_A + COUNT[config] ))
LAST_F=$(( LAST_S + COUNT[stray] ))
pick "What should come over from v1?" \
	"Apps are 1-$LAST_A, settings $(( LAST_A + 1 ))-$LAST_S, files $(( LAST_S + 1 ))-$LAST_F, programs $(( LAST_F + 1 ))-$N. Nothing is copied blind." \
	"${ITEMS[@]}" || exit 0

	# Ai - in the order of the list, so an app is in place before its settings
CHOSEN=()
for i in $(printf '%s\n' "${PICKED[@]}" | sort -nu); do CHOSEN+=("${IDS[i-1]}"); done

if (( ${#CHOSEN[@]} == 0 )); then
	dim "nothing chosen, run rebuild compare again any time"
else
	bring "${CHOSEN[@]}"
	todo "Run  rebuild compare  again to see what is left. When it is empty, or you no longer want the rest:  rebuild compare delete"
fi
finish
