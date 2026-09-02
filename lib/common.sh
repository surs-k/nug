#!/usr/bin/env bash



#    Debugging


## Charguard

for f in "$0" "${BASH_SOURCE[0]}"; do
	LC_ALL=C.UTF-8 grep -qnP '[\x{201C}\x{201D}\x{2018}\x{2019}\x{2014}\x{2013}]' "$f" \
		&& { echo "Smart punctuation in $f" >&2; exit 1; }
done


## Logging

STAGE="$(basename "$(dirname "$(readlink -f "$0")")")"

SUDO=""
	[[ $EUID -ne 0 ]] && SUDO="sudo"
	$SUDO mkdir -p /var/log/install

exec > >($SUDO tee -a "/var/log/install/$STAGE.log") 2>&1


## Markers

MARKERS="$HOME/.install-state"
mkdir -p "$MARKERS"

stage_done()    { touch "$MARKERS/$1"; }
require_stage() { [[ -f "$MARKERS/$1" ]] || { echo "Run $1 first" >&2; exit 1; }; }


## Trap

trap 'echo "FAIL ${BASH_SOURCE##*/}:$LINENO: $BASH_COMMAND" >&2' ERR



#    Config


## Disks

SYSTEM_DISK="${SYSTEM_DISK:-/dev/nvme0n1}"
DATA_DISK="${DATA_DISK:-/dev/nvme1n1}"


## Identity

HOSTNAME="${h:-CHANGEME}"
USERNAME="${u:-CHANGEME}"
KEYMAP="colemak"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"


## Overrides

CONFIG="$HOME/.install-config"
	[[ -f "$CONFIG" ]] && source "$CONFIG"

		# Machine-specific overrides


## Limits

RETRY_LIMIT=10



#    Partitions


## Suffix

partsuffix() { [[ "$1" =~ [0-9]$ ]] && printf p || printf ''; }


## Names

SYSPART1="${SYSTEM_DISK}$(partsuffix "$SYSTEM_DISK")1"
SYSPART2="${SYSTEM_DISK}$(partsuffix "$SYSTEM_DISK")2"
DATAPART1="${DATA_DISK}$(partsuffix "$DATA_DISK")1"



#    Helpers


## retry

retry() {
    local attempt=1
    local answer
    until "$@"; do
        if (( attempt >= RETRY_LIMIT )); then
            echo "" >&2
            echo "Failed $RETRY_LIMIT times:" >&2
            echo "  $*" >&2
            read -rp "Continue anyway? YES or NO: " answer
            [[ "$answer" == YES ]] && return 0
            exit 1
        fi
        echo "Attempt $attempt failed. Retrying..." >&2
        attempt=$(( attempt + 1 ))
        sleep 2
    done
}


## wait_for

wait_for() {
	local tries=$1; shift
	local n=0
	until "$@"; do
		n=$((n+1))
		if (( n >= tries )); then
			echo "TIMEOUT after ${tries}s: $*" >&2
			return 1
		fi
		sleep 1
	done
}


## confirm

confirm() {
    local answer
    read -rp "Type YES to continue: " answer
    [[ "$answer" == YES ]] || exit 1
}


## require_disk

require_disk() {
    [[ -b "$1" ]] || { echo "Not a block device: $1" >&2; exit 1; }
}


## check

FAILED=0
check() {
	local label=$1; shift
	if "$@" &>/dev/null; then
		echo "  ok    $label"
	else
		echo "  FAIL  $label" >&2
		FAILED=1
	fi
}
verify_done() { (( FAILED == 0 )) || { echo "verification failed" >&2; exit 1; }; }
