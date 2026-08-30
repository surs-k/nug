#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# Check 


set -Eeuo pipefail

require_stage 30-security


#    Virtualization


if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    echo "No hardware virtualization (vmx/svm) found in /proc/cpuinfo - aborting." >&2
    exit 1
fi

sudo pacman -S --needed --noconfirm qemu-full virt-manager libvirt dnsmasq ebtables iptables-nft edk2-ovmf

sudo systemctl enable --now libvirtd

sudo usermod -aG libvirt,kvm "$USERNAME"

sudo mkdir -p /etc/systemd/system/libvirtd.service.d
sudo tee /etc/systemd/system/libvirtd.service.d/after-ufw.conf > /dev/null << EOF
[Unit]
After=ufw.service
EOF

sudo systemctl daemon-reload

if ! sudo virsh net-info default &>/dev/null; then
	sudo virsh net-define /usr/share/libvirt/networks/default.xml
fi

sudo virsh net-autostart default

sudo virsh net-info default | grep -q 'Active:.*yes' || sudo virsh net-start default

if ip link show virbr0 &>/dev/null; then
	NIC=$(ip route show default | awk '{print $5}' | head -1)
	[[ -n "$NIC" ]] || { echo "No default route found" >&2; exit 1; }

	sudo ufw route deny in on virbr0 to 10.0.0.0/8
	
	sudo ufw route deny in on virbr0 to 172.16.0.0/12
	
	sudo ufw route deny in on virbr0 to 192.168.0.0/16
	
	sudo ufw route allow in on virbr0 out on "$NIC"
fi

sudo ufw reload

sudo ufw status numbered

sudo iptables -L FORWARD -n | head -1


# Verify

echo "VERIFY"
echo


check "forward drop"  sh -c 'iptables -L FORWARD -n | head -1 | grep -q DROP'


check "libvirtd active"   systemctl is-active --quiet libvirtd

check "default net up"    sudo virsh net-info default

check "user in libvirt"       sh -c "id -nG $USERNAME | grep -qw libvirt"

check "kvm device"        test -c /dev/kvm


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