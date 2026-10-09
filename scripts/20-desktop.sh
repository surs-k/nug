#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 10-base



#    Graphics


section "Graphics"

	# Ai - the laptop only has to show a stream, so this is the open stack and
	#      nothing else, no proprietary driver, no CUDA
	#      a display controller is PCI class 03, and 0x8086 is Intel, 0x1002 AMD,
	#      0x10de NVIDIA, read from sysfs so it needs no package to ask
VENDORS=""

for d in /sys/bus/pci/devices/*; do
	[[ "$(cat "$d/class" 2>/dev/null || true)" == 0x03* ]] || continue
	VENDORS+=" $(cat "$d/vendor" 2>/dev/null || true)"
done

pac mesa

	# Ai - the video decoder is what makes a stream smooth on a laptop, without
	#      it Moonlight decodes on the CPU and the fan never stops
if contains "$VENDORS" "0x8086"; then
	note "Intel graphics, video decoding on the GPU"
	pac intel-media-driver
fi

if contains "$VENDORS" "0x1002"; then
	note "AMD graphics"
		# Ai - the decoder moved into mesa itself in newer releases, so this
		#      package may not exist any more, and that is fine
	if pacman -Si libva-mesa-driver &> /dev/null; then
		pac libva-mesa-driver
	fi
fi

if contains "$VENDORS" "0x10de"; then
	note "NVIDIA graphics found, the open driver is used"
	note "the display runs on the Intel or AMD chip, which is plenty for a stream"
fi



#    Desktop


section "Desktop"


## Packages

	# Ai - a compositor, a terminal, a launcher, a lock screen and sound
	#      nothing else, no bar, no notifications, no file manager
pac hyprland kitty fuzzel hyprlock hypridle brightnessctl ttf-dejavu

	# Ai - pipewire-jack is listed so the jack provider is already chosen, ffmpeg
	#      depends on one and pacman would otherwise stop to ask which
pac pipewire pipewire-pulse pipewire-jack wireplumber

	# Ai - they start at login from now on, a stream with no sound is a bug
soft "sound at login" systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service


## Config

	# Ai - the package's own example config is the base, so what Hyprland reads
	#      is always valid for the version installed, and only a small block of
	#      this machine's choices is added at the end
	#      the example is a .lua or a .conf depending on the version, and the
	#      block is written in whichever one it is
	#      Hyprland takes hyprland.lua over hyprland.conf when both exist, so a
	#      second file is never made beside the first
HYPR="$HOME/.config/hypr"

mkdir -p "$HYPR"

CONF=""
KIND=none

if [[ -f "$HYPR/hyprland.lua" ]]; then
	CONF="$HYPR/hyprland.lua"
	KIND=lua
elif [[ -f "$HYPR/hyprland.conf" ]]; then
	CONF="$HYPR/hyprland.conf"
	KIND=conf
else
	for f in /usr/share/hypr/hyprland.lua /usr/share/hypr/hyprland.conf; do
		if [[ -f "$f" ]]; then
			CONF="$HYPR/$(basename "$f")"
			KIND="${f##*.}"
			cp "$f" "$CONF"
			note "base config copied from $f"
			break
		fi
	done
fi

if [[ "$KIND" == none ]]; then
	flag "the package ships no example config, so no keys or layout were added"
	flag "Hyprland writes its own on first start, the layout still comes from the profile below"
fi

[[ -z "$CONF" ]] || [[ -f "$CONF.bak-rebuild" ]] || cp "$CONF" "$CONF.bak-rebuild"


## Block

	# Ai - one block between two marker lines, replaced whole on every run, so
	#      a rerun never writes it twice
	#      terminal on SUPER + Return, launcher on SUPER + R, lock on SUPER + L,
	#      and SUPER + P opens your PC's screen
	#      SUPER + R and SUPER + P are taken in the example, so they are freed
	#      first
	#      hypridle is started here, with a check, because this file is read
	#      again on every reload and a second copy would fight the first
	# Ai - a file that does not end in a newline would have its last line joined
	#      to the first line of the block
if [[ -n "$CONF" && -n "$(tail -c 1 "$CONF")" ]]; then
	printf '\n' >> "$CONF"
fi

if [[ "$KIND" == lua ]]; then

	sed -i '/^-- rebuild laptop start$/,/^-- rebuild laptop end$/d' "$CONF"

	cat >> "$CONF" << LUAEOF
-- rebuild laptop start

hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "$KEYMAP"
  }
})

hl.unbind("SUPER + R")
hl.unbind("SUPER + P")

hl.bind("SUPER + Return", hl.dsp.exec_cmd("kitty"), { description = "[Laptop] terminal" })
hl.bind("SUPER + R", hl.dsp.exec_cmd("fuzzel"), { description = "[Laptop] launcher" })
hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"), { description = "[Laptop] lock" })
hl.bind("SUPER + P", hl.dsp.exec_cmd("kitty -e pc view"), { description = "[Laptop] your PC screen" })

hl.exec_cmd("pgrep -x hypridle > /dev/null || hypridle")

-- rebuild laptop end
LUAEOF

	note "laptop block written to hyprland.lua"

elif [[ "$KIND" == conf ]]; then

	sed -i '/^# rebuild laptop start$/,/^# rebuild laptop end$/d' "$CONF"

	cat >> "$CONF" << CONFEOF
# rebuild laptop start

input {
    kb_layout = us
    kb_variant = $KEYMAP
}

unbind = SUPER, R
unbind = SUPER, P

bind = SUPER, Return, exec, kitty
bind = SUPER, R, exec, fuzzel
bind = SUPER, L, exec, hyprlock
bind = SUPER, P, exec, kitty -e pc view

exec-once = hypridle

# rebuild laptop end
CONFEOF

	note "laptop block written to hyprland.conf"
fi


## Lock

	# Ai - written only when missing, so any change you make later stays
	#      five minutes idle locks, a minute after that the screen goes dark
	#      the lid does the same through logind, which tells hypridle to lock
	#      there is no sleep step, the SSD must never sleep, see 10-base
if [[ -f "$HYPR/hypridle.conf" ]]; then
	note "hypridle config already there, left as it is"
else
	cat > "$HYPR/hypridle.conf" << 'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 360
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
EOF
	note "hypridle config written"
fi

if [[ -f "$HYPR/hyprlock.conf" ]]; then
	note "hyprlock config already there, left as it is"
else
	cat > "$HYPR/hyprlock.conf" << 'EOF'
general {
    hide_cursor = true
    grace = 0
}

background {
    monitor =
    color = rgba(0, 0, 0, 1.0)
}

input-field {
    monitor =
    size = 300, 50
    outline_thickness = 2
    dots_size = 0.25
    fade_on_empty = true
    hide_input = false
    position = 0, 0
    halign = center
    valign = center
}
EOF
	note "hyprlock config written"
fi



#    Login


section "Login"

	# Ai - the disk passphrase is already typed at every boot, so a second
	#      password to reach the desktop only slows a cold start, the lock
	#      screen is what guards a machine that is already on
	#      agetty logs the user in on the first console, and that login starts
	#      Hyprland
	#      ~/.no-desktop stops it, for the day the desktop will not start and
	#      the login loops, the second console (Ctrl+Alt+F2) is always plain
$SUDO mkdir -p /etc/systemd/system/getty@tty1.service.d

$SUDO tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
EOF

run "reload systemd" $SUDO systemctl daemon-reload


## Profile

	# Ai - the layout is also given as environment, Hyprland falls back to it
	#      for anything its config leaves empty, so the keys are right even if
	#      the block above could not be written
PROFILE="$HOME/.bash_profile"

touch "$PROFILE"

sed -i '/^# rebuild desktop start$/,/^# rebuild desktop end$/d' "$PROFILE"

cat >> "$PROFILE" << EOF
# rebuild desktop start
export XKB_DEFAULT_LAYOUT=us
export XKB_DEFAULT_VARIANT=$KEYMAP
if [[ -z "\${WAYLAND_DISPLAY:-}" && "\${XDG_VTNR:-0}" == 1 && ! -e "\$HOME/.no-desktop" ]]; then
	exec Hyprland
fi
# rebuild desktop end
EOF

note "Hyprland starts at login on the first console"



#    Verify


section "Verify"

check "hyprland"          command -v Hyprland
check "kitty"             command -v kitty
check "fuzzel"            command -v fuzzel
check "hyprlock"          command -v hyprlock
check "hypridle"          command -v hypridle
check "brightnessctl"     command -v brightnessctl
check "idle config"       test -f "$HYPR/hypridle.conf"
check "lock config"       test -f "$HYPR/hyprlock.conf"
check "autologin"         test -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
check "desktop at login"  grep -q 'rebuild desktop start' "$PROFILE"
check "layout in profile" grep -q "XKB_DEFAULT_VARIANT=$KEYMAP" "$PROFILE"

if [[ "$KIND" != none ]]; then
	check "layout in config" grep -q "$KEYMAP" "$CONF"
fi

	# Ai - only asked of a Hyprland that knows the flag, a version without it
	#      would start the compositor instead of reading the file
if [[ "$KIND" != none ]] && Hyprland --help 2>&1 | grep -q -- '--verify-config'; then
	warn "config accepted" Hyprland --verify-config -c "$CONF"
fi

verify_done

stage_done



#    End


section "End"

printf '  Desktop installed. It starts by itself at the next boot.\n\n'
printf '    SUPER + Return   terminal\n'
printf '    SUPER + R        launcher\n'
printf '    SUPER + L        lock\n'
printf '    SUPER + P        your PC screen\n\n'
printf '  If the screen stays black: Ctrl+Alt+F2, log in, then\n\n'
printf '    touch ~/.no-desktop\n\n'
