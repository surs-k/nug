#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


# = =    Check     = = = = = = = =

set -Eeuo pipefail

retry ping -c1 archlinux.org



# = =    Timezone     = = = = = =


sudo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

sudo hwclock --systohc



# = =    Locale     = = = = = = =


sudo sed -i "s/^#\($LOCALE\)/\1/" /etc/locale.gen

sudo locale-gen

locale -a | grep -q "en_US.utf8" || { echo "Locale not generated" >&2; exit 1; }

echo "LANG=$LOCALE" | sudo tee /etc/locale.conf

echo "KEYMAP=$KEYMAP" | sudo tee /etc/vconsole.conf



# = =    Hostname     = = = = = 

sudo hostnamectl set-hostname "$HOSTNAME"

grep -q "$HOSTNAME" /etc/hosts || sudo tee -a /etc/hosts > /dev/null << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF


	

# = =    TPM2     = = = = = = = =


echo Encryption Pass

sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "/dev/disk/by-partlabel/cryptsystem"




# = =    zram     = = = = = = = =


sudo tee /etc/systemd/zram-generator.conf > /dev/null << EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF



# = =    yay     = = = = = = = = =


if ! command -v yay >/dev/null; then
	  sudo pacman -S --needed --noconfirm git base-devel
	  git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
	  (cd /tmp/yay-bin && makepkg -si --noconfirm)
fi

	# yay -S limine-mkinitcpio-hook
	# ^ commented out



	# possible fixes
	
		# yay -S limine-mkinitcpio-hook-git

	# or

		# yay -S jdk21-graalvm-bin
	
		# yay -S limine-mkinitcpio-hook


	# if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null; then
	    # echo "limine-mkinitcpio-hook didn't install"
	    # exit 1
	# fi

		# exits because of commented install



# = =    End     = = = = = = = = = 


stage_done 10-base

echo "Run desktop.sh"