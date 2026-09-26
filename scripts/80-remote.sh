#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 20-security

if [[ "${WANT_SUNSHINE:-yes}" != yes ]]; then
	note "remote access turned off in $CONFIG"
	stage_done
	exit 0
fi



#    Sunshine


section "Sunshine"


## Install

	# Ai - sunshine-bin is LizardByte's own prebuilt release, already built with
	#      CUDA, so NVENC works here without the CUDA toolkit being installed
	#      sunshine builds that same release from source, which is what stopped
	#      the v7.0 run on the PC, so it is the fallback rather than the default
SUN_PKG=""

for pkg in sunshine-bin sunshine; do
	if installed "$pkg"; then
		SUN_PKG="$pkg"
		note "$pkg already installed"
		break
	fi

	if aur "$pkg"; then
		SUN_PKG="$pkg"
		break
	fi

	info "$pkg would not install, trying the next name"
done

if [[ -z "$SUN_PKG" ]]; then
	flag "no sunshine package would install, nothing else in this stage can run"
	printf '\n  Sunshine did not install. The log has the build output:\n' >&2
	printf '    %s\n\n' "$LOG" >&2
	exit 1
fi


## Capture

	# Ai - sunshine captures the virtual screen made below, through wlr
	#      kms cannot see it, kms only knows real connectors, and with nothing
	#      set sunshine asked the desktop portal instead, which is the screen
	#      picker that popped up over whatever window was open at login
	#      wlr needs no extra privilege, so the cap_sys_admin kms needed is
	#      removed from the binary rather than left on for nothing
SUN_BIN="$(readlink -f "$(command -v sunshine)")"

SUN_CAPS="$(getcap "$SUN_BIN" 2>/dev/null || true)"

if contains "$SUN_CAPS" "cap_sys_admin"; then
	soft "drop unused kms capability" $SUDO setcap -r "$SUN_BIN"
fi

SUN_CONF="$HOME/.config/sunshine/sunshine.conf"
mkdir -p "$(dirname "$SUN_CONF")"
touch "$SUN_CONF"

	# Ai - only these two lines are managed, anything set in the web page stays
sed -i '/^capture *=/d; /^output_name *=/d' "$SUN_CONF"
printf 'capture = wlr\noutput_name = SUNSHINE\n' >> "$SUN_CONF"


## Input

	# Ai - the virtual keyboard and mouse are a uinput device
$SUDO tee /etc/udev/rules.d/60-sunshine.rules > /dev/null << 'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
EOF

run "reload udev rules" $SUDO udevadm control --reload-rules
run "trigger udev"      $SUDO udevadm trigger
soft "load uinput"      $SUDO modprobe uinput

run "add user to input" $SUDO usermod -aG input "$USERNAME"



#    Headless


section "Headless"

	# Ai - the virtual screen gives the laptop its own resolution instead of
	#      mirroring the ultrawide, and it only exists while Sunshine runs
	#      remote on makes it and starts Sunshine, remote off undoes both
$SUDO install -m 755 "$SCRIPTS/remote.sh" /usr/local/bin/remote

	# Ai - earlier versions made the screen at every login, so that goes
if [[ -f "$HOME/.config/systemd/user/rebuild-headless.service" ]]; then
	systemctl --user disable rebuild-headless.service 2>/dev/null || true
	rm -f "$HOME/.config/systemd/user/rebuild-headless.service"
	note "virtual screen no longer made at login"
fi

$SUDO rm -f /usr/local/bin/rebuild-headless

run "reload user systemd" systemctl --user daemon-reload



#    Service


section "Service"

	# Ai - the package does not always ship a user unit called sunshine.service,
	#      which is why enabling it failed outright
	#      whatever it ships gets used, and if it ships nothing we write one

	# Ai - upstream renamed the user unit for XDG portal compatibility
	#      plain sunshine.service is now an alias that does not always resolve
SUN_UNIT="app-dev.lizardbyte.app.Sunshine.service"

UNITS="$(capture systemctl --user list-unit-files --no-legend)"

if contains "$UNITS" "app-dev.lizardbyte.app.Sunshine"; then
	note "using the current upstream unit name"

elif contains "$UNITS" "sunshine.service"; then
	SUN_UNIT="sunshine.service"
	note "using the older unit name shipped with this build"

else
	SUN_UNIT="sunshine.service"
	flag "package shipped no user unit, writing one"

	mkdir -p "$HOME/.config/systemd/user"

	cat > "$HOME/.config/systemd/user/$SUN_UNIT" << EOF
[Unit]
Description=Sunshine game stream host
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$(command -v sunshine)
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF

	run "reload user systemd" systemctl --user daemon-reload
fi

	# Ai - never at login, only when you ask: remote on
	#      an install made before v7.4 enabled it, so both names are turned off
for u in "$SUN_UNIT" app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
	if systemctl --user is-enabled --quiet "$u" 2>/dev/null; then
		soft "sunshine off at login" systemctl --user disable --now "$u"
	fi
done



#    Firewall


section "Firewall"

	# Ai - only on the tailnet, never on the open lan
	#      sunshine speaks on 47984 47989 48010 tcp and 47998 to 48000 udp
	#      47990 is the web interface

if ip link show tailscale0 &> /dev/null; then
	soft "stream tcp"  $SUDO ufw allow in on tailscale0 to any port 47984,47989,48010 proto tcp
	soft "stream udp"  $SUDO ufw allow in on tailscale0 to any port 47998:48000 proto udp
	soft "web ui"      $SUDO ufw allow in on tailscale0 to any port 47990 proto tcp
else
		# Ai - one line for one situation, this used to print four
	note "no tailnet yet, so the stream ports stay closed"
	note "when you want remote access: rebuild --only 35-tailnet"
	note "then: rebuild --only 80-remote"
fi



#    Verify


section "Verify"

check "sunshine present"  command -v sunshine
check "unit exists"       sh -c 'systemctl --user list-unit-files > /tmp/_su; grep -qi sunshine /tmp/_su' 
check "capture pinned"    grep -q '^capture = wlr' "$SUN_CONF"
check "uinput rule"       test -f /etc/udev/rules.d/60-sunshine.rules
check "user in input"     sh -c "id -nG $USERNAME > /tmp/_ig; grep -qw input /tmp/_ig"
check "remote command"    test -x /usr/local/bin/remote

sun_off_at_login() {
	! systemctl --user is-enabled --quiet "$SUN_UNIT" 2>/dev/null
}

check "off at login"       sun_off_at_login

	# Ai - only when there is a tailnet, the ports stay shut on purpose otherwise
if ip link show tailscale0 &> /dev/null; then
	warn  "tailnet rules"   sh -c 'sudo ufw status > /tmp/_uf; grep -q 47984 /tmp/_uf'
fi

verify_done

stage_done



#    End


section "End"

printf '  Sunshine installed. It does not start with the PC.\n\n'
printf '  Start it before you stream, stop it after:\n\n'
printf '    remote on\n'
printf '    remote off\n\n'
printf '  First time only, with it on, finish setup here:\n\n'
printf '    https://localhost:47990\n\n'
printf '  Set a username and password, then pair the laptop in Moonlight.\n\n'
