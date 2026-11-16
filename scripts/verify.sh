#!/usr/bin/env bash

	# Ai - rebuild verify: what this system really is, in plain words
	#      it changes nothing, it only looks
	#      every line says what was found, why it matters, and the command
	#      that shows the same thing, so nothing here has to be taken on trust
	#      no addresses, serials or keys are printed or saved, only yes and no,
	#      names and counts
	#      stands alone on purpose, a stage library that stops on errors is
	#      the wrong base for a tool whose job is to find them

set -uo pipefail

REPORT="${REPORT:-$HOME/rebuild-report.txt}"

PLAIN=0
[[ "${1:-}" == "--plain" || ! -t 1 ]] && PLAIN=1

if (( PLAIN )); then
	G="" Y="" R="" D="" O=""
else
	G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' O=$'\e[0m'
fi

N_OK=0 N_LOOK=0 N_BAD=0 N_GAP=0

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT


#    Output

head1() { printf '\n\n%s\n%s\n\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '=')" | tee -a "$OUT"; }

	# Ai - ok    as wanted
	#      look  works, but worth your eyes or a decision
	#      bad   not as wanted, and it weakens something
	#      gap   wanted in SPEC.md, not built yet
line() {
	local kind=$1 text=$2 why=${3:-} see=${4:-} tag col
	case "$kind" in
		ok)   tag="[ ok ]"; col=$G; N_OK=$((N_OK+1)) ;;
		look) tag="[look]"; col=$Y; N_LOOK=$((N_LOOK+1)) ;;
		bad)  tag="[ bad]"; col=$R; N_BAD=$((N_BAD+1)) ;;
		gap)  tag="[ gap]"; col=$Y; N_GAP=$((N_GAP+1)) ;;
		*)    tag="[info]"; col=$D ;;
	esac
	printf '  %s%s%s  %s\n' "$col" "$tag" "$O" "$text"
	printf '  %s  %s\n' "$tag" "$text" >> "$OUT"
	if [[ -n "$why" ]]; then
		printf '          %swhy   %s%s\n' "$D" "$why" "$O"
		printf '          why   %s\n' "$why" >> "$OUT"
	fi
	if [[ -n "$see" ]]; then
		printf '          %scheck %s%s\n' "$D" "$see" "$O"
		printf '          check %s\n' "$see" >> "$OUT"
	fi
}

have() { command -v "$1" > /dev/null 2>&1; }

	# Ai - root is asked for once, and every check that needs it says so when
	#      it could not get it, instead of reporting a wrong answer
ROOT_OK=0
if [[ $EUID -eq 0 ]]; then
	ROOT_OK=1
elif sudo -n true 2>/dev/null; then
	ROOT_OK=1
elif [[ -t 0 ]]; then
	printf '\n  Some checks read things only root can see. Your password, once:\n\n'
	sudo -v && ROOT_OK=1
fi

root() {
	if [[ $EUID -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

VIRT="$(systemd-detect-virt 2>/dev/null || true)"
IN_VM=0
[[ -n "$VIRT" && "$VIRT" != none ]] && IN_VM=1

printf 'Rebuild verify report\n%s\n' "$(date '+%Y-%m-%d %H:%M')" > "$OUT"
(( IN_VM )) && printf 'Running inside a virtual machine (%s)\n' "$VIRT" >> "$OUT"

printf '\n  Rebuild verify   %s\n' "$(date '+%Y-%m-%d %H:%M')"
(( IN_VM )) && printf '  Inside a virtual machine (%s): hardware checks describe the VM, not your PC.\n' "$VIRT"
(( ROOT_OK )) || printf '  %sNo root access: checks that need it are marked.%s\n' "$Y" "$O"



#    Security


head1 "Security: who can get in"


## Disks

crypt_under() {
	local src
	src="$(findmnt -no SOURCE "$1" 2>/dev/null | sed 's/\[.*//')"
	[[ -n "$src" ]] || return 2
	lsblk -snro TYPE "$src" 2>/dev/null | grep -qx crypt
}

for mp in / /home; do
	if crypt_under "$mp"; then
		line ok "$mp is on an encrypted disk" \
			"a stolen or resold disk shows nothing without the key" \
			"lsblk -o NAME,TYPE,MOUNTPOINTS"
	else
		line bad "$mp is NOT on an encrypted disk" \
			"anyone holding the disk can read it" \
			"lsblk -o NAME,TYPE,MOUNTPOINTS"
	fi
done


## Unlock

SB=unknown
if have bootctl; then
	case "$(bootctl status 2>/dev/null | sed -n 's/^ *Secure Boot: *//p' | head -n1)" in
		enabled*) SB=on ;;
		disabled*) SB=off ;;
	esac
fi

TPM_UNLOCK=unknown
PIN=unknown
SLOTS=unknown
ROOTDEV="$(findmnt -no SOURCE / | sed 's/\[.*//')"
LUKSDEV="$(lsblk -snrpo NAME,TYPE "$ROOTDEV" 2>/dev/null | awk '$2=="part" || $2=="disk" {print $1; exit}')"

if (( ROOT_OK )) && [[ -n "$LUKSDEV" ]]; then
	DUMP="$(root cryptsetup luksDump "$LUKSDEV" 2>/dev/null || true)"
	if [[ -n "$DUMP" ]]; then
		if grep -q 'systemd-tpm2' <<< "$DUMP"; then TPM_UNLOCK=yes; else TPM_UNLOCK=no; fi
		if grep -q 'tpm2-pin: *true' <<< "$DUMP"; then PIN=yes; else PIN=no; fi
		SLOTS="$(grep -cE '^ +[0-9]+: luks2' <<< "$DUMP")"
	fi
fi

case "$SB" in
	on)  line ok "Secure Boot is on" "the firmware only starts boot files that are signed" "bootctl status" ;;
	off) line gap "Secure Boot is off" \
			"SPEC wants it on; without it nothing checks the boot files before the disk unlocks" \
			"bootctl status" ;;
	*)   line look "Could not read the Secure Boot state" "" "bootctl status" ;;
esac

case "$TPM_UNLOCK" in
	yes)
		if [[ "$SB" == on || "$PIN" == yes ]]; then
			line ok "The system disk unlocks through the TPM chip" \
				"no passphrase typed at boot, and the unlock is tied to checked boot files or a PIN" \
				"sudo cryptsetup luksDump <system partition>"
		else
			line bad "The system disk unlocks by itself, with Secure Boot off and no PIN" \
				"whoever holds the PC can change the boot line, get a root shell, and the disk opens for them; the encryption then only protects a disk taken out of the PC" \
				"sudo cryptsetup luksDump <system partition>   (look for systemd-tpm2 and tpm2-pin)"
		fi ;;
	no)
		line look "The system disk asks for its passphrase at every boot" \
			"safe; SPEC wants TPM unlock with Secure Boot so only the login password is typed" \
			"sudo cryptsetup luksDump <system partition>" ;;
	*)
		line look "Could not read how the system disk unlocks (needs root)" "" "sudo rebuild verify" ;;
esac

[[ "$SLOTS" =~ ^[0-9]+$ ]] && line info "The system disk has $SLOTS way(s) to unlock it (passphrase, TPM, key files)" \
	"each one is a door; more than you expect is worth a look" \
	"sudo systemd-cryptenroll <system partition>"


## Boot menu

CONF=/boot/limine.conf
if [[ -r "$CONF" ]] || (( ROOT_OK )); then
	LIM="$(cat "$CONF" 2>/dev/null || root cat "$CONF" 2>/dev/null || true)"
	if grep -qiE '^\s*editor_enabled:\s*no' <<< "$LIM"; then
		line ok "The boot menu editor is off" "nobody at the keyboard can rewrite the boot line" "grep editor_enabled /boot/limine.conf"
	else
		line look "The boot menu editor is on" \
			"anyone at the keyboard during boot can add one word to the boot line and get a root shell; turning it off costs you the same trick for repairs" \
			"grep editor_enabled /boot/limine.conf"
	fi
fi


## Firewall

if have ufw && (( ROOT_OK )); then
	UFW="$(root ufw status verbose 2>/dev/null || true)"
	if grep -q 'Status: active' <<< "$UFW"; then
		if grep -q 'deny (incoming)' <<< "$UFW"; then
			line ok "Firewall is on and refuses incoming connections by default" "" "sudo ufw status verbose"
		else
			line bad "Firewall is on but does not refuse incoming connections by default" "" "sudo ufw status verbose"
		fi
		RULES="$(root ufw status 2>/dev/null | grep -c 'ALLOW' || true)"
		line info "Firewall has $RULES allow rule(s)" "each is a deliberate hole; read them once" "sudo ufw status numbered"
	else
		line bad "Firewall is off" "every listening program is reachable from the network" "sudo ufw status"
	fi
elif ! have ufw; then
	line bad "No firewall installed (ufw)" "" "pacman -Q ufw"
else
	line look "Firewall state needs root to read" "" "sudo ufw status verbose"
fi


## Listening

	# Ai - only the port and the program, and whether it listens on every
	#      network or just this machine, never an address
if have ss; then
	OPEN="$( { if (( ROOT_OK )); then root ss -H -tulnp; else ss -H -tulnp; fi; } 2>/dev/null | awk '
		{
			addr=$5; n=split(addr, a, ":"); port=a[n]
			host=substr(addr, 1, length(addr)-length(port)-1)
			if (host ~ /^127\./ || host == "[::1]" || host ~ /^\[::ffff:127\./ || host ~ /%lo$/) next
			prog="unknown"
			if (match($0, /users:\(\("[^"]+"/)) { prog=substr($0, RSTART+9, RLENGTH-9); gsub(/"/, "", prog) }
			scope=(host=="0.0.0.0" || host=="*" || host=="[::]") ? "every network" : "one network"
			print $1 " port " port "  " prog "  (" scope ")"
		}' | sort -u)"
	if [[ -z "$OPEN" ]]; then
		line ok "Nothing listens for connections from outside this PC" "" "sudo ss -tulnp"
	else
		COUNT="$(wc -l <<< "$OPEN")"
		line look "$COUNT thing(s) listen beyond this PC (the firewall decides who reaches them)" \
			"each should be something you chose to run" "sudo ss -tulnp"
		while IFS= read -r l; do
			printf '            %s\n' "$l" | tee -a "$OUT"
		done <<< "$OPEN"
	fi
fi


## SSH

if systemctl is-enabled --quiet sshd 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
	if (( ROOT_OK )); then
		SSHD="$(root sshd -T 2>/dev/null || true)"
		if grep -qi '^passwordauthentication no' <<< "$SSHD"; then
			line ok "Remote login (SSH) is on, keys only" "password guessing cannot work" "sudo sshd -T | grep -i passwordauth"
		else
			line look "Remote login (SSH) is on and accepts passwords" \
				"anyone who can reach the port can guess passwords; keys only is safer" \
				"sudo sshd -T | grep -i passwordauth"
		fi
		grep -qi '^permitrootlogin no' <<< "$SSHD" \
			|| line look "SSH does not forbid logging in as root outright" "" "sudo sshd -T | grep -i permitroot"
	else
		line look "Remote login (SSH) is on; its settings need root to read" "" "sudo sshd -T"
	fi
else
	line ok "Remote login (SSH) is off" "" "systemctl is-enabled sshd"
fi


## Sudo

if (( ROOT_OK )); then
	NOPASS="$(root grep -rhs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -v '^\s*#' || true)"
	if [[ -z "$NOPASS" ]]; then
		line ok "Every admin action asks for your password" "" "sudo grep -r NOPASSWD /etc/sudoers.d"
	elif grep -qE 'NOPASSWD: *ALL' <<< "$NOPASS"; then
		if (( IN_VM )) && root test -f /etc/sudoers.d/99-vm-test; then
			line look "Admin rights need no password (the VM test rule, never written on a real PC)" \
				"the hands off test needs it; on your real PC this line must not appear" \
				"sudo cat /etc/sudoers.d/99-vm-test"
		else
			line bad "Some account has admin rights with no password at all" \
				"any program you run can take over the whole system silently" \
				"sudo grep -r NOPASSWD /etc/sudoers.d"
		fi
	else
		line look "$(wc -l <<< "$NOPASS") admin command(s) run without a password" \
			"set up on purpose for the health check and similar; each should be narrow" \
			"sudo grep -r NOPASSWD /etc/sudoers.d"
	fi
fi

if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
	line look "Your account is in the input group" \
		"every program you run can read every key you type; only game streaming setups need it" \
		"id -nG"
fi

for g in docker libvirt; do
	if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
		line info "Your account is in the $g group" "that group can do almost anything root can; normal for using $g without sudo" "id -nG"
	fi
done


## Software

if have checkupdates; then
	UPD="$(timeout 90 checkupdates 2>/dev/null | wc -l)"
	if (( UPD == 0 )); then
		line ok "No updates waiting" "" "checkupdates"
	else
		line look "$UPD update(s) waiting" "updates carry security fixes; you start them yourself" "checkupdates"
	fi
fi

FOREIGN="$(pacman -Qmq 2>/dev/null | wc -l)"
line info "$FOREIGN package(s) come from outside the official Arch repos" \
	"these are built from recipes anyone can publish; each is trust in its author" \
	"pacman -Qm"

FAILED_UNITS="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
if [[ -z "$FAILED_UNITS" ]]; then
	line ok "No system service has failed" "" "systemctl --failed"
else
	line bad "Failed system service(s): $(tr '\n' ' ' <<< "$FAILED_UNITS")" "" "systemctl --failed"
fi



#    Privacy


head1 "Privacy: what leaves this PC"


## VPN

if have mullvad; then
	MS="$(timeout 8 mullvad status 2>/dev/null | head -n1 || true)"
	if grep -q '^Connected' <<< "$MS"; then
		line ok "VPN is connected" "" "mullvad status"
	elif (( IN_VM )); then
		line look "VPN is not connected (the VM test has no VPN account, so this is expected here)" "" "mullvad status"
	else
		line bad "VPN is not connected" "your traffic leaves from your own internet address" "mullvad status"
	fi

		# Ai - the answer is the last word, the sentence itself contains "on"
	if grep -qiE ':\s*on\s*$' <<< "$(timeout 8 mullvad auto-connect get 2>/dev/null)"; then
		line ok "VPN connects by itself at startup" "" "mullvad auto-connect get"
	else
		line look "VPN does not connect by itself at startup" "" "mullvad auto-connect get"
	fi

	if grep -qiE ':\s*on\s*$' <<< "$(timeout 8 mullvad lockdown-mode get 2>/dev/null)"; then
		line ok "Lockdown is on: no traffic at all while the VPN is down" "" "mullvad lockdown-mode get"
	else
		line look "Lockdown is off: when the VPN is switched off, traffic goes out bare" \
			"the install leaves this to you; turn it on in the Mullvad app once settled" \
			"mullvad lockdown-mode get"
	fi

	if grep -qi 'block' <<< "$(timeout 8 mullvad dns get 2>/dev/null)"; then
		line ok "VPN blocks ads, trackers and malware at the name lookup" "" "mullvad dns get"
	else
		line look "VPN content blocking is not set" "" "mullvad dns get"
	fi
else
	line bad "No VPN installed" "" "pacman -Q mullvad-vpn"
fi


## DNS

	# Ai - which link answers name lookups, by its name only
if have resolvectl; then
	DNSLINKS="$(timeout 8 resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!="" {gsub(/^Link [0-9]+ \(|\)$/, "", $1); print $1}' | sort -u | tr '\n' ' ')"
	if grep -qi 'mullvad\|wg' <<< "$DNSLINKS"; then
		line ok "Name lookups go through the VPN link" "what you look up is not shown to your internet provider" "resolvectl dns"
	elif [[ -n "$DNSLINKS" ]]; then
		line look "Name lookups go out through: $DNSLINKS" \
			"with the VPN down, your internet provider sees every site name you look up" \
			"resolvectl dns"
	fi
fi


## Watcher

if pacman -Qq opensnitch > /dev/null 2>&1; then
	if systemctl is-active --quiet opensnitchd 2>/dev/null; then
		line ok "The connection watcher (OpenSnitch) is running" \
			"its window lists every connection by program; open OpenSnitch from the app launcher" \
			"systemctl status opensnitchd"
		if (( ROOT_OK )); then
			RULES_OS="$(root sh -c 'ls /etc/opensnitchd/rules 2>/dev/null | wc -l')"
			line info "The watcher has $RULES_OS saved rule(s)" "each is an answer you gave: this program may, or may not, connect there" "OpenSnitch window, Rules tab"
			if root grep -q '"DefaultAction": *"allow"' /etc/opensnitchd/default-config.json 2>/dev/null; then
				line look "Connections nobody answers for are allowed" \
					"the learning setting: nothing breaks while you watch; switch to deny in OpenSnitch, Preferences, once your rules look right" \
					"sudo grep DefaultAction /etc/opensnitchd/default-config.json"
			else
				line ok "Connections nobody answers for are refused" "" "sudo grep DefaultAction /etc/opensnitchd/default-config.json"
			fi
		fi
	else
		line bad "The connection watcher (OpenSnitch) is installed but not running" "nothing is being shown or asked" "systemctl status opensnitchd"
	fi
else
	line look "No connection watcher installed" "there is no window showing which program connects where" "rebuild --only 85-connections"
fi

if pacman -Qq gufw > /dev/null 2>&1; then
	line ok "The firewall has a window (Gufw)" "open Firewall Configuration from the app launcher" "pacman -Q gufw"
fi


## Services

if have docker && (( ROOT_OK )) && systemctl is-active --quiet docker 2>/dev/null; then
	WIDE="$(root timeout 10 docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|\[::\]:' | awk '{print $1}' | tr '\n' ' ')"
	TOTAL="$(root timeout 10 docker ps -q 2>/dev/null | wc -l)"
	if [[ -z "$WIDE" ]]; then
		line ok "$TOTAL self hosted service(s) running, none reachable from outside this PC" "" "docker ps"
	else
		line look "Self hosted service(s) open to the network: $WIDE" \
			"fine if you meant to reach them from another device, otherwise they should bind to this PC only" \
			"docker ps"
	fi
fi

if have bluetoothctl && timeout 5 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
	line look "Bluetooth is switched on" "it announces this PC to anything nearby; you said you rarely use it" "bluetoothctl show"
fi

if systemctl is-active --quiet geoclue 2>/dev/null; then
	line look "A location service (geoclue) is running" "apps can ask it where this PC is" "systemctl status geoclue"
fi

if systemctl is-active --quiet tailscaled 2>/dev/null; then
	line info "Tailscale is running" "your devices reach this PC through Tailscale's network; chosen at install" "tailscale status"
fi

if systemctl --user is-active --quiet syncthing 2>/dev/null; then
	line info "Syncthing is running" "it sends the folders you shared to your other devices" "systemctl --user status syncthing"
fi

ENABLED="$(systemctl list-unit-files --state=enabled --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -v '@\.service$' | wc -l)"
TIMERS="$(systemctl list-timers --all --no-legend 2>/dev/null | wc -l)"
line info "$ENABLED service(s) start with the PC, $TIMERS timer(s) run things on a schedule" \
	"this is the full list of what runs without you asking; read it once" \
	"systemctl list-unit-files --state=enabled ; systemctl list-timers"



#    Sandbox


head1 "Sandbox: what each app can touch"

if have flatpak; then
	APPS="$(flatpak list --app --columns=application 2>/dev/null | grep -v '^Application' | sort -u)"
	NAPPS="$(grep -c . <<< "$APPS" || true)"

	if (( NAPPS > 0 )); then
		line ok "$NAPPS app(s) run sandboxed, as Flatpaks" \
			"each is fenced off from the rest of the system, and its data sits in one folder that is removed with it" \
			"flatpak list --app"

			# Ai - Flathub marks an app verified when its own author publishes it
		ASTREAM=/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz
		if [[ -r "$ASTREAM" ]] && have python3; then
			UNVER="$(python3 - "$ASTREAM" $APPS << 'PYEOF' 2>/dev/null
import gzip, re, sys
want = set(sys.argv[2:])
text = gzip.open(sys.argv[1], "rt", errors="replace").read()
bad = []
for comp in text.split("<component")[1:]:
    m = re.search(r"<id>([^<]+)</id>", comp)
    if not m:
        continue
    cid = m.group(1).removesuffix(".desktop")
    if cid in want and 'verification::verified">true' not in comp:
        bad.append(cid)
print(" ".join(sorted(set(bad))))
PYEOF
)"
			if [[ -z "${UNVER// /}" ]]; then
				line ok "Every Flatpak app is published by its own author (verified on Flathub)" "" "the blue tick on each app's page at flathub.org"
			else
				line look "Flatpak app(s) not published by their own author: $UNVER" \
					"someone else packaged them; usually fine, but it is one more party to trust" \
					"each app's page at flathub.org"
			fi
		fi

			# Ai - a sandbox with the whole home folder inside it is a thin one
		WIDE_FS=""
		while IFS= read -r a; do
			[[ -n "$a" ]] || continue
			if flatpak info --show-permissions "$a" 2>/dev/null | grep -E '^filesystems=' | grep -qE '(^|[=;])(host|home)(;|:|$)'; then
				WIDE_FS+="$a "
			fi
		done <<< "$APPS"
		if [[ -z "$WIDE_FS" ]]; then
			line ok "No Flatpak app can read your whole home folder" "" "open Flatseal"
		else
			line look "Flatpak app(s) that can read your whole home folder: $WIDE_FS" \
				"their sandbox does not protect your files; narrow it in Flatseal if the app does not need it" \
				"open Flatseal, pick the app, look at Filesystem"
		fi
	else
		line look "No apps are installed as Flatpaks" "nothing runs sandboxed" "flatpak list --app"
	fi

	for pair in "com.github.tchx84.Flatseal|Flatseal|a window to see and change what each Flatpak app may touch" \
		"io.github.flattool.Warehouse|Warehouse|a window to remove a Flatpak app together with all its data"; do
		IFS='|' read -r wid wname wwhat <<< "$pair"
		if grep -qx "$wid" <<< "$APPS"; then
			line ok "$wname is installed" "$wwhat" "open $wname from the app launcher"
		else
			line look "$wname is not installed" "$wwhat" "flatpak install flathub $wid"
		fi
	done
else
	line look "Flatpak is not installed" "no app runs sandboxed" "pacman -Q flatpak"
fi

NATIVE="$(pacman -Qqe 2>/dev/null | wc -l)"
line info "$NATIVE package(s) are installed the Arch way and run with your full account rights" \
	"this is the system itself plus apps like Steam and the browsers; they can read anything you can, and removing one leaves its settings in your home folder" \
	"pacman -Qe"

line gap "Apps installed the Arch way cannot be sandboxed or fully removed from a window" \
	"only Flatpak apps get both today; prefer the Flatpak when adding an app (configs/flatpaks.conf)" ""



#    Recovery


head1 "Recovery: undoing a mistake"


## System snapshots

if have snapper && (( ROOT_OK )); then
	SNAPS="$(root timeout 20 snapper -c root list 2>/dev/null | grep -cE '^\s*[0-9]+' || true)"
	if (( SNAPS > 0 )); then
		line ok "System snapshots exist ($SNAPS)" "a bad update or change can be rolled back" "sudo snapper -c root list"
	else
		line bad "No system snapshots" "there is nothing to roll back to" "sudo snapper -c root list"
	fi
elif ! have snapper; then
	line bad "The snapshot tool (snapper) is not installed" "" "pacman -Q snapper"
fi

if pacman -Qq snap-pac > /dev/null 2>&1; then
	line ok "A snapshot is taken by itself before and after every update" "" "pacman -Q snap-pac"
else
	line bad "Updates do not take a snapshot first" "" "pacman -Q snap-pac"
fi

if systemctl is-enabled --quiet limine-snapper-sync 2>/dev/null; then
	line ok "Snapshots appear in the boot menu" "an unbootable system is recovered by picking an older one at power on" "systemctl status limine-snapper-sync"
else
	line look "Snapshots do not appear in the boot menu" \
		"if the system will not boot, the way back needs the install USB" \
		"systemctl is-enabled limine-snapper-sync"
fi


## Home snapshots

if have btrbk; then
	if systemctl is-enabled --quiet btrbk.timer 2>/dev/null; then
		line ok "Home snapshots run on a schedule" "" "systemctl list-timers btrbk.timer"
	else
		line look "Home snapshots are set up but not scheduled" "" "systemctl is-enabled btrbk.timer"
	fi
	if (( ROOT_OK )); then
		CONFB="$(root cat /etc/btrbk/btrbk.conf 2>/dev/null || true)"
		if grep -qE '^\s*target\s' <<< "$CONFB"; then
			if mountpoint -q /mnt/backup 2>/dev/null; then
				line ok "Home is also copied to a second disk, and that disk is attached" "a dead home disk does not take your files with it" "sudo btrbk list latest"
			else
				line bad "Home copies go to a second disk, but that disk is not attached now" "no new copies are being made" "findmnt /mnt/backup"
			fi
		else
			line gap "Home snapshots live on the same disk as home; there is no copy on a second disk" \
				"SPEC wants a daily copy to the internal hard drive; if the home disk dies, every snapshot dies with it" \
				"sudo grep target /etc/btrbk/btrbk.conf"
		fi
	fi
else
	line gap "No home snapshots (btrbk is not installed)" "" "pacman -Q btrbk"
fi

line gap "No monthly copy to an unplugged external drive, and no reminder when it is overdue" "SPEC wants both; not built yet" ""
line gap "Backups do not record what they skipped" "SPEC wants each backup to list skipped items by name; not built yet" ""



#    Performance


head1 "Performance: speed and load"


## Boot

if have systemd-analyze; then
	BOOT="$(systemd-analyze time 2>/dev/null | head -n1 | sed 's/^Startup finished in //')"
	if [[ -n "$BOOT" ]]; then
		line info "Startup took: $BOOT" "" "systemd-analyze time"
	else
		line info "Startup time is not known yet, something is still starting" "" "systemd-analyze time"
	fi
		# Ai - device lines are left out, their names are built from disk ids
	SLOW="$(systemd-analyze blame 2>/dev/null | grep -v '\.device$' | head -n 5)"
	if [[ -n "$SLOW" ]]; then
		printf '            slowest five at startup:\n' | tee -a "$OUT"
		while IFS= read -r l; do printf '            %s\n' "$l" | tee -a "$OUT"; done <<< "$SLOW"
		printf '          %scheck systemd-analyze blame%s\n' "$D" "$O"
	fi
fi


## Memory

read -r MT MA < <(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%d %d\n", t/1024, a/1024}' /proc/meminfo)
USED=$(( MT - MA ))
line info "Memory in use: $USED MB of $MT MB" "" "free -m"
printf '            largest five right now:\n' | tee -a "$OUT"
ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 5 | awk '{printf "            %5d MB  %s\n", $1/1024, $2}' | tee -a "$OUT"
printf '          %scheck ps -eo rss,comm --sort=-rss | head%s\n' "$D" "$O"

if swapon --noheadings 2>/dev/null | grep -q zram; then
	line ok "Compressed memory swap (zram) is on" "the PC slows down gently instead of freezing when memory fills" "swapon"
else
	line look "No compressed memory swap" "" "swapon"
fi


## Disk

if findmnt -no OPTIONS / 2>/dev/null | grep -q 'compress'; then
	line ok "Disk compression is on for the system" "saves space at almost no speed cost" "findmnt -no OPTIONS /"
else
	line look "Disk compression is off for the system" "" "findmnt -no OPTIONS /"
fi

while read -r mp pct; do
	n="${pct%\%}"
	if (( n >= 90 )); then
		line bad "$mp is $pct full" "btrfs gets slow and fragile when nearly full" "df -h $mp"
	elif (( n >= 75 )); then
		line look "$mp is $pct full" "" "df -h $mp"
	else
		line ok "$mp is $pct full" "" "df -h $mp"
	fi
done < <(df --output=target,pcent / /home 2>/dev/null | tail -n +2 | sort -u)

if systemctl is-enabled --quiet fstrim.timer 2>/dev/null; then
	line ok "SSD cleanup (trim) runs weekly" "" "systemctl list-timers fstrim.timer"
else
	line look "SSD cleanup (trim) is not scheduled" "SSDs stay fast longer with it" "systemctl is-enabled fstrim.timer"
fi


## Graphics

if (( IN_VM )); then
	line info "Graphics: virtual machine, the real card is not tested here" "" ""
elif lsmod 2>/dev/null | grep -q '^nvidia_drm'; then
	if grep -q 'nvidia_drm.modeset=1' /proc/cmdline; then
		line ok "NVIDIA driver is loaded with the setting Wayland needs" "" "cat /proc/cmdline"
	else
		line bad "NVIDIA driver is loaded without modeset" "Wayland desktops flicker or fail to start" "cat /proc/cmdline"
	fi
else
	line info "Graphics driver: $(lspci -k 2>/dev/null | grep -A3 -E 'VGA|3D' | sed -n 's/.*Kernel driver in use: //p' | sort -u | tr '\n' ' ')" "" "lspci -k"
fi

GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
[[ -n "$GOV" ]] && line info "Processor speed policy: $GOV" "" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"


## Errors

ERRS="$(journalctl -b -p err --no-pager -q 2>/dev/null | wc -l)"
if (( ERRS == 0 )); then
	line ok "No errors logged since startup" "" "journalctl -b -p err"
else
	line look "$ERRS error line(s) logged since startup" "many are harmless; the same one repeating is worth a look" "journalctl -b -p err"
fi



#    Desktops


head1 "Desktops: what you can log in to"

if systemctl is-enabled --quiet sddm 2>/dev/null; then
	line ok "The login screen (SDDM) starts with the PC" "" "systemctl is-enabled sddm"
else
	line bad "No login screen is set to start" "the PC boots to a text prompt" "systemctl is-enabled sddm"
fi

SESS=""
for f in /usr/share/wayland-sessions/*.desktop /usr/share/xsessions/*.desktop; do
	[[ -f "$f" ]] || continue
	SESS+="$(sed -n 's/^Name=//p' "$f" | head -n1), "
done

if [[ -n "$SESS" ]]; then
	line info "Choices on the login screen: ${SESS%, }" "add or remove with the desktop command" "desktop"
else
	line bad "No desktop is installed" "" "ls /usr/share/wayland-sessions"
fi

if have desktop; then
	line ok "The desktop command is installed" "one place to add, remove and list desktops" "desktop"
else
	line look "The desktop command is not installed yet" "" "rebuild --only 26-desktops"
fi

line gap "Your own polished desktop is not built" "the Dream draft exists but is unfinished; add it to look at with: desktop add dream" ""
line gap "The PC does not lock by itself when idle" "SPEC wants it, never during a game or video; not built yet" ""



#    Summary


head1 "Summary"

SUM="$N_OK as wanted   $N_LOOK to look at   $N_BAD wrong   $N_GAP wanted but not built"

printf '  %s%s%s\n\n' "$G" "$SUM" "$O"
printf '  %s\n\n' "$SUM" >> "$OUT"

cp "$OUT" "$REPORT" 2>/dev/null && printf '  Saved to %s\n' "$REPORT"
printf '  Read it before sharing it.\n\n'

	# Ai - for a caller that wants a verdict, wrong things are the exit code
(( N_BAD == 0 ))
