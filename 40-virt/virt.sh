#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


set -Eeuo pipefail

require_stage 30-security



#    Libvirt


## Support

if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    echo "No hardware virtualization (vmx/svm) found in /proc/cpuinfo - aborting." >&2
    exit 1
fi


## Install

sudo pacman -S --needed --noconfirm qemu-full virt-manager libvirt dnsmasq ebtables iptables-nft edk2-ovmf swtpm

sudo systemctl enable --now libvirtd


## Ready

wait_for 20 sudo virsh version


## Groups

sudo usermod -aG libvirt,kvm "$USERNAME"


## Ordering

sudo mkdir -p /etc/systemd/system/libvirtd.service.d
sudo tee /etc/systemd/system/libvirtd.service.d/after-ufw.conf > /dev/null << EOF
[Unit]
After=ufw.service
EOF

sudo systemctl daemon-reload



#    Network


## ## Subnet

inuse="$(ip -4 route show; ip -4 addr show)"

for n in 122 133 144 155; do
	[[ "$inuse" == *"192.168.$n."* ]] || { SUBNET="192.168.$n"; break; }
done

[[ -n "${SUBNET:-}" ]] || { echo "No free subnet" >&2; exit 1; }

echo "virbr0 subnet: $SUBNET.0/24"


## Define

cat > /tmp/virbr0.xml << EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='$SUBNET.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$SUBNET.2' end='$SUBNET.254'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-destroy default 2>/dev/null || true
sudo virsh net-define /tmp/virbr0.xml
sudo virsh net-autostart default
sudo virsh net-start default

state="$(sudo virsh net-info default)" || true
grep -q 'Active:.*yes' <<<"$state" || sudo virsh net-start default


## Firewall

if ip link show virbr0 &>/dev/null; then

	# Guest DHCP reaches host dnsmasq
	sudo ufw allow in on virbr0 to any port 67 proto udp

	# Guest DNS reaches host dnsmasq
	sudo ufw allow in on virbr0 to any port 53

	sudo ufw route deny in on virbr0 to 10.0.0.0/8

	sudo ufw route deny in on virbr0 to 172.16.0.0/12

	sudo ufw route deny in on virbr0 to 192.168.0.0/16

	# Interface agnostic, survives reconnects
	sudo ufw route allow in on virbr0
fi


## Show

sudo ufw status numbered

sudo nft list tables

ip -br addr show virbr0

sysctl net.ipv4.ip_forward

mullvad lan get || true



#    Verify


echo "VERIFY"
echo


check "kvm device"        test -c /dev/kvm

check "user in libvirt"   sh -c "id -nG $USERNAME | grep -qw libvirt"

check "default net up"    sh -c 'sudo virsh net-list --name | grep -qx default'

check "virbr0 gateway"    sh -c "ip -br addr show virbr0 | grep -q $SUBNET.1"


check "libvirt nft rules" sh -c 'sudo nft list table ip libvirt_network'


verify_done



#    End


stage_done 40-virt

echo
echo "Reboot to enable VM groups"
echo
echo "REBOOT"
echo
echo "Run backup-net.sh after"
echo
