#!/usr/bin/env bash

	# Ai - limine-header-fix
	#      writes /boot/limine.conf in the one shape that starts on its own AND
	#      has room for snapshot entries, and checks that it really does
	#      not a stage, 05-iso runs it from the repo and 10-base installs it as
	#      /usr/local/bin/limine-header-fix, so there is only one copy of the logic

set -euo pipefail


#    Usage


usage() {
	cat << 'USAGEEOF'

  limine-header-fix               repair the boot menu, keep snapshot entries
  limine-header-fix --check       only report, change nothing
  limine-header-fix --flat        emergency shape, no snapshots in the menu
  limine-header-fix --nested      normal shape, snapshots in the menu
  limine-header-fix --timeout 3   seconds the menu waits before starting

  --root /mnt                     work on an install that is not running yet

USAGEEOF
}


#    Options


ROOT=""
MODE_ARG=""
TIMEOUT_ARG=""
CHECK=no

while [[ $# -gt 0 ]]; do
	case "$1" in
		--root)    ROOT="${2:-}"; ROOT="${ROOT%/}"; shift 2 ;;
		--flat)    MODE_ARG=flat;   shift ;;
		--nested)  MODE_ARG=nested; shift ;;
		--timeout) TIMEOUT_ARG="${2:-}"; shift 2 ;;
		--check)   CHECK=yes; shift ;;
		-h|--help) usage; exit 0 ;;
		*)
			printf 'unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2 ;;
	esac
done

BOOT="$ROOT/boot"
CONF="$BOOT/limine.conf"
SETTINGS="$ROOT/etc/rebuild-boot.conf"
CMDFILE="$ROOT/etc/kernel/cmdline"
MIDFILE="$ROOT/etc/machine-id"

OS_NAME="Arch Linux"
KERNEL_NAME="Linux"


#    Settings


## Read

	# Ai - BOOT_MODE and BOOT_TIMEOUT live in /etc/rebuild-boot.conf
	#      read line by line rather than sourced, so nothing in it can run
BOOT_MODE=nested
BOOT_TIMEOUT=3

if [[ -f "$SETTINGS" ]]; then
	while IFS='=' read -r k v; do
		v="${v//\"/}"
		case "$k" in
			BOOT_MODE)    BOOT_MODE="$v" ;;
			BOOT_TIMEOUT) BOOT_TIMEOUT="$v" ;;
		esac
	done < "$SETTINGS"
fi

[[ -n "$MODE_ARG" ]]    && BOOT_MODE="$MODE_ARG"
[[ -n "$TIMEOUT_ARG" ]] && BOOT_TIMEOUT="$TIMEOUT_ARG"


## Validate

case "$BOOT_MODE" in
	nested|flat) ;;
	*) printf 'BOOT_MODE must be nested or flat, got: %s\n' "$BOOT_MODE" >&2; exit 2 ;;
esac

	# Ai - a number only, "no" would mean never start on its own
if [[ ! "$BOOT_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
	printf 'BOOT_TIMEOUT must be a number of seconds, got: %s\n' "$BOOT_TIMEOUT" >&2
	exit 2
fi


#    Model


## Menu

	# Ai - reads a limine.conf and reports which entry limine will start
	#      limine numbers the entries it shows, and a folder only shows its
	#      contents when it is expanded with a plus, so both are tracked here
	#      the same number is also counted as a flat list, and the two have to
	#      agree, so the answer does not depend on which way limine counts
MENU_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

BEGIN { n = 0; cur = 0 }

{
	t = trim($0)
	if (t == "" || substr(t, 1, 1) == "#") next

	if (substr(t, 1, 1) == "/") {
		d = 0
		while (substr(t, d + 1, 1) == "/") d++
		rest = substr(t, d + 1)
		plus = 0
		if (substr(rest, 1, 1) == "+") { plus = 1; rest = substr(rest, 2) }
		n++
		depth[n] = d; expd[n] = plus; title[n] = trim(rest)
		proto[n] = ""; kpath[n] = ""; cmd[n] = ""; mods[n] = ""
		cur = n
		next
	}

	p = index(t, ":")
	if (p == 0) next
	key = tolower(trim(substr(t, 1, p - 1)))
	val = trim(substr(t, p + 1))

	if (key == "timeout" || key == "default_entry" || key == "quiet" || key == "remember_last_entry") {
		if (!(key in glob)) glob[key] = val
		next
	}

	if (cur == 0) next
	if (key == "protocol") proto[cur] = val
	else if (key == "path" || key == "kernel_path") kpath[cur] = val
	else if (key == "cmdline" || key == "kernel_cmdline") cmd[cur] = val
	else if (key == "module_path") mods[cur] = mods[cur] "\n" val
}

END {
	vis = 0
	for (i = 1; i <= n; i++) {
		isdir[i] = (i < n && depth[i + 1] > depth[i]) ? 1 : 0
		ok = 1
		for (k = 1; k < depth[i]; k++) if (!(k in anc) || anc[k] == 0) ok = 0
		anc[depth[i]] = expd[i]
		for (k = depth[i] + 1; k <= 16; k++) if (k in anc) delete anc[k]
		if (depth[i] == 1) top = title[i]
		parent[i] = (depth[i] == 1) ? "" : top
		if (ok) { vis++; vorder[vis] = i }
	}

	os = 0; osplus = 0; kfirst = 0; smark = 0; snaps = 0; zone = ""
	for (i = 1; i <= n; i++) {
		if (depth[i] == 1) {
			zone = ""; sub_zone = ""
			if (title[i] == osname && os == 0) { os = i; osplus = expd[i]; zone = "os" }
			continue
		}
		if (zone == "os" && depth[i] == 2) {
			if (i == os + 1 && tolower(title[i]) == tolower(kname) && proto[i] != "") kfirst = 1
			sub_zone = (title[i] == "Snapshots") ? "snap" : ""
			if (sub_zone == "snap") smark = 1
			continue
		}
		if (zone == "os" && sub_zone == "snap" && depth[i] >= 3 && proto[i] != "") snaps++
	}

	print "entries=" n
	print "has_timeout=" (("timeout" in glob) ? 1 : 0)
	print "timeout=" glob["timeout"]
	print "quiet=" glob["quiet"]
	print "remember=" glob["remember_last_entry"]

	de = ("default_entry" in glob) ? glob["default_entry"] : "1"
	print "default=" de

	vi = 0; fi = 0
	if (de ~ /^[0-9]+$/) {
		idx = de + 0
		if (idx >= 1 && idx <= vis) vi = vorder[idx]
		if (idx >= 1 && idx <= n) fi = idx
	}
	print "vis_entry=" vi
	print "flat_entry=" fi

	if (vi > 0) {
		print "title=" title[vi]
		print "parent=" parent[vi]
		print "dir=" isdir[vi]
		print "protocol=" proto[vi]
		print "path=" kpath[vi]
		print "cmdline=" cmd[vi]
		m = split(mods[vi], parts, "\n")
		for (j = 1; j <= m; j++) if (parts[j] != "") print "module=" parts[j]
	}

	print "os_found=" (os > 0 ? 1 : 0)
	print "os_plus=" osplus
	print "kernel_first=" kfirst
	print "snap_marker=" smark
	print "snap_entries=" snaps
}
'


## Split

	# Ai - takes an existing limine.conf apart into the pieces worth keeping
	#      the Arch entry itself is always rebuilt from the real files, what is
	#      kept is everything under it except the kernel, which is where the
	#      snapshot tool writes its entries, plus any other top level entries
SPLIT_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

BEGIN { zone = "hdr"; seen = 0; sz = "own" }

{
	line = $0
	sub(/\r$/, "", line)
	t = trim(line)

	if (substr(t, 1, 1) == "/") {
		d = 0
		while (substr(t, d + 1, 1) == "/") d++
		nm = substr(t, d + 1)
		if (substr(nm, 1, 1) == "+") nm = substr(nm, 2)
		nm = trim(nm)

		if (d == 1) {
			if (nm == osname && !seen) { zone = "os"; seen = 1; sz = "own"; next }
			else if (nm == osname)     { zone = "drop"; next }
			else                       zone = "rest"
		} else if (zone == "os" && d == 2) {
			if (tolower(nm) == tolower(kname))      sz = "skip"
			else if (nm == "Snapshots" && !keepsnap) sz = "skip"
			else                                    sz = "keep"
		}
	} else if (substr(t, 1, 1) != "#") {
		p = index(t, ":")
		if (p > 0) {
			k = tolower(trim(substr(t, 1, p - 1)))
			if (k == "timeout" || k == "default_entry" || k == "quiet" || k == "remember_last_entry") next
		}
	}

	if (zone == "hdr")       print line > hdrfile
	else if (zone == "os")   { if (sz == "keep") print line > keepfile }
	else if (zone == "rest") print line > restfile
}
'


#    Check


## Paths

	# Ai - boot():/x means /x on the partition holding limine.conf, which is
	#      the ESP mounted at /boot
boot_file() {
	local p=$1
	p="${p%%#*}"
	case "$p" in
		boot\(\):/*) printf '%s/%s' "$BOOT" "${p#boot():/}" ;;
		*)           return 1 ;;
	esac
}


## Report

row() { printf '  %-16s %s\n' "$1" "$2"; }

secs() { [[ "$1" == 1 ]] && printf '1 second' || printf '%s seconds' "$1"; }

check_conf() {
	local conf=$1
	local shown=${2:-$1}
	local out line k v f
	local has_timeout=0 timeout="" quiet="" remember="" default="" vis=0 flat=0
	local title="" parent="" dir=0 protocol="" kpath="" cmdline=""
	local os_found=0 os_plus=0 kernel_first=0 snap_marker=0 snap_entries=0
	local -a modules=()
	local bad=0

	if [[ ! -f "$conf" ]]; then
		row "limine.conf" "missing: $conf"
		return 1
	fi

	out="$(awk -v osname="$OS_NAME" -v kname="$KERNEL_NAME" "$MENU_AWK" "$conf")"

	while IFS= read -r line; do
		k="${line%%=*}"
		v="${line#*=}"
		case "$k" in
			has_timeout)  has_timeout="$v" ;;
			timeout)      timeout="$v" ;;
			quiet)        quiet="$v" ;;
			remember)     remember="$v" ;;
			default)      default="$v" ;;
			vis_entry)    vis="$v" ;;
			flat_entry)   flat="$v" ;;
			title)        title="$v" ;;
			parent)       parent="$v" ;;
			dir)          dir="$v" ;;
			protocol)     protocol="$v" ;;
			path)         kpath="$v" ;;
			cmdline)      cmdline="$v" ;;
			module)       modules+=("$v") ;;
			os_found)     os_found="$v" ;;
			os_plus)      os_plus="$v" ;;
			kernel_first) kernel_first="$v" ;;
			snap_marker)  snap_marker="$v" ;;
			snap_entries) snap_entries="$v" ;;
		esac
	done <<< "$out"

	row "file" "$shown"

		# Ai - every line below that says FAIL is a reason it would not start alone
	if [[ "$has_timeout" != 1 ]]; then
		row "timeout" "FAIL  missing"
		bad=1
	elif [[ ! "$timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		row "timeout" "FAIL  $timeout, it would never start on its own"
		bad=1
	else
		row "timeout" "$(secs "$timeout")"
	fi

	if [[ "${quiet,,}" == yes ]]; then
		row "quiet" "FAIL  on, it hides the reason a boot fails"
		bad=1
	fi

	if [[ "${remember,,}" == yes ]]; then
		row "remember" "FAIL  on, one snapshot boot would become the default"
		bad=1
	fi

	if [[ ! "$default" =~ ^[0-9]+$ ]]; then
		row "default entry" "FAIL  $default is not an entry number"
		bad=1
	elif (( vis == 0 )); then
		row "default entry" "FAIL  #$default is past the end of the menu"
		bad=1
	elif (( vis != flat )); then
		row "default entry" "FAIL  #$default means different entries depending on how it is counted"
		bad=1
	else
		if [[ -n "$parent" ]]; then
			row "default entry" "#$default  $title, inside $parent"
		else
			row "default entry" "#$default  $title"
		fi

			# Ai - a folder has nothing of its own to check, and it is the
			#      one reason that matters, the rest would only be noise
		if (( dir == 1 )); then
			row "shape" "FAIL  that entry is a folder, limine will not start a folder"
			bad=1
		elif [[ -z "$protocol" ]]; then
			row "protocol" "FAIL  none, the entry cannot boot"
			bad=1
		fi

		if (( dir == 1 )); then
			:
		elif [[ -z "$kpath" ]]; then
			row "kernel" "FAIL  no path"
			bad=1
		elif f="$(boot_file "$kpath")"; then
			if [[ -f "$f" ]]; then
				row "kernel" "$kpath  found"
			else
				row "kernel" "FAIL  $kpath  not on the ESP"
				bad=1
			fi
		else
			row "kernel" "$kpath  not checked"
		fi

		(( dir == 1 )) && modules=()

		for v in "${modules[@]}"; do
			if f="$(boot_file "$v")"; then
				if [[ -f "$f" ]]; then
					row "module" "$v  found"
				else
					row "module" "FAIL  $v  not on the ESP"
					bad=1
				fi
			else
				row "module" "$v  not checked"
			fi
		done

		if (( dir == 0 )) && [[ "$cmdline" != *root=* ]]; then
			row "cmdline" "FAIL  no root=, the kernel would not find the system"
			bad=1
		fi
	fi

	if [[ "$BOOT_MODE" == nested ]]; then
		if (( os_found == 0 || os_plus == 0 || kernel_first == 0 )); then
			row "shape" "FAIL  not /+$OS_NAME with //$KERNEL_NAME first inside it"
			bad=1
		fi

		if [[ -n "$cmdline" && "$cmdline" != *rootflags=subvol=/@* ]]; then
			row "snapshots" "warn  cmdline lacks rootflags=subvol=/@, the snapshot tool needs it"
		fi

		if (( snap_marker == 1 )); then
			row "snapshots" "$snap_entries in the menu"
		else
			row "snapshots" "none yet, the menu gets them once 50-bkp-net runs"
		fi
	fi

	if (( bad == 0 )); then
		row "result" "starts on its own"
		return 0
	fi

	row "result" "FAIL  would not start on its own"
	return 1
}


if [[ "$CHECK" == yes ]]; then
	printf '\n'
	if check_conf "$CONF"; then
		printf '\n'
		exit 0
	fi
	printf '\n'
	exit 1
fi


#    Write


## Guard

if [[ $EUID -ne 0 ]]; then
	printf 'run with sudo, this writes to the ESP\n' >&2
	exit 1
fi

if [[ ! -d "$BOOT" ]]; then
	printf 'no %s, is the ESP mounted\n' "$BOOT" >&2
	exit 1
fi

	# Ai - the snapshot tool runs this after every save, and a stage may run it
	#      at the same moment, so only one copy writes at a time
if command -v flock > /dev/null && [[ -d /run/lock ]]; then
	exec 9> /run/lock/limine-header-fix.lock
	flock -w 60 9 || { printf 'another copy is still writing, giving up\n' >&2; exit 1; }
fi


## Inputs

	# Ai - refuse to write anything without a real cmdline to put in it
CMDLINE=""
[[ -f "$CMDFILE" ]] && CMDLINE="$(tr -s '[:space:]' ' ' < "$CMDFILE")"
CMDLINE="${CMDLINE# }"
CMDLINE="${CMDLINE% }"

if [[ -z "$CMDLINE" ]]; then
	printf 'no %s, refusing to write limine.conf\n' "$CMDFILE" >&2
	exit 1
fi

MID=""
[[ -f "$MIDFILE" ]] && MID="$(tr -d '[:space:]' < "$MIDFILE")"

	# Ai - snapshot entries only have a home while the tool that makes them is
	#      installed, once it is gone its old entries go too
SNAPTOOL=no
[[ -x "$ROOT/usr/bin/limine-snapper-sync" ]] && SNAPTOOL=yes


## Split

WORK="$(mktemp -d)"
NEW="$(mktemp "$BOOT/.limine.conf.XXXXXX")"

cleanup_tmp() { rm -rf "$WORK"; rm -f "$NEW"; }
trap cleanup_tmp EXIT

: > "$WORK/hdr"
: > "$WORK/keep"
: > "$WORK/rest"

KEEPSNAP=0
[[ "$SNAPTOOL" == yes ]] && KEEPSNAP=1

if [[ -f "$CONF" ]]; then
	awk -v osname="$OS_NAME" -v kname="$KERNEL_NAME" -v keepsnap="$KEEPSNAP" \
		-v hdrfile="$WORK/hdr" -v keepfile="$WORK/keep" -v restfile="$WORK/rest" \
		"$SPLIT_AWK" "$CONF"
fi

	# Ai - blank lines at either end of a piece are dropped, the gaps between
	#      pieces are put back one at a time below
squeeze() {
	awk '
		NF { for (; blank > 0; blank--) print ""; print; started = 1; next }
		started { blank++ }
	' "$1"
}

HDR="$(squeeze "$WORK/hdr")"
KEEP="$(squeeze "$WORK/keep")"
REST="$(squeeze "$WORK/rest")"

	# Ai - the flat shape cannot hold anything under the entry, a single sub
	#      entry turns it back into a folder
[[ "$BOOT_MODE" == flat ]] && KEEP=""

if [[ "$BOOT_MODE" == nested && "$SNAPTOOL" == yes && "$KEEP" != *//Snapshots* && "$KEEP" != *//+Snapshots* ]]; then
	KEEP="${KEEP:+$KEEP$'\n'}    //Snapshots"
fi


## Build

	# Ai - nested is the normal shape
	#      the folder is expanded with the plus, the kernel is the first thing in
	#      it, so entry 1 is the folder and entry 2 is the kernel, and
	#      default_entry points straight at the kernel
	#      flat is the escape hatch, one bootable entry and nothing under it

kernel_lines() {
	local pad=$1
	printf '%sprotocol: linux\n' "$pad"
	printf '%spath: boot():/vmlinuz-linux\n' "$pad"
	[[ -f "$BOOT/intel-ucode.img" ]] && printf '%smodule_path: boot():/intel-ucode.img\n' "$pad"
	[[ -f "$BOOT/amd-ucode.img" ]]   && printf '%smodule_path: boot():/amd-ucode.img\n' "$pad"
	printf '%smodule_path: boot():/initramfs-linux.img\n' "$pad"
	printf '%scmdline: %s\n' "$pad" "$CMDLINE"
}

{
	printf 'timeout: %s\n' "$BOOT_TIMEOUT"

	[[ "$BOOT_MODE" == nested ]] && printf 'default_entry: 2\n'

	[[ -n "$HDR" ]] && printf '%s\n' "$HDR"

	printf '\n'

	if [[ "$BOOT_MODE" == nested ]]; then
		printf '/+%s\n' "$OS_NAME"
		[[ -n "$MID" ]] && printf '    comment: machine-id=%s\n' "$MID"
		printf '    //%s\n' "$KERNEL_NAME"
		kernel_lines '        '
		[[ -n "$KEEP" ]] && printf '%s\n' "$KEEP"
	else
		printf '/%s\n' "$OS_NAME"
		[[ -n "$MID" ]] && printf '    comment: machine-id=%s\n' "$MID"
		kernel_lines '    '
	fi

	if [[ -n "$REST" ]]; then
		printf '\n'
		printf '%s\n' "$REST"
	fi
} > "$NEW"


## Prove

	# Ai - the new file has to pass the same check, or it is not written at all
	#      a menu that cannot start is never put in place of one that can
if ! REPORT="$(check_conf "$NEW" "$CONF")"; then
	printf '\n  refusing to write, the result would not start on its own\n\n' >&2
	printf '%s\n\n' "$REPORT" >&2
	exit 1
fi


## Save

	# Ai - a choice given on the command line is remembered for every later run,
	#      including the ones the snapshot tool starts on its own
if [[ -n "$MODE_ARG$TIMEOUT_ARG" || ! -f "$SETTINGS" ]]; then
	mkdir -p "$(dirname "$SETTINGS")"
	printf 'BOOT_MODE=%s\nBOOT_TIMEOUT=%s\n' "$BOOT_MODE" "$BOOT_TIMEOUT" > "$SETTINGS"
fi

if [[ -f "$CONF" ]] && cmp -s "$NEW" "$CONF"; then
	printf 'boot menu already correct, %s shape, %s\n' "$BOOT_MODE" "$(secs "$BOOT_TIMEOUT")"
else
	[[ -f "$CONF" ]] && cp -f "$CONF" "$CONF.prev"
	mv -f "$NEW" "$CONF"
	sync
	printf 'boot menu written, %s shape, %s\n' "$BOOT_MODE" "$(secs "$BOOT_TIMEOUT")"
	[[ -f "$CONF.prev" ]] && printf 'previous version kept at %s.prev\n' "$CONF"
fi

printf '%s\n' "$REPORT"


## Watcher

	# Ai - the sync tool cannot work with the flat shape and would complain on
	#      every snapshot, so it is paused with it and resumed with nested
	#      only on a running system, never inside --root
if [[ -z "$ROOT" && -n "$MODE_ARG" ]] && command -v systemctl > /dev/null; then
	if systemctl cat limine-snapper-sync.service > /dev/null 2>&1 \
		&& [[ "$SNAPTOOL" == yes ]]; then
		if [[ "$MODE_ARG" == flat ]]; then
			systemctl disable --now limine-snapper-sync.service > /dev/null 2>&1 || true
			printf 'snapshot sync paused, limine-header-fix --nested turns it back on\n'
		else
			systemctl enable --now limine-snapper-sync.service > /dev/null 2>&1 || true
			printf 'snapshot sync running\n'
		fi
	fi
fi

exit 0
