#!/usr/bin/env bash

# Ai - remote: your laptop reaches this PC over Tailscale and nowhere else,
#      a terminal over SSH, the screen over Sunshine, and a wake-up over the
#      network for when the PC is off

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Remote" "Tailscale, SSH and streaming to the laptop"


step "Tailscale"

pac tailscale

	# Ai - Tailscale runs outside the Mullvad tunnel, or its traffic would go
	#      through the VPN and out, and the laptop could not reach the PC
	#      mullvad-exclude is the part of Mullvad made for exactly this
if has mullvad-exclude; then
	TS_EXEC="$(sed -n 's/^ExecStart=//p' /usr/lib/systemd/system/tailscaled.service | head -n 1)"
	[[ -n "$TS_EXEC" ]] || die "tailscaled has no start line to wrap"
	put /etc/systemd/system/tailscaled.service.d/mullvad-exclude.conf << EOF
[Unit]
After=mullvad-daemon.service
Wants=mullvad-daemon.service

[Service]
ExecStart=
ExecStart=$(command -v mullvad-exclude) $TS_EXEC
EOF
	ok "Tailscale runs beside the VPN"
else
	warn "mullvad-exclude is missing, Tailscale will run inside the VPN"
fi
run "reload services" $SUDO systemctl daemon-reload
run "start Tailscale" $SUDO systemctl enable --now tailscaled
if (( DRY == 0 )); then
	wait_for 30 test -S /run/tailscale/tailscaled.sock || warn "Tailscale did not start"
fi

	# Ai - its identity lives on the data disk, so after a reinstall it is the
	#      same device on your tailnet, with the same name
if tailscale status > /dev/null 2>&1; then
	ok "already on your tailnet"
	soft "names stay with Mullvad" $SUDO tailscale set --accept-dns=false --operator="$USER"
else
	todo "Join your tailnet: run  sudo tailscale up --accept-dns=false --operator=$USER --qr
Scan the code with your phone, or open the link, and approve this PC."
fi


step "SSH"

	# Ai - keys only once the laptop's key is here, never root, and reachable
	#      only over the tailnet, the firewall keeps it closed everywhere else
SSHD=(
	"PermitRootLogin no"
	"AllowUsers $USER"
	"X11Forwarding no"
)
if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
	SSHD+=("PasswordAuthentication no" "KbdInteractiveAuthentication no")
	ok "keys only, passwords are refused"
else
	todo "From the laptop, run:  pc copykey
Then here:  rebuild remote   (SSH then refuses passwords)"
fi
printf '%s\n' "${SSHD[@]}" | put /etc/ssh/sshd_config.d/10-nug.conf
run "SSH identity" $SUDO ssh-keygen -A
run "check SSH settings" $SUDO sshd -t
run "SSH on" $SUDO systemctl enable --now sshd

	# Ai - the identity goes onto the data disk, so the laptop still trusts
	#      this PC after a reinstall
quiet $SUDO install -d -m 700 /persist/ssh
quiet $SUDO sh -c 'cp -a /etc/ssh/ssh_host_* /persist/ssh/'
soft "SSH from the tailnet only" $SUDO ufw allow in on tailscale0 to any port 22 proto tcp


step "Wake from the laptop"

	# Ai - the network card listens for a wake-up while the PC is off, the
	#      firmware has to allow it too, that part is yours
	#      names like "Wired connection 1" have spaces, so read line by line
while IFS= read -r c; do
	if [[ -n "$c" ]]; then
		soft "wake on the wired network ($c)" $SUDO nmcli connection modify "$c" 802-3-ethernet.wake-on-lan magic
	fi
done < <(nmcli -t -f NAME,TYPE connection show 2> /dev/null | awk -F: '$2 == "802-3-ethernet" {print $1}')
todo "In the firmware, turn on Wake on LAN (often under Power, or APM)."


step "Streaming"

	# Ai - Sunshine runs only while you ask, remote on and remote off, it is
	#      never listening while you are not streaming
any "Sunshine" sunshine sunshine-bin || die "Sunshine did not install"

	# Ai - it grabs the screen through Hyprland, so the extra kernel right some
	#      builds give it is not needed and is taken away
if has sunshine; then
	SUN="$(readlink -f "$(command -v sunshine)")"
	if getcap "$SUN" 2> /dev/null | grep -q cap_sys_admin; then
		soft "drop a right it does not need" $SUDO setcap -r "$SUN"
	fi
fi

if (( DRY == 0 )); then
	mkdir -p "$HOME/.config/sunshine"
	touch "$HOME/.config/sunshine/sunshine.conf"
	sed -i '/^capture *=/d; /^output_name *=/d' "$HOME/.config/sunshine/sunshine.conf"
	printf 'capture = wlr\noutput_name = SUNSHINE\n' >> "$HOME/.config/sunshine/sunshine.conf"
fi

	# Ai - the laptop's mouse and keyboard arrive through uinput, given to
	#      whoever is logged in at the screen and to nobody else
	#      v1 also put you in the input group, which lets any program read
	#      every keyboard, passwords included, it is left out here
put /etc/udev/rules.d/60-sunshine.rules << 'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
EOF
put /etc/modules-load.d/uinput.conf <<< "uinput"
quiet $SUDO udevadm control --reload-rules || true
quiet $SUDO udevadm trigger || true
if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
	soft "leave the input group" $SUDO gpasswd -d "$USER" input
fi

put /usr/local/bin/remote 755 < "$SCRIPTS/bin/remote"
for u in app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
	if systemctl --user is-enabled --quiet "$u" 2> /dev/null; then
		soft "Sunshine off at login" systemctl --user disable "$u"
	fi
done

soft "stream ports, tailnet only" $SUDO ufw allow in on tailscale0 to any port 47984,47989,47990,48010 proto tcp
soft "stream ports, tailnet only" $SUDO ufw allow in on tailscale0 to any port 47998:48000 proto udp

todo "Pair the laptop: here run  remote on,  open https://localhost:47990 and set a login,
then on the laptop run  pc pair.  Run  remote off  when done."


step "Check"

if systemctl is-active --quiet tailscaled; then ok "Tailscale running"; else warn "Tailscale is not running"; fi
if systemctl is-active --quiet sshd; then ok "SSH on, tailnet only"; else warn "SSH is not running"; fi
if has sunshine; then ok "Sunshine installed, off until  remote on"; else warn "Sunshine is missing"; fi
