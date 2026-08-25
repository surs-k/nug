#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# = =    Check     = = = = = = = 

set -Eeuo pipefail

require_stage 40-virt



# = =    Tailscale     = = = = = =


sudo pacman -Syu --needed tailscale systemd

sudo systemctl enable --now sshd

sudo systemctl enable --now systemd-resolved.service

sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo systemctl enable --now tailscaled.service

sudo tailscale up --accept-dns=false

sudo systemctl restart NetworkManager.service 2>/dev/null || true

sudo systemctl restart systemd-resolved.service

sudo ufw allow in on tailscale0 to any port 22

if getent hosts archlinux.org >/dev/null; then
    echo "DNS is working."
else
    echo "DNS test failed." >&2
    exit 1
fi

read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1


# = =    Snapper     = = = = = =


if sudo btrfs subvolume show /.snapshots &>/dev/null; then
	sudo btrfs subvolume delete /.snapshots
fi

sudo snapper -c root create-config /

sudo rm -rf /.snapshots

sudo btrfs subvolume create /.snapshots

sudo chmod 750 /.snapshots

ROOTFS_UUID=$(sudo blkid -s UUID -o value /dev/mapper/cryptsystem)

grep -q '/.snapshots' /etc/fstab \
	    || echo "UUID=$ROOTFS_UUID /.snapshots btrfs subvol=@/.snapshots,compress=zstd:1,noatime 0 0" | sudo tee -a /etc/fstab
	    
sudo mount -a

sudo systemctl enable snapper-timeline.timer

sudo systemctl enable snapper-cleanup.timer



# = =    Snap-boot     = = = = =

	# yay -S --noconfirm limine-snapper-sync

if ! pacman -Qi limine-snapper-sync &>/dev/null; then
    echo "limine-snapper-sync didn't install - stopping before HOOKS edit"
    exit 1
fi

sudo mkinitcpio -P

sudo systemctl enable limine-snapper-sync.service




# = =    btrbk     = = = = = = = = 


sudo pacman -S --noconfirm btrbk

sudo mkdir -p /etc/btrbk

if [[ ! -f /etc/btrbk/btrbk.conf ]]; then
    sudo tee /etc/btrbk/btrbk.conf > /dev/null << 'BTRBK_CONF_TEMPLATE'
####### fill in your internal HDD's actual mount point before relying on this
####### snapshot_create   onchange
####### volume /
#######   subvolume @home
#######   target send-receive /path/to/hdd/mount
BTRBK_CONF_TEMPLATE
fi


# = =    End     = = = = = = = = = 


stage_done 50-backup-net
