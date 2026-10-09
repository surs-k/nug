#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Checker


section "Checker"

	# Ai - the few things on this laptop that can fail without a sound
	#      the one that matters most is the SSD, a bumped cable turns the whole
	#      system read only and nothing says so until a save fails
	#      there are no popups, there is no notification daemon, a problem is
	#      printed at the top of every new terminal instead

$SUDO tee /usr/local/bin/rebuild-health > /dev/null << 'HEALTHEOF'
#!/usr/bin/env bash

set -uo pipefail

	# Ai - deliberately not set -e
	#      a failing check is the point, it must not abort the run

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

BROKEN=()
OK=()

REPORT="$HOME/.rebuild/health.txt"
mkdir -p "$(dirname "$REPORT")"


	# Ai - helpers

pass() { OK+=("$1"); }
fail() { BROKEN+=("$1: $2"); }

capture() { "$@" 2>&1 || true; }

has() { [[ "$1" == *"$2"* ]]; }


	# Ai - the system disk is still writable
	#      btrfs turns itself read only when the SSD drops off the bus

OPTS="$(findmnt -no OPTIONS / 2>/dev/null || true)"

if has ",$OPTS," ",rw,"; then
	pass "System disk"
else
	fail "System disk" "went read-only, was the SSD unplugged? plug it in and reboot"
fi


	# Ai - room left on the system disk

USE="$(capture df --output=pcent /)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 90 )); then
	fail "Root disk" "${USE}% full"
else
	pass "Root disk"
fi


	# Ai - room left for the next kernel

USE="$(capture df --output=pcent /boot)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 85 )); then
	fail "Boot disk" "${USE}% full, the next kernel update will fail"
else
	pass "Boot disk"
fi


	# Ai - the firewall

if systemctl is-active --quiet ufw; then
	pass "Firewall"
else
	fail "Firewall" "ufw is not running, try: sudo systemctl enable --now ufw"
fi


	# Ai - the way to the PC

if ! command -v tailscale > /dev/null; then
	fail "Tailscale" "the command is gone, the package was removed"
else
	S="$(capture tailscale status)"
	if has "$S" "Logged out" || has "$S" "stopped" || [[ -z "${S//[[:space:]]/}" ]]; then
		fail "Tailscale" "down, the laptop cannot reach your PC, try: sudo tailscale up"
	else
		pass "Tailscale"
	fi
fi


	# Ai - anything systemd gave up on

S="$(capture systemctl --failed --no-legend --plain)"
if [[ -n "${S//[[:space:]]/}" ]]; then
	COUNT="$(printf '%s\n' "$S" | grep -c . )"
	fail "Services" "$COUNT failed unit(s), run: systemctl --failed"
else
	pass "Services"
fi


	# Ai - report
	#      the file stays plain text, the colour is added only on the way to a
	#      terminal, this script is its own process and has no colour variables

{
	printf 'Rebuild health  %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
	for o in "${OK[@]}";     do printf '  ok      %s\n' "$o"; done
	for b in "${BROKEN[@]}"; do printf '  BROKEN  %s\n' "$b"; done
} > "$REPORT"

if (( QUIET == 0 )); then
	if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
		sed -e $'s/^  ok      /  \033[32mok\033[0m      /' \
			-e $'s/^  BROKEN  /  \033[31mBROKEN\033[0m  /' "$REPORT"
	else
		cat "$REPORT"
	fi
fi

if (( ${#BROKEN[@]} > 0 )); then
	exit 1
fi

exit 0
HEALTHEOF

$SUDO chmod 755 /usr/local/bin/rebuild-health



#    Schedule


section "Schedule"

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/rebuild-health.service" << 'EOF'
[Unit]
Description=Check the things that fail silently

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rebuild-health --quiet
EOF

cat > "$HOME/.config/systemd/user/rebuild-health.timer" << 'EOF'
[Unit]
Description=Health check every twelve hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF

run "reload user systemd" systemctl --user daemon-reload

run "enable health timer" systemctl --user enable --now rebuild-health.timer



#    Greeting


section "Greeting"

	# Ai - if the last check found something, say so when a terminal opens
	#      with no popups this is the only place it can show

SNIP="$HOME/.config/rebuild-health.sh"

cat > "$SNIP" << 'EOF'
	# Ai - rebuild health greeting
if [[ -f "$HOME/.rebuild/health.txt" ]] && grep -q BROKEN "$HOME/.rebuild/health.txt"; then
	printf '\n  Something needs fixing:\n\n'
	grep BROKEN "$HOME/.rebuild/health.txt" | sed 's/^/  /'
	printf '\n  Full report: rebuild-health\n\n'
fi
EOF

for rc in "$HOME/.bashrc"; do
	[[ -f "$rc" ]] || touch "$rc"
	if grep -q 'rebuild-health.sh' "$rc"; then
		note "greeting already in $(basename "$rc")"
	else
		printf '\n[[ -f "$HOME/.config/rebuild-health.sh" ]] && source "$HOME/.config/rebuild-health.sh"\n' >> "$rc"
		note "greeting added to $(basename "$rc")"
	fi
done



#    Verify


section "Verify"

check "checker installed"  test -x /usr/local/bin/rebuild-health
check "timer enabled"      systemctl --user is-enabled --quiet rebuild-health.timer
check "greeting snippet"   test -f "$SNIP"

verify_done

stage_done



#    End


section "End"

printf '  Health checks installed.\n\n'
printf '  Runs every 12 hours and at boot. A problem is printed at the top\n'
printf '  of every new terminal until it is fixed.\n\n'
printf '  Check any time with:\n\n'
printf '    rebuild-health\n\n'


## First

	# Ai - the first report on a fresh machine
	#      anything it calls broken goes into the summary by name, instead of
	#      one line saying the first run did not succeed
HEALTH_NOW="$(capture /usr/local/bin/rebuild-health)"

printf '%s\n' "$HEALTH_NOW"

while IFS= read -r l; do
	if contains "$l" "BROKEN"; then
		flag "health: ${l#*BROKEN  }"
	fi
done <<< "$HEALTH_NOW"
