#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 50-bkp-net

if [[ "${WANT_SUNSHINE:-yes}" != yes ]]; then
	note "remote access turned off in $CONFIG"
	stage_done
	exit 0
fi



#    Sunshine


section "Sunshine"


## Install

aur sunshine-bin


## Capture

####### wayland capture goes through kms and needs this capability
####### without it sunshine starts, connects, and streams a black screen
SUN_BIN="$(readlink -f "$(command -v sunshine)")"

run "grant kms capture" $SUDO setcap cap_sys_admin+p "$SUN_BIN"


## Input

####### the virtual keyboard and mouse are a uinput device
$SUDO tee /etc/udev/rules.d/60-sunshine.rules > /dev/null << 'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
EOF

run "reload udev rules" $SUDO udevadm control --reload-rules
run "trigger udev"      $SUDO udevadm trigger
soft "load uinput"      $SUDO modprobe uinput

run "add user to input" $SUDO usermod -aG input "$USERNAME"



#    Headless


section "Headless"

####### a virtual monitor so the laptop gets its own resolution instead of
####### mirroring the ultrawide
####### it has to exist before sunshine starts, because sunshine reads the
####### output name once at startup and caches it, so an on demand headless
####### makes it capture the wrong screen

$SUDO tee /usr/local/bin/rebuild-headless > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

####### create the virtual output only if one is not already there
MONS="$(hyprctl monitors all 2>&1 || true)"

case "$MONS" in
	*HEADLESS*) exit 0 ;;
esac

hyprctl output create headless
EOF

$SUDO chmod 755 /usr/local/bin/rebuild-headless

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/rebuild-headless.service" << 'EOF'
[Unit]
Description=Create a headless Hyprland output for Sunshine
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/sleep 3
ExecStart=/usr/local/bin/rebuild-headless

[Install]
WantedBy=graphical-session.target
EOF

run "reload user systemd" systemctl --user daemon-reload

soft "enable headless output" systemctl --user enable rebuild-headless.service



#    Service


section "Service"

####### the package does not always ship a user unit called sunshine.service,
####### which is why enabling it failed outright
####### whatever it ships gets used, and if it ships nothing we write one

UNITS="$(capture systemctl --user list-unit-files --no-legend)"

if contains "$UNITS" "sunshine.service"; then
	note "using the unit shipped with the package"

elif [[ -f /usr/lib/systemd/user/sunshine.service ]]; then
	note "found a unit in /usr/lib/systemd/user"
	run "reload user systemd" systemctl --user daemon-reload

else
	flag "package shipped no user unit, writing one"

	mkdir -p "$HOME/.config/systemd/user"

	cat > "$HOME/.config/systemd/user/sunshine.service" << EOF
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

soft "enable sunshine" systemctl --user enable sunshine.service

soft "start sunshine"  systemctl --user start sunshine.service



#    Firewall


section "Firewall"

####### only on the tailnet, never on the open lan
####### sunshine speaks on 47984 47989 48010 tcp and 47998 to 48000 udp
####### 47990 is the web interface

if ip link show tailscale0 &> /dev/null; then
	soft "stream tcp"  $SUDO ufw allow in on tailscale0 to any port 47984,47989,48010 proto tcp
	soft "stream udp"  $SUDO ufw allow in on tailscale0 to any port 47998:48000 proto udp
	soft "web ui"      $SUDO ufw allow in on tailscale0 to any port 47990 proto tcp
else
	flag "tailscale0 absent, sunshine ports not opened"
fi



#    Verify


section "Verify"

check "sunshine present"  command -v sunshine
check "unit exists"       test -f "$HOME/.config/systemd/user/sunshine.service" -o -f /usr/lib/systemd/user/sunshine.service
check "kms capability"    sh -c "getcap '$SUN_BIN' > /tmp/_cap; grep -q cap_sys_admin /tmp/_cap"
check "uinput rule"       test -f /etc/udev/rules.d/60-sunshine.rules
check "user in input"     sh -c "id -nG $USERNAME > /tmp/_ig; grep -qw input /tmp/_ig"
check "headless helper"   test -x /usr/local/bin/rebuild-headless

warn  "sunshine running"  systemctl --user is-active --quiet sunshine
warn  "headless unit"     systemctl --user is-enabled --quiet rebuild-headless
warn  "tailnet rules"     sh -c 'sudo ufw status > /tmp/_uf; grep -q 47984 /tmp/_uf'

verify_done

stage_done



#    End


section "End"

printf '  Sunshine installed.\n\n'
printf '  Finish setup in a browser on this PC:\n'
printf '    https://localhost:47990\n\n'
printf '  Set a username and password there, then pair the laptop.\n'
printf '  On the laptop install moonlight-qt and connect to this\n'
printf '  machines tailscale address.\n\n'
printf '  Check tailscale status shows a direct connection, not relay.\n'
printf '  A relayed link adds latency you will feel.\n\n'
