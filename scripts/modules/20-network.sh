#!/usr/bin/env bash

# Ai - network: the firewall first, then the VPN, then a check that names
#      still resolve through it, everything after this downloads something

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Network" "VPN, private DNS and the firewall"


step "Firewall"

	# Ai - ufw closes every door coming in, going out is left to Mullvad,
	#      which already drops anything that is not in the tunnel
	#      the tailnet is the only way in, opened by the remote module
pac ufw
run "close incoming" $SUDO ufw default deny incoming
run "allow outgoing" $SUDO ufw default allow outgoing
run "turn it on" $SUDO ufw --force enable
run "on at every start" $SUDO systemctl enable ufw


step "VPN"

	# Ai - its settings live on the data disk, so a reinstall is still logged
	#      in and uses no new device slot
any "Mullvad" mullvad-vpn-bin mullvad-vpn || die "Mullvad did not install, nothing after this should run without it"
run "start Mullvad" $SUDO systemctl enable --now mullvad-daemon
wait_for 60 mullvad status || die "the Mullvad service did not start"

logged_in() { mullvad account get 2> /dev/null | grep -qi 'mullvad account'; }

if logged_in; then
	ok "already logged in"
elif [[ -n "${MULLVAD_NUMBER:-}" ]]; then
	if mullvad account login "$MULLVAD_NUMBER" >&3 2>&1; then
		ok "logged in"
	else
		warn "the account number was not accepted"
		todo "Log in to Mullvad: open the Mullvad app from the tray, or run: mullvad account login"
	fi
else
	todo "Log in to Mullvad: open the Mullvad app from the tray, or run: mullvad account login"
fi
unset MULLVAD_NUMBER

	# Ai - local network on, or the kill switch cuts off the tailnet, VMs and
	#      local services, lockdown mode is yours to turn on in the app
soft "allow the local network" mullvad lan set allow
soft "connect at start" mullvad auto-connect set on

	# Ai - every content blocker Mullvad has, the biggest privacy win in daily
	#      use, with the core three if a flag was renamed upstream
if quiet mullvad dns set default --block-ads --block-trackers --block-malware \
	--block-adult-content --block-gambling --block-social-media; then
	ok "ads, trackers and malware blocked by name"
else
	soft "block ads, trackers and malware" mullvad dns set default --block-ads --block-trackers --block-malware
fi

	# Ai - IPv6 in the tunnel with no IPv6 route makes every name lookup wait
	#      for a timeout, it is only turned on when this network has IPv6
if [[ -n "$(ip -6 route show default 2> /dev/null)" ]]; then
	soft "IPv6 in the tunnel" mullvad tunnel set ipv6 on
else
	soft "IPv6 off, this network has none" mullvad tunnel set ipv6 off
fi

if logged_in; then
	soft "connect" mullvad connect
	wait_for 90 sh -c 'mullvad status | grep -q Connected' || warn "Mullvad did not say Connected within 90 seconds"
fi


step "DNS"

	# Ai - one owner for names: systemd-resolved, NetworkManager and Mullvad
	#      both hand it their servers, Tailscale is told to keep out of it
if [[ "$(readlink /etc/resolv.conf)" != *stub-resolv.conf ]]; then
	quiet $SUDO ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
if (( DRY == 1 )); then
	dim "would check that names resolve through the VPN"
elif wait_for 45 getent ahostsv4 archlinux.org; then
	ok "names resolve through the VPN"
else
	soft "IPv6 off, then reconnect" sh -c 'mullvad tunnel set ipv6 off && mullvad reconnect'
	wait_for 60 getent ahostsv4 archlinux.org || die "names do not resolve, nothing else can download: check mullvad status"
	warn "IPv6 in the tunnel broke name lookups, it is off now"
fi


step "Check"

if $SUDO ufw status | grep -q 'Status: active'; then ok "firewall on"; else warn "the firewall is off"; fi
if systemctl is-active --quiet mullvad-daemon; then ok "Mullvad running"; else warn "Mullvad is not running"; fi
if mullvad status 2> /dev/null | grep -q Connected; then ok "connected through the VPN"; else warn "not connected through the VPN yet"; fi
