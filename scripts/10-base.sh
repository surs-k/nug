#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


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

####### limine reads the directory holding its own efi binary before /boot,
####### so a stray limine.conf beside the binary silently wins
####### limine-snapper-sync rewrites /boot/limine.conf on every snapshot, so
####### the menu is re-checked by a hook after every save instead of by hand


## Stray

for c in /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf /boot/limine/limine.conf; do
	if [[ -f "$c" ]]; then
		$SUDO mv "$c" "$c.disabled"
		flag "moved $c aside, it outranked /boot/limine.conf"
	fi
done


## Cmdline

####### installs made before v7.0 wrote subvol=@, the snapshot tool only
####### recognises subvol=/@, both mount the same thing
if grep -Eq 'rootflags=subvol=@([[:space:]]|$)' /etc/kernel/cmdline; then
	$SUDO sed -i -E 's#rootflags=subvol=@([[:space:]]|$)#rootflags=subvol=/@\1#' /etc/kernel/cmdline
	note "root subvolume now written as /@ in /etc/kernel/cmdline"
fi


## Fstab

####### same repair as 05-iso makes on a fresh install, see Fstab in 00-lib
if ! fstab_root_named /etc/fstab; then
	$SUDO cp /etc/fstab /etc/fstab.pre-v7.0
	fstab_root_by_name /etc/fstab
	note "/ in fstab now mounts by name only, old copy at /etc/fstab.pre-v7.0"
fi


## Enforcer

####### the same file 05-iso used to write the menu, now installed for good
####### the snapshot tool runs it after every save, and so does 20-desktop
####### after it changes the cmdline
$SUDO install -m 755 "$SCRIPTS/limine-header-fix.sh" /usr/local/bin/limine-header-fix

####### only created when missing, a choice made later with --flat or
####### --timeout is never overwritten by a rerun
if [[ ! -f /etc/rebuild-boot.conf ]]; then
	printf 'BOOT_MODE=nested\nBOOT_TIMEOUT=%s\n' "$LIMINE_TIMEOUT" \
		| $SUDO tee /etc/rebuild-boot.conf > /dev/null
fi


## Apply

####### also converts an older flat menu to the nested shape, and keeps
####### any snapshot entries already in it
run "write boot menu" $SUDO /usr/local/bin/limine-header-fix



#    Swap


section "Swap"

$SUDO tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

####### swap in RAM behaves nothing like swap on a disk
####### the defaults are tuned for a spinning disk and leave zram unused
####### these are the values Pop_OS ships and the Arch wiki documents
$SUDO tee /etc/sysctl.d/99-zram.conf > /dev/null << 'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

run "apply swap tuning" $SUDO sysctl --system

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

printf '\nUpdated to %s\n' "$(git rev-parse --short HEAD)"
printf 'Now run: rebuild\n\n'
EOF

$SUDO chmod 755 /usr/local/bin/rebuild-update


## Command

####### one word from anywhere, no cd and no executable bit to care about
$SUDO tee /usr/local/bin/rebuild > /dev/null << 'EOF'
#!/usr/bin/env bash
####### the scripts moved into Scripts in v7.5, an older checkout still works
if [[ -f "$HOME/Rebuild/Scripts/run.sh" ]]; then
	exec bash "$HOME/Rebuild/Scripts/run.sh" "$@"
fi
exec bash "$HOME/Rebuild/run.sh" "$@"
EOF

$SUDO chmod 755 /usr/local/bin/rebuild

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
check "swap tuning"      test -f /etc/sysctl.d/99-zram.conf
check "no stray conf"    sh -c '! test -f /boot/EFI/limine/limine.conf'
check "menu starts alone" $SUDO /usr/local/bin/limine-header-fix --check
check "cmdline names /@" grep -q 'rootflags=subvol=/@' /etc/kernel/cmdline
check "fstab / by name"  fstab_root_named /etc/fstab
check "deploy hook"      test -f /etc/pacman.d/hooks/99-limine-deploy.hook
check "menu tool"        test -x /usr/local/bin/limine-header-fix
check "yay present"      command -v yay
check "update helper"    test -x /usr/local/bin/rebuild-update
check "rebuild command"  test -x /usr/local/bin/rebuild

warn  "tpm2 enrolled"    sh -c 'sudo cryptsetup luksDump /dev/disk/by-partlabel/cryptsystem > /tmp/_lk; grep -q systemd-tpm2 /tmp/_lk'

verify_done

stage_done



#    End


section "End"

printf '  Base system configured.\n\n'
