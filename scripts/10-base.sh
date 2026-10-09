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

	# Ai - colour and parallel downloads make the install bars readable
$SUDO sed -i 's/^#Color$/Color/'                          /etc/pacman.conf
$SUDO sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

grep -q '^Color'            /etc/pacman.conf || printf 'Color\n'            | $SUDO tee -a /etc/pacman.conf > /dev/null
grep -q '^ParallelDownloads' /etc/pacman.conf || printf 'ParallelDownloads = 5\n' | $SUDO tee -a /etc/pacman.conf > /dev/null


## Sync

pac archlinux-keyring

run "full system upgrade" $SUDO pacman -Syu --noconfirm



#    Host


section "Host"

	# Ai - this stage runs on the real booted system, where hostnamectl works
	#      properly, so it is also the place that can repair a bad hostname

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

	# Ai - capture then match, a pipeline into grep -q can take SIGPIPE
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

	# Ai - limine reads the directory holding its own efi binary before /boot,
	#      so a stray limine.conf beside the binary silently wins
	#      limine-snapper-sync rewrites /boot/limine.conf on every snapshot, so
	#      the menu is re-checked by a hook after every save instead of by hand


## Stray

for c in /boot/EFI/limine/limine.conf /boot/EFI/BOOT/limine.conf /boot/limine/limine.conf; do
	if [[ -f "$c" ]]; then
		$SUDO mv "$c" "$c.disabled"
		flag "moved $c aside, it outranked /boot/limine.conf"
	fi
done


## Cmdline

	# Ai - installs made before v7.0 wrote subvol=@, the snapshot tool only
	#      recognises subvol=/@, both mount the same thing
if grep -Eq 'rootflags=subvol=@([[:space:]]|$)' /etc/kernel/cmdline; then
	$SUDO sed -i -E 's#rootflags=subvol=@([[:space:]]|$)#rootflags=subvol=/@\1#' /etc/kernel/cmdline
	note "root subvolume now written as /@ in /etc/kernel/cmdline"
fi


## Fstab

	# Ai - same repair as iso.sh makes on a fresh install, see Fstab in 00-lib
if ! fstab_root_named /etc/fstab; then
	$SUDO cp /etc/fstab /etc/fstab.pre-v7.0
	fstab_root_by_name /etc/fstab
	note "/ in fstab now mounts by name only, old copy at /etc/fstab.pre-v7.0"
fi


## Enforcer

	# Ai - the same file iso.sh used to write the menu, now installed for good
	#      the snapshot tool runs it after every save, and so does 20-desktop
	#      after it changes the cmdline
$SUDO install -m 755 "$SCRIPTS/limine-header-fix.sh" /usr/local/bin/limine-header-fix

	# Ai - only created when missing, a choice made later with --flat or
	#      --timeout is never overwritten by a rerun
if [[ ! -f /etc/rebuild-boot.conf ]]; then
	printf 'BOOT_MODE=nested\nBOOT_TIMEOUT=%s\n' "$LIMINE_TIMEOUT" \
		| $SUDO tee /etc/rebuild-boot.conf > /dev/null
fi


## Apply

	# Ai - also converts an older flat menu to the nested shape, and keeps
	#      any snapshot entries already in it
run "write boot menu" $SUDO /usr/local/bin/limine-header-fix



#    Swap


section "Swap"

$SUDO tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

	# Ai - swap in RAM behaves nothing like swap on a disk
	#      the defaults are tuned for a spinning disk and leave zram unused
	#      these are the values Pop_OS ships and the Arch wiki documents
$SUDO tee /etc/sysctl.d/99-zram.conf > /dev/null << 'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

run "apply swap tuning" $SUDO sysctl --system

run "reload systemd" $SUDO systemctl daemon-reload



#    Power


section "Power"

	# Ai - the system disk is a USB SSD, and a USB disk that has to wake up
	#      from sleep can drop off the bus, which leaves the root filesystem
	#      unreachable and then read only, so this machine never sleeps
	#      the lid and the sleep keys lock the screen or do nothing instead,
	#      and the sleep targets are masked so nothing else can start one

pac upower

$SUDO mkdir -p /etc/systemd/logind.conf.d

$SUDO tee /etc/systemd/logind.conf.d/20-rebuild-laptop.conf > /dev/null << 'EOF'
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

run "mask sleep" $SUDO systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

	# Ai - a flat battery would cut the power in the middle of a write
	#      UPower powers the laptop off cleanly at 5 percent instead, its
	#      default is to hybrid sleep, which is masked above
	#      the three levels have to stay in this order or UPower ignores them
$SUDO sed -i \
	-e 's/^PercentageLow=.*/PercentageLow=15/' \
	-e 's/^PercentageCritical=.*/PercentageCritical=8/' \
	-e 's/^PercentageAction=.*/PercentageAction=5/' \
	-e 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' \
	/etc/UPower/UPower.conf

run "enable upower" $SUDO systemctl enable upower.service



#    Update


section "Update"

	# Ai - one command that refreshes the repo without ever hitting the
	#      "local changes would be overwritten" wall
	#      it throws away local edits on purpose, the repo is the source of truth

$SUDO tee /usr/local/bin/rebuild-update > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/rebuild"

cd "$REPO"

	# Ai - the executable bit counts as a change to git, so ignore modes
git config core.fileMode false

git fetch origin

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

	# Ai - discard local edits and match the remote exactly
git reset --hard "origin/$BRANCH"

find . -name '*.sh' -exec chmod +x {} +

printf '\nUpdated to %s\n' "$(git rev-parse --short HEAD)"
printf 'Now run: rebuild\n\n'
EOF

$SUDO chmod 755 /usr/local/bin/rebuild-update


## Command

	# Ai - one word from anywhere, no cd and no executable bit to care about
$SUDO tee /usr/local/bin/rebuild > /dev/null << 'EOF'
#!/usr/bin/env bash
exec bash "$HOME/rebuild/scripts/run.sh" "$@"
EOF

$SUDO chmod 755 /usr/local/bin/rebuild

if [[ -d "$HOME/rebuild/.git" ]]; then
	soft "let git ignore file modes" git -C "$HOME/rebuild" config core.fileMode false
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
check "lid locks"        grep -q "^HandleLidSwitch=lock" /etc/systemd/logind.conf.d/20-rebuild-laptop.conf
check "sleep masked"     sh -c 'systemctl is-enabled suspend.target 2>&1 | grep -q masked'
check "power off at 5"   grep -q "^CriticalPowerAction=PowerOff" /etc/UPower/UPower.conf
check "update helper"    test -x /usr/local/bin/rebuild-update
check "rebuild command"  test -x /usr/local/bin/rebuild


verify_done

stage_done



#    End


section "End"

printf '  Base system configured.\n\n'
