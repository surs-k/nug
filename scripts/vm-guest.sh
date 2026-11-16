#!/usr/bin/env bash

	# Ai - runs inside the test VM, started at every boot by the service
	#      iso.sh writes in hands off mode
	#      it carries the stages on until they are all done, then runs the
	#      verify report and prints it between markers, which is how vm-test.sh
	#      on the host knows the run is over and gets the report out
	#      it never runs on a real PC, the library refuses hands off mode there

set -uo pipefail

HERE="$(dirname "$(readlink -f "$0")")"

say() { printf '\n=== REBUILD VM: %s ===\n' "$*"; }

systemd-detect-virt --quiet --vm || { say "not a virtual machine, stopping"; exit 1; }

say "boot $(date '+%H:%M'), carrying on"


#    Network

	# Ai - the service starts as early as it can, the network may be a moment behind
for _ in $(seq 1 60); do
	ping -4 -c1 -W2 1.1.1.1 > /dev/null 2>&1 && break
	sleep 2
done


#    Again

	# Ai - vm-test.sh serves the repo from the host while the VM runs
	#      a fresh copy is taken at every boot, so a fix made on the host is
	#      tested by vm-test.sh again, without reinstalling from the ISO
HOST=http://10.0.2.2:8377
DONE=/var/lib/rebuild-vm-test.done

if [[ -z "${VM_GUEST_FRESH:-}" ]] && curl -fsS --max-time 20 "$HOST/repo.tar" -o /tmp/repo.tar 2>/dev/null; then
	tar -xf /tmp/repo.tar -C "$HOME/rebuild" && say "took a fresh copy of the repo from the host"
	rm -f /tmp/repo.tar
		# Ai - again carries a stamp, a new stamp clears the finished mark once,
		#      and the restarts inside that run see the same stamp and leave it
	TOK="$(curl -fsS --max-time 5 "$HOST/again" 2>/dev/null || true)"
	if [[ -n "$TOK" && "$TOK" != "$(cat "$HOME/.rebuild/vm-again" 2>/dev/null)" ]]; then
		sudo -n rm -f "$DONE"
		mkdir -p "$HOME/.rebuild"
		printf '%s' "$TOK" > "$HOME/.rebuild/vm-again"
	fi
	VM_GUEST_FRESH=1 exec bash "$HERE/vm-guest.sh"
fi

	# Ai - the installed desktop command follows the fresh copy, so a change
	#      to it can be tried in the open VM without a reinstall
if [[ -n "${VM_GUEST_FRESH:-}" && -x /usr/local/bin/desktop ]]; then
	sudo -n install -m755 "$HOME/rebuild/scripts/desktop.sh" /usr/local/bin/desktop
fi

	# Ai - vm-test.sh probe: the host may offer one script of questions to
	#      run in here, its answers go back over the same log
	#      this is how a problem inside the VM is looked at without a login
if curl -fsS --max-time 5 "$HOST/probe.sh" -o /tmp/probe.sh 2>/dev/null; then
	say "PROBE START"
	bash /tmp/probe.sh 2>&1
	say "PROBE END"
	rm -f /tmp/probe.sh
	exit 0
fi

if [[ -f "$DONE" ]]; then
	say "already finished, nothing to do"
	exit 0
fi


#    Session

	# Ai - a service has no login session, so no /run/user folder and no user
	#      services, and HyDE's installer and several stages need both
	#      lingering starts them for this user without anyone logged in
sudo -n loginctl enable-linger "$USER"

export XDG_RUNTIME_DIR="/run/user/$(id -u)"

for _ in $(seq 1 30); do
	[[ -S "$XDG_RUNTIME_DIR/bus" ]] && break
	sleep 1
done

export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"


#    Stages

export REBUILD_AUTO=1

	# Ai - run.sh restarts the VM itself where a stage needs it, and this
	#      script simply starts again on the next boot
bash "$HERE/run.sh"
RC=$?

	# Ai - 75 is run.sh saying it asked for a restart, the next boot carries on
if (( RC == 75 )); then
	say "restarting to carry on"
	sleep 600
	exit 0
fi

say "stages ended with exit $RC"

bash "$HERE/run.sh" --list


#    Report

say "REPORT START"

REPORT="$HOME/rebuild-report.txt" bash "$HERE/verify.sh" --plain
VRC=$?

say "REPORT END"

if [[ -s "$HOME/.rebuild/logs/failures.txt" ]]; then
	say "PROBLEMS START"
	cat "$HOME/.rebuild/logs/failures.txt"
	say "PROBLEMS END"
fi

sudo -n touch "$DONE"

say "DONE stages=$RC verify=$VRC"
