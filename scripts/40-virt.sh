#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 30-security

CPU="$(capture cat /proc/cpuinfo)"

if ! contains "$CPU" "vmx" && ! contains "$CPU" "svm"; then
	printf 'No hardware virtualisation found in /proc/cpuinfo\n' >&2
	exit 1
fi



#    Libvirt


section "Libvirt"


## Install

####### ebtables is no longer needed, libvirt uses its own private nftables
####### table and does not go through the system filter table at all
pac qemu-full virt-manager libvirt dnsmasq iptables-nft edk2-ovmf swtpm


## Backend

$SUDO mkdir -p /etc/libvirt

if grep -q '^firewall_backend' /etc/libvirt/network.conf 2>/dev/null; then
	note "firewall backend already pinned"
else
	$SUDO cp /etc/libvirt/network.conf /etc/libvirt/network.conf.bak-rebuild 2>/dev/null || true
	printf 'firewall_backend = "nftables"\n' | $SUDO tee -a /etc/libvirt/network.conf > /dev/null
	note "pinned libvirt to the nftables backend"
fi


## Service

run "enable libvirtd" $SUDO systemctl enable --now libvirtd

wait_for 20 $SUDO virsh version


## Groups

run "add user to groups" $SUDO usermod -aG libvirt,kvm "$USERNAME"


## Ordering

$SUDO mkdir -p /etc/systemd/system/libvirtd.service.d

$SUDO tee /etc/systemd/system/libvirtd.service.d/after-ufw.conf > /dev/null << 'EOF'
[Unit]
After=ufw.service
EOF

run "reload systemd" $SUDO systemctl daemon-reload



#    Network


section "Network"


## Subnet

HAVE="$(capture ip -br -4 addr show virbr0)"

if [[ "$HAVE" =~ 192\.168\.([0-9]+)\.1/ ]]; then
	SUBNET="192.168.${BASH_REMATCH[1]}"
	REBUILD_NET=no
	note "virbr0 already on $SUBNET.0/24"
else
	REBUILD_NET=yes

	####### this only needs stopping if it is actually running
	####### on a fresh install it never is, and reporting that as a failure
	####### was pure noise in the list
	RUNNING="$(capture $SUDO virsh net-list --name)"

	if contains "$RUNNING" "default"; then
		soft "stop default net" $SUDO virsh net-destroy default
	else
		note "default network is not running, nothing to stop"
	fi

	INUSE="$(capture ip -4 route show)$(capture ip -4 addr show)"

	for n in 122 133 144 155; do
		contains "$INUSE" "192.168.$n." || { SUBNET="192.168.$n"; break; }
	done

	[[ -n "${SUBNET:-}" ]] || { printf 'No free subnet\n' >&2; exit 1; }
	note "virbr0 will use $SUBNET.0/24"
fi


## Define

####### the element is <name>, not <n>
####### libvirt silently refuses to define a network without a real name tag,
####### which is why the default network kept coming back missing
####### the mtu tag is the fix for guests that connect but hang on anything
####### large, mullvad wireguard runs about 1420 and a 1500 byte guest packet
####### is dropped with no error anywhere

if [[ "$REBUILD_NET" == yes ]]; then

	cat > /tmp/virbr0.xml << EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mtu size='$TUNNEL_MTU'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$SUBNET.2' end='$SUBNET.254'/>
    </dhcp>
  </ip>
</network>
EOF

	soft "undefine old net"  $SUDO virsh net-undefine default
	run  "define default"    $SUDO virsh net-define /tmp/virbr0.xml
	run  "start default"     $SUDO virsh net-start default
fi

run "autostart default" $SUDO virsh net-autostart default


## Firewall

if ip link show virbr0 &> /dev/null; then

	####### guests reach the host dnsmasq for dhcp and dns
	soft "allow guest dhcp" $SUDO ufw allow in on virbr0 to any port 67 proto udp
	soft "allow guest dns"  $SUDO ufw allow in on virbr0 to any port 53

	####### guests must not reach the rest of the lan
	soft "block lan 10"     $SUDO ufw route deny in on virbr0 to 10.0.0.0/8
	soft "block lan 172"    $SUDO ufw route deny in on virbr0 to 172.16.0.0/12
	soft "block lan 192"    $SUDO ufw route deny in on virbr0 to 192.168.0.0/16

	soft "allow guest out"  $SUDO ufw route allow in on virbr0
else
	flag "virbr0 absent, firewall rules skipped"
fi



#    Verify


section "Verify"

check "kvm device"       test -c /dev/kvm
check "user in libvirt"  sh -c "id -nG $USERNAME > /tmp/_grp; grep -qw libvirt /tmp/_grp"
check "default defined"  sh -c 'sudo virsh net-list --all --name > /tmp/_net; grep -qx default /tmp/_net'
check "default running"  sh -c 'sudo virsh net-list --name > /tmp/_run; grep -qx default /tmp/_run'
check "virbr0 gateway"   sh -c "ip -br addr show virbr0 > /tmp/_br; grep -q $SUBNET.1 /tmp/_br"
check "virbr0 mtu"       sh -c "ip -br link show virbr0 > /tmp/_mtu; grep -q 'mtu $TUNNEL_MTU' /tmp/_mtu || ip link show virbr0 | grep -q 'mtu $TUNNEL_MTU'"

warn  "libvirt nft table" sh -c 'sudo nft list table ip libvirt_network'

verify_done

stage_done



#    End


section "End"

printf '  Virtualisation ready.\n'
printf '  The libvirt and kvm groups apply at your next login.\n'
printf '  Nothing later in the run needs them, so there is no reboot here.\n\n'
