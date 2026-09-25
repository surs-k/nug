#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base

pac libnotify



#    Checker


section "Checker"

	# Ai - everything on this machine that can fail without telling you
	#      freetube showing an error is not a notification, it is a symptom
	#      this turns silence into a popup you cannot miss

$SUDO tee /usr/local/bin/rebuild-health > /dev/null << 'HEALTHEOF'
#!/usr/bin/env bash

set -uo pipefail

	# Ai - deliberately not set -e
	#      a failing check is the point, it must not abort the run

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

BROKEN=()
IDLE=()
NOTES=()
OK=()

REPORT="$HOME/.rebuild/health.txt"
mkdir -p "$(dirname "$REPORT")"


	# Ai - helpers

pass() { OK+=("$1"); }
fail() { BROKEN+=("$1: $2"); }

	# Ai - worth knowing, nothing to fix here, never a popup
aside() { NOTES+=("$1: $2"); }

	# Ai - a check that needs root asks through the sudo rules 90-health writes
	#      when a rule is missing, sudo says a password is required, and that
	#      is reported once, instead of as two unrelated sounding problems
	#      the answer comes back in ROOT_OUT, not on stdout, because a $( )
	#      is a subshell and a flag set in there never reaches this script
NO_RULE=0
ROOT_OUT=""

asroot() {
	local rc=0
	ROOT_OUT="$(sudo -n "$@" 2>&1)" || rc=$?
	if (( rc != 0 )) && has "$ROOT_OUT" "password is required"; then
		NO_RULE=1
		ROOT_OUT=""
		return 1
	fi
	return "$rc"
}

	# Ai - a service you stopped on purpose is not a fault
off()  { IDLE+=("$1: $2"); }

	# Ai - every container that is running right now
RUNNING=""
asroot docker ps --format '{{.Names}}' && RUNNING="$ROOT_OUT"

is_up() { [[ $'\n'"$RUNNING"$'\n' == *$'\n'"$1"$'\n'* ]]; }

capture() { "$@" 2>&1 || true; }

has() { [[ "$1" == *"$2"* ]]; }

	# Ai - the answers from the install, read, never sourced
answer() { sed -n "s/^$1=//p" "$HOME/.install-config" 2>/dev/null | tail -n 1; }

WANT_TS="$(answer WANT_TAILSCALE)"
WANT_ST="$(answer WANT_STACKS)"


	# Ai - vpn
	#      a missing command is a failure, not a pass, these are all things
	#      the install put there and their absence means something ate them

if ! command -v mullvad > /dev/null; then
	fail "Mullvad" "the command is gone, the package was removed"
else
	S="$(capture mullvad status)"
	if has "$S" "Connected"; then pass "Mullvad"
	else fail "Mullvad" "not connected, you are browsing exposed"; fi
fi


	# Ai - tailnet
	#      only a failure when it was chosen, Tailscale is off unless asked for

if ! command -v tailscale > /dev/null && [[ "$WANT_TS" != yes ]]; then
	:
elif ! command -v tailscale > /dev/null; then
	fail "Tailscale" "the command is gone, the package was removed"
else
	S="$(capture tailscale status)"
	if has "$S" "Logged out" || has "$S" "stopped" || [[ -z "${S//[[:space:]]/}" ]]; then
		fail "Tailscale" "down, the laptop cannot reach this machine"
	else
		pass "Tailscale"
	fi
fi


	# Ai - containers stuck restarting
	#      you are not in the docker group, so this asks through one sudo rule
	#      that allows exactly this listing and nothing else
	#      it used to ask as you, got permission denied, and called that text a
	#      container stuck in a restart loop

if command -v docker > /dev/null; then
	if asroot docker ps -a --filter status=restarting --format '{{.Names}}'; then
		S="$ROOT_OUT"
		if [[ -n "${S//[[:space:]]/}" ]]; then
			fail "Containers" "stuck in a restart loop: ${S//$'\n'/ }"
		else
			pass "Containers"
		fi
	elif (( ! NO_RULE )); then
		fail "Containers" "Docker did not answer: ${ROOT_OUT:-no output}"
	fi
fi


	# Ai - invidious, the one that youtube actively breaks
	#      two questions, is it running at all, and can it still reach YouTube
	#      the stats page answers without YouTube, the video needs it
	#      the video is the first one ever uploaded, it is not going anywhere

if (( NO_RULE )); then
	:

elif ! is_up invidious; then
	has "$WANT_ST" "invidious" && off "Invidious" "stopped, start it with: stack up invidious"

elif has "$WANT_ST" "invidious" || has "$WANT_ST" "all"; then
	CODE="$(capture curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
		http://127.0.0.1:3000/api/v1/stats)"
	if [[ "$CODE" != 200 ]]; then
		fail "Invidious" "not answering, try: sudo docker restart invidious"
	else
		CODE="$(capture curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
			http://127.0.0.1:3000/api/v1/videos/jNQXAC9IVRw)"
		if [[ "$CODE" == 200 ]]; then
			pass "Invidious"
		else
				# Ai - YouTube blocks VPN addresses, which is not a fault on this PC
			aside "Invidious" "YouTube is refusing this VPN address, mullvad reconnect may help"
		fi
	fi
fi


	# Ai - searxng

if (( NO_RULE )); then
	:

elif ! is_up searxng; then
	has "$WANT_ST" "searxng" && off "SearXNG" "stopped, start it with: stack up searxng"

elif has "$WANT_ST" "searxng" || has "$WANT_ST" "all"; then
	CODE="$(capture curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:8080/)"
	if [[ "$CODE" == 200 ]]; then pass "SearXNG"
	else fail "SearXNG" "not answering, try: sudo docker restart searxng"; fi
fi


	# Ai - backups actually ran

if [[ -f /var/log/btrbk.log ]]; then
	AGE=$(( ( $(date +%s) - $(stat -c %Y /var/log/btrbk.log) ) / 86400 ))
	if (( AGE <= 2 )); then pass "Backups"
	else fail "Backups" "btrbk has not run in $AGE days"; fi
else
	fail "Backups" "btrbk has never run"
fi


	# Ai - snapshots exist

	# Ai - the output has to contain an actual snapshot number, an error
	#      message is also non empty and would otherwise read as success

if ! command -v snapper > /dev/null; then
	fail "Snapshots" "snapper is gone"
else
	if asroot snapper -c root list --columns number; then
		N="$ROOT_OUT"
		if [[ "$N" =~ [0-9] ]]; then pass "Snapshots"
		else fail "Snapshots" "no root snapshots found"; fi
	elif (( ! NO_RULE )); then
		fail "Snapshots" "snapper did not answer: ${ROOT_OUT:-no output}"
	fi
fi


	# Ai - the esp fills up with a kernel per snapshot entry

USE="$(capture df --output=pcent /boot)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 85 )); then
	fail "Boot disk" "${USE}% full, snapshot boot entries will stop being made"
else
	pass "Boot disk"
fi


	# Ai - root disk

USE="$(capture df --output=pcent /)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 90 )); then
	fail "Root disk" "${USE}% full"
else
	pass "Root disk"
fi


	# Ai - boot menu still starts on its own
	#      the same check the install used, first failing reason is reported

if [[ ! -x /usr/local/bin/limine-header-fix ]]; then
	fail "Boot menu" "limine-header-fix is gone, rerun: rebuild --only 10-base"
elif S="$(/usr/local/bin/limine-header-fix --check 2>&1)"; then
	pass "Boot menu"
else
	R=""
	while IFS= read -r L; do
		if has "$L" "FAIL"; then
			R="${L#*FAIL}"
			R="${R#"${R%%[![:space:]]*}"}"
			break
		fi
	done <<< "$S"
	fail "Boot menu" "${R:-would not start on its own}, see Guides/Bootmenu.md"
fi


	# Ai - anything systemd gave up on

S="$(capture systemctl --failed --no-legend --plain)"
if [[ -n "${S//[[:space:]]/}" ]]; then
	COUNT="$(printf '%s\n' "$S" | grep -c . )"
	fail "Services" "$COUNT failed unit(s), run: systemctl --failed"
else
	pass "Services"
fi


	# Ai - one problem, not two, when the root checks could not ask at all

if (( NO_RULE )); then
	fail "Health check" "cannot ask as root, its sudo rule is missing, rerun: rebuild --only 90-health"
fi


	# Ai - report
	#      least serious first, so the lines that need you sit at the bottom

{
	printf 'Rebuild health  %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
	for o in "${OK[@]}";     do printf '  ok      %s\n' "$o"; done
	for i in "${IDLE[@]}";   do printf '  off     %s\n' "$i"; done
	for n in "${NOTES[@]}";  do printf '  note    %s\n' "$n"; done
	for b in "${BROKEN[@]}"; do printf '  BROKEN  %s\n' "$b"; done
} > "$REPORT"

if (( QUIET == 0 )); then
	cat "$REPORT"
fi


	# Ai - shout

if (( ${#BROKEN[@]} > 0 )); then

		# Ai - one popup per problem, never several stacked into one wall of
		#      text, and never more than three at once
	if command -v notify-send > /dev/null; then
		SHOWN=0
		for b in "${BROKEN[@]}"; do
			(( SHOWN >= 3 )) && break
				# Ai - -t 0 means it stays until dismissed
			notify-send -u critical -t 0 "${b%%:*} needs fixing" "${b#*: }" 2>/dev/null || true
			SHOWN=$(( SHOWN + 1 ))
		done

		if (( ${#BROKEN[@]} > SHOWN )); then
			notify-send -u critical -t 0 "More to fix" \
				"$(( ${#BROKEN[@]} - SHOWN )) more, run rebuild-health" 2>/dev/null || true
		fi
	fi

		# Ai - also on every new terminal, in case the popup was missed
	exit 1
fi

exit 0
HEALTHEOF

$SUDO chmod 755 /usr/local/bin/rebuild-health



#    Sudoers


section "Sudoers"

	# Ai - ahead of the timer on purpose: enabling the timer can run the check
	#      at once, and before these rules exist every root check fails, which
	#      is where no root snapshots found and could not ask Docker came from

	# Ai - two read only listings without a password, nothing else is granted
	#      snapper for the snapshot check, docker for the restart loop check
	#      the file is proven with visudo before it is put in place, a broken
	#      file in sudoers.d stops sudo working for everything

SUDO_TMP="$(mktemp)"

cat > "$SUDO_TMP" << EOF
$USERNAME ALL=(root) NOPASSWD: /usr/bin/snapper -c root list --columns number
$USERNAME ALL=(root) NOPASSWD: /usr/bin/docker ps -a --filter status\=restarting --format {{.Names}}
$USERNAME ALL=(root) NOPASSWD: /usr/bin/docker ps --format {{.Names}}
EOF

run "validate sudoers" $SUDO visudo -c -f "$SUDO_TMP"

$SUDO install -m 440 -o root -g root "$SUDO_TMP" /etc/sudoers.d/20-rebuild-health

rm -f "$SUDO_TMP"



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
Description=Daily health check

[Timer]
OnBootSec=10min
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
	#      a popup can be missed, a login cannot

SNIP="$HOME/.config/rebuild-health.sh"

cat > "$SNIP" << 'EOF'
	# Ai - rebuild health greeting
if [[ -f "$HOME/.rebuild/health.txt" ]] && grep -q BROKEN "$HOME/.rebuild/health.txt"; then
	printf '\n  Something needs fixing:\n\n'
	grep BROKEN "$HOME/.rebuild/health.txt" | sed 's/^/  /'
	printf '\n  Full report: rebuild-health\n\n'
fi
EOF

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
	[[ -f "$rc" ]] || continue
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
check "sudoers valid"      $SUDO visudo -c -f /etc/sudoers.d/20-rebuild-health
check "notify-send"        command -v notify-send

verify_done

stage_done



#    End


section "End"

printf '  Health checks installed.\n\n'
printf '  Runs every 12 hours and at boot.\n'
printf '  A popup appears when something breaks, and every new\n'
printf '  terminal repeats it until it is fixed.\n\n'
printf '  Lockdown mode is left off. Turn it on in the Mullvad app\n'
printf '  once your settings are done.\n\n'
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
	elif contains "$l" "  note    "; then
		aside "health: ${l#*note    }"
	fi
done <<< "$HEALTH_NOW"
