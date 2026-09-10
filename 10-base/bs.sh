#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


section "Check"

sudo_keepalive

retry online

[[ "$HOSTNAME" != CHANGEME ]] || { printf 'No hostname in %s\n' "$CONFIG" >&2; exit 1; }
[[ "$USERNAME" != CHANGEME ]] || { printf 'No username in %s\n' "$CONFIG" >&2; exit 1; }



#    Pacman


section "Pacman"


## Display

####### colour and parallel downloads make the install bars readable
$SUDO sed -i 's/^#Color$/Color/'                          /etc/pacman.conf
$SUDO sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

grep -q '^Color'            /etc/pacman.conf || printf 'Color\n'            | $SUDO tee -a /etc/pacman.conf > /dev/null
grep -q '^ParallelDownloads' /etc/pacman.conf || printf 'ParallelDownloads = 5\n' | $SUDO tee -a /etc/pacman.conf > /dev/null


## Sync

pac archlinux-keyring

run "full system upgrade" $SUDO pacman -Syu --noconfirm



#    Locale


section "Locale"

$SUDO sed -i "s/^#\($LOCALE\)/\1/" /etc/locale.gen

run "generate locale" $SUDO locale-gen

####### capture then match, a pipeline into grep -q can take SIGPIPE
LOCALES="$(capture locale -a)"

contains "$LOCALES" "en_US.utf8" || { printf 'Locale not generated\n' >&2; exit 1; }

printf 'LANG=%s\n'   "$LOCALE" | $SUDO tee /etc/locale.conf   > /dev/null
printf 'KEYMAP=%s\n' "$KEYMAP" | $SUDO tee /etc/vconsole.conf > /dev/null



#    Time


section "Time"

run "set timezone" $SUDO ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

run "sync hardware clock" $SUDO hwclock --systohc

run "enable ntp" $SUDO timedatectl set-ntp true



#    Boot


section "Boot"

####### this is the fix for the menu that sat there waiting for a keypress
####### limine reads the directory holding its own efi binary before /boot,
####### so a stray limine.conf beside the binary silently wins
####### and limine-snapper-sync rewrites /boot/limine.conf on every snapshot,
####### so the global settings are re-asserted by a hook instead of by hand


## Stray

for c in /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf /boot/limine/limine.conf; do
	if [[ -f "$c" ]]; then
		$SUDO mv "$c" "$c.disabled"
		flag "moved $c aside, it outranked /boot/limine.conf"
	fi
done


## Enforcer

$SUDO tee /usr/local/bin/limine-header-fix > /dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail

CONF=/boot/limine.conf

[[ -f "\$CONF" ]] || exit 0

TMP="\$(mktemp)"

####### strip any existing global settings, then put ours back on top
####### global directives must appear before the first entry
grep -Ev '^(timeout|default_entry|quiet|verbose):' "\$CONF" > "\$TMP" || true

{
	printf 'timeout: %s\n' "$LIMINE_TIMEOUT"
	printf 'default_entry: 1\n'
	printf 'quiet: yes\n'
	cat "\$TMP"
} > "\$CONF"

rm -f "\$TMP"
EOF

$SUDO chmod 755 /usr/local/bin/limine-header-fix


## Apply

run "set boot to auto start" $SUDO /usr/local/bin/limine-header-fix



#    Swap


section "Swap"

$SUDO tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

run "reload systemd" $SUDO systemctl daemon-reload



#    Unlock


section "Unlock"

####### tpm2 auto unlock is convenience, not protection
####### pcr 7 measures the secure boot state, so with secure boot off it
####### proves very little, and a firmware update can invalidate it
####### the passphrase slot always stays, so a broken pcr is never a lockout

SB="$(capture bootctl status)"

if contains "$SB" "Secure Boot: enabled"; then
	note "Secure Boot is on, PCR 7 is meaningful"
	TPM_OK=yes
else
	flag "Secure Boot is off, PCR 7 binding is convenience only"
	TPM_OK=ask
fi

ENROLLED="$(capture $SUDO cryptsetup luksDump /dev/disk/by-partlabel/cryptsystem)"

if contains "$ENROLLED" "systemd-tpm2"; then
	note "TPM2 already enrolled"

elif [[ ! -e /dev/tpmrm0 ]]; then
	flag "no TPM device found, skipping"

elif [[ "$TPM_OK" == yes ]] || yesno "Enrol the TPM anyway so you skip the boot passphrase" y; then
	note "You will be asked for your LUKS passphrase once."
	$SUDO systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
		/dev/disk/by-partlabel/cryptsystem \
		|| flag "TPM enrolment failed, the passphrase still works"
fi



#    Yay


section "Yay"

if command -v yay > /dev/null; then
	note "yay already installed"
else
	pac git base-devel
	run "clone yay-bin"  git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
	run "build yay-bin"  bash -c 'cd /tmp/yay-bin && makepkg -si --noconfirm'
fi



#    Verify


section "Verify"

check "hostname set"     sh -c "test \"\$(hostnamectl --static)\" = \"$HOSTNAME\""
check "locale built"     sh -c 'locale -a > /tmp/_loc; grep -q en_US.utf8 /tmp/_loc'
check "zram config"      test -f /etc/systemd/zram-generator.conf
check "limine conf"      test -f /boot/limine.conf
check "no stray conf"    sh -c '! test -f /boot/EFI/limine/limine.conf'
check "auto start set"   grep -q '^timeout:' /boot/limine.conf
check "deploy hook"      test -f /etc/pacman.d/hooks/99-limine-deploy.hook
check "header enforcer"  test -x /usr/local/bin/limine-header-fix
check "yay present"      command -v yay

warn  "tpm2 enrolled"    sh -c 'sudo cryptsetup luksDump /dev/disk/by-partlabel/cryptsystem > /tmp/_lk; grep -q systemd-tpm2 /tmp/_lk'

verify_done

stage_done



#    End


section "End"

printf '  Base system configured.\n\n'
