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



#    Host


section "Host"

####### this stage runs on the real booted system, where hostnamectl works
####### properly, so it is also the place that can repair a bad hostname

CURRENT="$(capture hostnamectl --static)"

if [[ "$CURRENT" == "$HOSTNAME" ]]; then
	note "hostname already $HOSTNAME"
else
	run "set hostname" $SUDO hostnamectl --static set-hostname "$HOSTNAME"

	printf '%s\n' "$HOSTNAME" | $SUDO tee /etc/hostname > /dev/null

	$SUDO tee /etc/hosts > /dev/null << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

	note "hostname set to $HOSTNAME"
fi



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

TIMEOUT="\${LIMINE_TIMEOUT:-$LIMINE_TIMEOUT}"

####### refuse to touch anything without a real cmdline to write back
CMDLINE="\$(cat /etc/kernel/cmdline 2>/dev/null || true)"

if [[ -z "\$CMDLINE" ]]; then
	printf 'no /etc/kernel/cmdline, refusing to rewrite limine.conf\n' >&2
	exit 1
fi

MID="\$(cat /etc/machine-id 2>/dev/null || true)"

TMP="\$(mktemp)"

####### keep everything from the SECOND top level entry onward
####### a top level entry starts with one slash, a sub entry with two
####### this is what preserves snapshot entries while the main one is rebuilt
awk '/^\/[^\/]/ { n++ } n >= 2' "\$CONF" > "\$TMP" || true

{
	printf 'timeout: %s\n\n' "\$TIMEOUT"

	####### top level and directly bootable
	####### /+Name with a plus is a folder, and limine will not auto boot a
	####### folder, it sits waiting for someone to open it and choose
	printf '/Arch Linux\n'

	if [[ -n "\$MID" ]]; then
		printf '    comment: machine-id=%s\n' "\$MID"
	fi

	printf '    protocol: linux\n'
	printf '    path: boot():/vmlinuz-linux\n'

	if [[ -f /boot/intel-ucode.img ]]; then
		printf '    module_path: boot():/intel-ucode.img\n'
	fi

	if [[ -f /boot/amd-ucode.img ]]; then
		printf '    module_path: boot():/amd-ucode.img\n'
	fi

	printf '    module_path: boot():/initramfs-linux.img\n'
	printf '    cmdline: %s\n\n' "\$CMDLINE"

	cat "\$TMP"
} > "\$CONF"

rm -f "\$TMP"
EOF

$SUDO chmod 755 /usr/local/bin/limine-header-fix


## Apply

####### this also repairs an existing install, it flattens a /+Arch Linux
####### folder into a bootable top level entry and keeps snapshot entries
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

####### enrolment already happened during the install, where the passphrase
####### was in hand, so this only reports the outcome and never prompts

SB="$(capture bootctl status)"

if contains "$SB" "Secure Boot: enabled"; then
	note "Secure Boot is on, PCR 7 is meaningful"
else
	note "Secure Boot is off, TPM unlock is convenience only"
fi

ENROLLED="$(capture $SUDO cryptsetup luksDump /dev/disk/by-partlabel/cryptsystem)"

if contains "$ENROLLED" "systemd-tpm2"; then
	note "TPM unlock is active, no boot passphrase needed"
elif [[ ! -e /dev/tpmrm0 ]]; then
	flag "no TPM device on this machine, the passphrase is required at boot"
else
	flag "TPM is not enrolled, the passphrase is required at boot"
	flag "to enrol it later: sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/cryptsystem"
fi



#    Update


section "Update"

####### one command that refreshes the repo without ever hitting the
####### "local changes would be overwritten" wall
####### it throws away local edits on purpose, the repo is the source of truth

$SUDO tee /usr/local/bin/rebuild-update > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Rebuild"

cd "$REPO"

####### the executable bit counts as a change to git, so ignore modes
git config core.fileMode false

git fetch origin

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

####### discard local edits and match the remote exactly
git reset --hard "origin/$BRANCH"

find . -name '*.sh' -exec chmod +x {} +

printf '
Updated to %s
' "$(git rev-parse --short HEAD)"
printf 'Now run: ./run.sh

'
EOF

$SUDO chmod 755 /usr/local/bin/rebuild-update

if [[ -d "$HOME/Rebuild/.git" ]]; then
	soft "let git ignore file modes" git -C "$HOME/Rebuild" config core.fileMode false
fi



#    Yay


section "Yay"

if command -v yay > /dev/null; then
	note "yay already installed"
else
	pac git base-devel

	rm -rf /tmp/yay-bin

	run "clone yay-bin" git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin

	####### makepkg calls sudo itself to install what it built
	####### run() puts the command in the background where it has no terminal,
	####### so sudo cannot reuse the unlocked session and prompts instead, and
	####### that prompt lands in the middle of the spinner line
	####### package work is visible anyway, so this stays in the foreground
	printf '\n  building yay-bin, this takes a minute\n\n'

	( cd /tmp/yay-bin && makepkg -si --noconfirm )
fi



#    Verify


section "Verify"

check "hostname set"     sh -c "test \"\$(hostnamectl --static)\" = \"$HOSTNAME\""
check "locale built"     sh -c 'locale -a > /tmp/_loc; grep -q en_US.utf8 /tmp/_loc'
check "zram config"      test -f /etc/systemd/zram-generator.conf
check "limine conf"      test -f /boot/limine.conf
check "no stray conf"    sh -c '! test -f /boot/EFI/limine/limine.conf'
check "auto start set"   grep -q '^timeout:' /boot/limine.conf
check "entry top level"  grep -q '^/Arch Linux' /boot/limine.conf
check "entry not folder" sh -c '! grep -q "^/+" /boot/limine.conf'
check "entry bootable"   grep -q 'protocol: linux' /boot/limine.conf
check "deploy hook"      test -f /etc/pacman.d/hooks/99-limine-deploy.hook
check "header enforcer"  test -x /usr/local/bin/limine-header-fix
check "yay present"      command -v yay
check "update helper"    test -x /usr/local/bin/rebuild-update

warn  "tpm2 enrolled"    sh -c 'sudo cryptsetup luksDump /dev/disk/by-partlabel/cryptsystem > /tmp/_lk; grep -q systemd-tpm2 /tmp/_lk'

verify_done

stage_done



#    End


section "End"

printf '  Base system configured.\n\n'
