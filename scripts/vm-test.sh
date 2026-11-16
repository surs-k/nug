#!/usr/bin/env bash

	# Ai - vm-test: install the whole system into a throwaway virtual machine,
	#      hands off, and bring back the verify report
	#      runs on your PC as you, no root, and touches nothing outside its
	#      own folder, the VM gets two blank virtual disks of its own
	#
	#      vm-test.sh run      install from scratch, run every stage, fetch the report
	#      vm-test.sh again    after a fix: boot the same VM and carry the stages on
	#      vm-test.sh probe F  boot the VM, run script file F inside it, print what it says
	#      vm-test.sh open     start the installed VM in a window to look around
	#      vm-test.sh report   show the last report again
	#      vm-test.sh log      follow what the VM is printing
	#      vm-test.sh shot     save a picture of the VM screen
	#      vm-test.sh stop     switch the VM off
	#      vm-test.sh clean    delete the VM and its disks

set -uo pipefail

SCRIPTS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(dirname "$SCRIPTS")"

DIR="${REBUILD_VM_DIR:-$HOME/.cache/rebuild-vm}"

RAM="${VM_RAM:-6G}"
CPUS="${VM_CPUS:-4}"
DISK="${VM_DISK:-48G}"

	# Ai - how long each half may take before the test gives up, in minutes
ISO_LIMIT="${VM_ISO_LIMIT:-60}"
RUN_LIMIT="${VM_RUN_LIMIT:-300}"

ISO="${VM_ISO:-}"
ANSWERS="${VM_ANSWERS:-$SCRIPTS/vm-answers.conf}"
DESKTOPS=""
KEEP=0
GL=1

CMD="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
	case "$1" in
		--iso)      ISO="${2:-}"; shift 2 ;;
		--desktops) DESKTOPS="${2:-}"; shift 2 ;;
		--keep)     KEEP=1; shift ;;
		--no-gl)    GL=0; shift ;;
		-*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
		*)  PROBE_FILE="$1"; shift ;;
	esac
done

say()  { printf '\n  %s\n' "$*"; }
die()  { printf '\n  %s\n\n' "$*" >&2; exit 1; }


#    Parts

need_tools() {
	local t missing=""
	for t in qemu-system-x86_64 qemu-img swtpm bsdtar python3 tar; do
		command -v "$t" > /dev/null 2>&1 || missing+=" $t"
	done
	[[ -z "$missing" ]] || die "Missing tools:$missing
  On Arch:  sudo pacman -S qemu-full swtpm libarchive python"

	[[ -r /dev/kvm && -w /dev/kvm ]] || die "No access to /dev/kvm, the VM would be far too slow."

	OVMF_CODE=""
	local c
	for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do
		[[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
	done
	[[ -n "$OVMF_CODE" ]] || die "No UEFI firmware found. On Arch:  sudo pacman -S edk2-ovmf"
	OVMF_VARS="${OVMF_CODE/CODE/VARS}"
	[[ -f "$OVMF_VARS" ]] || die "Firmware settings file missing: $OVMF_VARS"
}

find_iso() {
	[[ -n "$ISO" ]] && { [[ -r "$ISO" ]] || die "Cannot read $ISO"; return 0; }
	local f
	for f in "$DIR"/archlinux-*.iso "$HOME"/Downloads/archlinux-*.iso \
		"$HOME"/firelink/vm-storage/iso/archlinux-*.iso /var/lib/libvirt/images/archlinux-*.iso; do
		[[ -r "$f" ]] && { ISO="$f"; return 0; }
	done
	die "No Arch install ISO found.
  Download archlinux-x86_64.iso from https://archlinux.org/download/ and check
  it as that page describes, then:  vm-test.sh run --iso /path/to/archlinux-x86_64.iso"
}

mon() {
	python3 - "$DIR/mon.sock" "$1" << 'PYEOF' 2>/dev/null
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(sys.argv[1])
time.sleep(0.3)
s.sendall((sys.argv[2] + "\n").encode())
time.sleep(0.7)
PYEOF
}

alive() { [[ -f "$DIR/qemu.pid" ]] && kill -0 "$(cat "$DIR/qemu.pid")" 2>/dev/null; }

start_tpm() {
	if [[ -f "$DIR/tpm.pid" ]] && kill -0 "$(cat "$DIR/tpm.pid")" 2>/dev/null; then
		return 0
	fi
	mkdir -p "$DIR/tpm"
	rm -f "$DIR/tpm.sock"
	swtpm socket --tpm2 --tpmstate "dir=$DIR/tpm" \
		--ctrl "type=unixio,path=$DIR/tpm.sock" \
		--daemon --pid "file=$DIR/tpm.pid" || die "The virtual TPM chip did not start."
}

stop_all() {
	if alive; then
		mon system_powerdown
		local i
		for i in $(seq 1 30); do alive || break; sleep 1; done
		alive && kill "$(cat "$DIR/qemu.pid")" 2>/dev/null
	fi
	[[ -f "$DIR/tpm.pid" ]] && kill "$(cat "$DIR/tpm.pid")" 2>/dev/null
	[[ -f "$DIR/http.pid" ]] && kill "$(cat "$DIR/http.pid")" 2>/dev/null
	rm -f "$DIR/qemu.pid" "$DIR/tpm.pid" "$DIR/http.pid" "$DIR/mon.sock"
}

	# Ai - one place builds the machine, so the install boot, the test boot
	#      and the look around boot are the same hardware
qemu_args() {
	local display=$1
	QARGS=(
		-name rebuild-vm-test
		-enable-kvm -machine q35 -cpu host -smp "$CPUS" -m "$RAM"
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
		-drive "if=pflash,format=raw,file=$DIR/vars.fd"
		-drive "file=$DIR/system.qcow2,if=virtio,discard=unmap"
		-drive "file=$DIR/data.qcow2,if=virtio,discard=unmap"
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0
		-chardev "socket,id=chrtpm,path=$DIR/tpm.sock"
		-tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0
		-device virtio-rng-pci
		-monitor "unix:$DIR/mon.sock,server,nowait"
		-pidfile "$DIR/qemu.pid"
	)
	case "$display" in
		none)   QARGS+=(-display none -device virtio-vga) ;;
		window)
			if (( GL )); then
				QARGS+=(-display gtk,gl=on -device virtio-vga-gl)
			else
				QARGS+=(-display gtk -device virtio-vga)
			fi
			QARGS+=(-device qemu-xhci -device usb-tablet -audiodev none,id=a0) ;;
	esac
}

	# Ai - prints new lines of the VM log until a marker shows or time runs out
	#      1 marker seen, 2 the VM stopped first, 3 out of time
follow_until() {
	local log=$1 marker=$2 minutes=$3 early=${4:-}
	local shown=0 total end early_end
	end=$(( $(date +%s) + minutes * 60 ))
	early_end=$(( $(date +%s) + 600 ))
	while true; do
		if [[ -f "$log" ]]; then
			total="$(wc -l < "$log")"
			if (( total > shown )); then
				sed -n "$(( shown + 1 )),${total}p" "$log" | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v '^\s*$' | cut -c1-160
				shown=$total
			fi
			grep -aq "$marker" "$log" && return 0
			if [[ -n "$early" ]] && (( $(date +%s) > early_end )) && ! grep -aq "$early" "$log"; then
				return 4
			fi
		fi
		alive || { sleep 1; grep -aq "$marker" "$log" 2>/dev/null && return 0; return 2; }
		(( $(date +%s) > end )) && return 3
		sleep 3
	done
}


#    Run

cmd_run() {
	need_tools
	find_iso
	[[ -r "$ANSWERS" ]] || die "Answers file missing: $ANSWERS"

	alive && die "A test VM is already running.  vm-test.sh stop"

	say "Test folder: $DIR"
	say "Install ISO: $ISO"

	stop_all
	rm -rf "$DIR/www" "$DIR/tpm" "$DIR"/serial-*.log "$DIR/report.txt" "$DIR/problems.txt"
	mkdir -p "$DIR/www"

		# Ai - blank disks every run, a test that starts from leftovers proves nothing
	rm -f "$DIR/system.qcow2" "$DIR/data.qcow2"
	qemu-img create -q -f qcow2 "$DIR/system.qcow2" "$DISK" || die "Could not make the system disk."
	qemu-img create -q -f qcow2 "$DIR/data.qcow2"   "$DISK" || die "Could not make the data disk."
	cp "$OVMF_VARS" "$DIR/vars.fd"
	chmod u+w "$DIR/vars.fd"

		# Ai - the ISO's own kernel is started directly, so the boot line can
		#      carry script=, which the Arch ISO runs by itself once it is up
	bsdtar -xf "$ISO" -C "$DIR" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img \
		|| die "Could not read the kernel out of the ISO."
	local opts
	opts="$(bsdtar -xOf "$ISO" 'loader/entries/01-archiso*linux.conf' 2>/dev/null | sed -n 's/^options *//p' | head -n1)"
	[[ -n "$opts" ]] || die "Could not read the boot line out of the ISO."

		# Ai - the repo as it is on disk now, uncommitted edits included, so
		#      what is tested is what you are looking at
	tar -C "$REPO" --exclude=.git -cf "$DIR/www/repo.tar" . || die "Could not pack the repo."

	cp "$ANSWERS" "$DIR/www/answers.conf"
	[[ -n "$DESKTOPS" ]] && { sed -i '/^WANT_DESKTOPS=/d' "$DIR/www/answers.conf"; printf 'WANT_DESKTOPS=%q\n' "$DESKTOPS" >> "$DIR/www/answers.conf"; }

	local port
	port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

	cat > "$DIR/www/auto.sh" << AUTOEOF
#!/usr/bin/env bash
exec > /dev/ttyS0 2>&1
printf '\n=== REBUILD VM: install started ===\n'
mkdir -p /root/rebuild
curl -fsS http://10.0.2.2:$port/repo.tar | tar -x -C /root/rebuild
curl -fsS http://10.0.2.2:$port/answers.conf -o /root/.install-config
chmod 600 /root/.install-config
export REBUILD_AUTO=1 TERM=dumb
bash /root/rebuild/scripts/iso.sh
rc=\$?
printf '\n=== REBUILD VM: ISO DONE rc=%s ===\n' "\$rc"
sync
sleep 2
poweroff
AUTOEOF

	( cd "$DIR/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 > "$DIR/http.log" 2>&1 ) &
	echo $! > "$DIR/http.pid"

	start_tpm


	## Install

	say "Part 1 of 2: installing from the ISO onto blank disks (up to $ISO_LIMIT minutes)"

	qemu_args none
	qemu-system-x86_64 "${QARGS[@]}" \
		-cdrom "$ISO" -no-reboot \
		-kernel "$DIR/arch/boot/x86_64/vmlinuz-linux" \
		-initrd "$DIR/arch/boot/x86_64/initramfs-linux.img" \
		-append "$opts script=http://10.0.2.2:$port/auto.sh" \
		-serial "file:$DIR/serial-1.log" -daemonize || die "The VM did not start."

	follow_until "$DIR/serial-1.log" "ISO DONE rc=" "$ISO_LIMIT" "REBUILD VM: install started"
	local rc=$?

	kill "$(cat "$DIR/http.pid")" 2>/dev/null
	rm -f "$DIR/http.pid"

	case "$rc" in
		3) stop_all; die "Part 1 ran out of time. Log: $DIR/serial-1.log" ;;
		4) stop_all; die "The ISO never started the install script. Log: $DIR/serial-1.log" ;;
	esac

	grep -aq "ISO DONE rc=0" "$DIR/serial-1.log" || { stop_all; die "The disk install failed. Log: $DIR/serial-1.log"; }

	local i
	for i in $(seq 1 60); do alive || break; sleep 1; done
	alive && kill "$(cat "$DIR/qemu.pid")" 2>/dev/null
	rm -f "$DIR/qemu.pid"
	[[ -f "$DIR/tpm.pid" ]] && kill "$(cat "$DIR/tpm.pid")" 2>/dev/null
	rm -f "$DIR/tpm.pid"
	sleep 1


	run_stages
}

	# Ai - the repo is served to the VM for the whole of part 2, vm-guest.sh
	#      takes a fresh copy at each boot
serve_repo() {
	mkdir -p "$DIR/www"
	tar -C "$REPO" --exclude=.git -cf "$DIR/www/repo.tar" . || die "Could not pack the repo."
	rm -f "$DIR/www/again"
	[[ "${1:-}" == again ]] && date +%s > "$DIR/www/again"
	( cd "$DIR/www" && exec python3 -m http.server 8377 --bind 127.0.0.1 > "$DIR/http.log" 2>&1 ) &
	echo $! > "$DIR/http.pid"
}

cmd_again() {
	need_tools
	[[ -f "$DIR/system.qcow2" ]] || die "Nothing installed yet. Run: vm-test.sh run"
	alive && die "The test VM is already running.  vm-test.sh stop"
	stop_all
	[[ -f "$DIR/serial-2.log" ]] && mv "$DIR/serial-2.log" "$DIR/serial-2-$(date +%H%M%S).log"
	run_stages again
}

cmd_probe() {
	local file=$1
	need_tools
	[[ -r "$file" ]] || die "Give a script file to run inside the VM."
	[[ -f "$DIR/system.qcow2" ]] || die "Nothing installed yet. Run: vm-test.sh run"
	alive && die "The test VM is already running.  vm-test.sh stop"
	stop_all
	serve_repo
	cp "$file" "$DIR/www/probe.sh"
	start_tpm
	qemu_args none
	rm -f "$DIR/serial-probe.log"
	qemu-system-x86_64 "${QARGS[@]}" -serial "file:$DIR/serial-probe.log" -daemonize || die "The VM did not start."
	follow_until "$DIR/serial-probe.log" "REBUILD VM: PROBE END" 15 > /dev/null
	tr -d '\r' < "$DIR/serial-probe.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
		| awk '/REBUILD VM: PROBE START/ {on=1; next} /REBUILD VM: PROBE END/ {on=0} on'
	rm -f "$DIR/www/probe.sh"
	(( KEEP )) || stop_all
}

run_stages() {
	local rc

	say "Part 2 of 2: starting the installed system and running every stage (up to $RUN_LIMIT minutes)"

	serve_repo "${1:-}"
	start_tpm
	qemu_args none
	qemu-system-x86_64 "${QARGS[@]}" \
		-serial "file:$DIR/serial-2.log" -daemonize || die "The installed VM did not start."

	follow_until "$DIR/serial-2.log" "REBUILD VM: DONE" "$RUN_LIMIT" "REBUILD VM: boot"
	rc=$?

	case "$rc" in
		2) die "The VM switched off before finishing. Log: $DIR/serial-2.log" ;;
		3) die "Part 2 ran out of time, the VM is still running.
  Log: $DIR/serial-2.log     Look inside: vm-test.sh shot" ;;
		4) die "The installed system never reached the test runner (boot or disk unlock failed).
  Look at its screen: vm-test.sh shot" ;;
	esac

	cmd_extract

	if (( KEEP )); then
		say "The VM is still running. Switch it off with: vm-test.sh stop"
	else
		stop_all
	fi

	cmd_report
	say "Look around inside it:  vm-test.sh open     (user and password are in $ANSWERS)"
	printf '\n'
}

cmd_extract() {
	local log="$DIR/serial-2.log"
	[[ -f "$log" ]] || return 1
	tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
		| awk '/REBUILD VM: REPORT START/ {on=1; next} /REBUILD VM: REPORT END/ {on=0} on' > "$DIR/report.txt"
	tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
		| awk '/REBUILD VM: PROBLEMS START/ {on=1; next} /REBUILD VM: PROBLEMS END/ {on=0} on' > "$DIR/problems.txt"
}

cmd_report() {
	[[ -s "$DIR/report.txt" ]] || die "No report yet. Run: vm-test.sh run"
	cat "$DIR/report.txt"
	if [[ -s "$DIR/problems.txt" ]]; then
		printf '\n\nStages that reported a problem\n==============================\n\n'
		cat "$DIR/problems.txt"
	fi
	say "Report file:  $DIR/report.txt"
	grep -a 'REBUILD VM: DONE' "$DIR/serial-2.log" 2>/dev/null | tail -n1 | tr -d '\r' | sed 's/^/  /'
}


#    Open

cmd_open() {
	need_tools
	[[ -f "$DIR/system.qcow2" ]] || die "Nothing installed yet. Run: vm-test.sh run"
	alive && die "The test VM is already running.  vm-test.sh stop"
	stop_all
		# Ai - the VM takes a fresh copy of the repo as it starts
	serve_repo
	start_tpm
	qemu_args window
	say "Opening the VM in a window. Close the window or run vm-test.sh stop to end."
	say "If the screen stays black, try: vm-test.sh open --no-gl"
	qemu-system-x86_64 "${QARGS[@]}" -serial "file:$DIR/serial-open.log" -daemonize || die "The VM did not start."
}

cmd_shot() {
	alive || die "The VM is not running."
	local out
	out="$DIR/screen-$(date +%H%M%S).ppm"
	mon "screendump $out"
	sleep 1
	[[ -s "$out" ]] || die "No picture came back."
	if command -v magick > /dev/null 2>&1; then
		magick "$out" "${out%.ppm}.png" && rm -f "$out" && out="${out%.ppm}.png"
	fi
	say "Saved $out"
}

cmd_log() {
	local f
	f="$(ls -t "$DIR"/serial-*.log 2>/dev/null | head -n1)"
	[[ -n "$f" ]] || die "No log yet."
	tail -n 40 -f "$f"
}

cmd_clean() {
	stop_all
	rm -rf "$DIR"
	say "Deleted $DIR"
}

case "$CMD" in
	run)     cmd_run ;;
	again)   cmd_again ;;
	probe)   cmd_probe "${PROBE_FILE:-}" ;;
	open)    cmd_open ;;
	report)  cmd_extract; cmd_report ;;
	shot)    cmd_shot ;;
	log)     cmd_log ;;
	stop)    stop_all; say "VM off." ;;
	clean)   cmd_clean ;;
	*)
		sed -n '3,17p' "$0" | sed 's/^\t# Ai - /  /; s/^\t#      /  /; s/^\t#$//'
		printf '\n  Options for run:  --desktops plasma,gnome   --iso FILE   --keep\n\n' ;;
esac
