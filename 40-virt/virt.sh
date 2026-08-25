#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# = =    Check     = = = = = = = 


set -Eeuo pipefail

require_stage 30-security


# = =    Virtualization     = = = =


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

sudo virsh net-autostart default

sudo virsh net-info default | grep -q 'Active:.*yes' \
	    || sudo virsh net-start default


sudo ufw allow in on virbr0

sudo ufw allow out on virbr0

echo "Virtualization ready. Open virt-manager to create your first VM."



# = =    End     = = = = = = = = = 

stage_done 40-virt

echo "Run backup-net.sh"
