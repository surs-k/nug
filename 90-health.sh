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

####### everything on this machine that can fail without telling you
####### freetube showing an error is not a notification, it is a symptom
####### this turns silence into a popup you cannot miss

$SUDO tee /usr/local/bin/rebuild-health > /dev/null << 'HEALTHEOF'
#!/usr/bin/env bash

set -uo pipefail

####### deliberately not set -e
####### a failing check is the point, it must not abort the run

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

BROKEN=()
OK=()

REPORT="$HOME/.rebuild/health.txt"
mkdir -p "$(dirname "$REPORT")"


####### helpers

pass() { OK+=("$1"); }
fail() { BROKEN+=("$1: $2"); }

capture() { "$@" 2>&1 || true; }

has() { [[ "$1" == *"$2"* ]]; }


####### vpn
####### a missing command is a failure, not a pass, these are all things
####### the install put there and their absence means something ate them

if ! command -v mullvad > /dev/null; then
	fail "Mullvad" "the command is gone, the package was removed"
else
	S="$(capture mullvad status)"
	if has "$S" "Connected"; then pass "Mullvad"
	else fail "Mullvad" "not connected, you are browsing exposed"; fi
fi


####### tailnet

if ! command -v tailscale > /dev/null; then
	fail "Tailscale" "the command is gone, the package was removed"
else
	S="$(capture tailscale status)"
	if has "$S" "Logged out" || has "$S" "stopped" || [[ -z "${S//[[:space:]]/}" ]]; then
		fail "Tailscale" "down, the laptop cannot reach this machine"
	else
		pass "Tailscale"
	fi
fi


####### containers stuck restarting

if command -v docker > /dev/null; then
	S="$(capture docker ps -a --filter status=restarting --format '{{.Names}}')"
	if [[ -n "${S//[[:space:]]/}" ]]; then
		fail "Containers" "stuck in a restart loop: ${S//$'\n'/ }"
	else
		pass "Containers"
	fi
fi


####### invidious, the one that youtube actively breaks

if command -v docker > /dev/null; then
	S="$(capture docker ps --format '{{.Names}}')"
	if has "$S" "invidious"; then
		CODE="$(capture curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
			http://127.0.0.1:3000/api/v1/trending)"
		if [[ "$CODE" == 200 ]]; then
			pass "Invidious"
		else
			fail "Invidious" "API returned $CODE, YouTube has probably broken it again"
		fi
	fi
fi


####### searxng

if command -v docker > /dev/null; then
	S="$(capture docker ps --format '{{.Names}}')"
	if has "$S" "searxng"; then
		CODE="$(capture curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:8080/)"
		if [[ "$CODE" == 200 ]]; then pass "SearXNG"
		else fail "SearXNG" "returned $CODE"; fi
	fi
fi


####### backups actually ran

if [[ -f /var/log/btrbk.log ]]; then
	AGE=$(( ( $(date +%s) - $(stat -c %Y /var/log/btrbk.log) ) / 86400 ))
	if (( AGE <= 2 )); then pass "Backups"
	else fail "Backups" "btrbk has not run in $AGE days"; fi
else
	fail "Backups" "btrbk has never run"
fi


####### snapshots exist

####### the output has to contain an actual snapshot number, an error
####### message is also non empty and would otherwise read as success

if ! command -v snapper > /dev/null; then
	fail "Snapshots" "snapper is gone"
else
	N="$(capture sudo -n snapper -c root list --columns number)"
	if [[ "$N" =~ [0-9] ]]; then pass "Snapshots"
	else fail "Snapshots" "no root snapshots found"; fi
fi


####### the esp fills up with a kernel per snapshot entry

USE="$(capture df --output=pcent /boot)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 85 )); then
	fail "Boot disk" "${USE}% full, snapshot boot entries will stop being made"
else
	pass "Boot disk"
fi


####### root disk

USE="$(capture df --output=pcent /)"
USE="${USE//[^0-9]/}"
if [[ -n "$USE" ]] && (( USE > 90 )); then
	fail "Root disk" "${USE}% full"
else
	pass "Root disk"
fi


####### boot menu still auto starts

if [[ -f /boot/limine.conf ]]; then
	if grep -q '^timeout:' /boot/limine.conf; then pass "Boot menu"
	else fail "Boot menu" "auto start setting was wiped, it will wait for a keypress"; fi
fi


####### anything systemd gave up on

S="$(capture systemctl --failed --no-legend --plain)"
if [[ -n "${S//[[:space:]]/}" ]]; then
	COUNT="$(printf '%s\n' "$S" | grep -c . )"
	fail "Services" "$COUNT failed unit(s), run: systemctl --failed"
else
	pass "Services"
fi


####### report

{
	printf 'Rebuild health  %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
	for o in "${OK[@]}";     do printf '  ok      %s\n' "$o"; done
	for b in "${BROKEN[@]}"; do printf '  BROKEN  %s\n' "$b"; done
} > "$REPORT"

if (( QUIET == 0 )); then
	cat "$REPORT"
fi


####### shout

if (( ${#BROKEN[@]} > 0 )); then

	BODY="$(printf '%s\n' "${BROKEN[@]}")"

	if command -v notify-send > /dev/null; then
		####### -t 0 means it stays until dismissed
		notify-send -u critical -t 0 \
			"Something on this PC needs fixing" \
			"$BODY

Run rebuild-health for detail." 2>/dev/null || true
	fi

	####### also on every new terminal, in case the popup was missed
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

####### if the last check found something, say so when a terminal opens
####### a popup can be missed, a login cannot

SNIP="$HOME/.config/rebuild-health.sh"

cat > "$SNIP" << 'EOF'
####### rebuild health greeting
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



#    Sudoers


section "Sudoers"

####### the snapshot check needs one read only command without a password
####### nothing else is granted

$SUDO tee /etc/sudoers.d/20-rebuild-health > /dev/null << EOF
$USERNAME ALL=(root) NOPASSWD: /usr/bin/snapper -c root list --columns number
EOF

$SUDO chmod 440 /etc/sudoers.d/20-rebuild-health

run "validate sudoers" $SUDO visudo -c -f /etc/sudoers.d/20-rebuild-health



#    Lockdown


section "Lockdown"

####### this goes absolutely last
####### lockdown blocks everything outside the tunnel, and it was previously
####### switched on in 50-bkp-net, before the package installs that came after
####### it, which is what killed that stage part way through
####### nothing after this point needs to download anything

TS="$(capture tailscale status)"

if contains "$TS" "Logged out" || contains "$TS" "stopped"; then
	flag "Tailscale is down, leaving lockdown mode off so you keep remote access"

elif yesno "Turn on lockdown mode, nothing leaves outside the VPN" y; then
	soft "lockdown mode on" $SUDO mullvad lockdown-mode set on
	note "lockdown mode is on"
	note "if anything loses network later, this is the first thing to check"
	note "to undo: sudo mullvad lockdown-mode set off"
else
	note "lockdown mode left off"
fi



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
printf '  Check any time with:\n\n'
printf '    rebuild-health\n\n'

soft "first run" /usr/local/bin/rebuild-health
