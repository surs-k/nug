-- Ai - the desktop's own keys and start-up, added after Hyprland's example
--      config, so the example's keys stay and only these are changed
--      keys taken from the example are freed first, then set

hl.config({
	input = {
		kb_layout = "${XKB_LAYOUT}",
		kb_variant = "${XKB_VARIANT}",
	},
})

hl.unbind("SUPER + R")
hl.bind("SUPER + R", hl.dsp.exec_cmd("fuzzel"), { description = "[nug] launcher" })
hl.bind("SUPER + Space", hl.dsp.exec_cmd("fuzzel"), { description = "[nug] launcher" })
hl.bind("SUPER + Return", hl.dsp.exec_cmd("kitty"), { description = "[nug] terminal" })
hl.unbind("SUPER + E")
hl.bind("SUPER + E", hl.dsp.exec_cmd("dolphin"), { description = "[nug] files" })
hl.bind("SUPER + L", hl.dsp.exec_cmd("loginctl lock-session"), { description = "[nug] lock" })
hl.bind("SUPER + Escape", hl.dsp.exec_cmd("nug-power"), { description = "[nug] lock, log out, restart, shut down" })
hl.bind("SUPER + slash", hl.dsp.exec_cmd("nug-keys"), { description = "[nug] every key" })
hl.bind("SUPER + N", hl.dsp.exec_cmd("changes"), { description = "[nug] Changes" })
-- Ai - the example logs out on SUPER + M with no question, work is lost
hl.unbind("SUPER + M")
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd("nug-shot"), { description = "[nug] screenshot of an area" })

-- Ai - started once, this file is read again on every reload, the pgrep
--      check stops a second copy

hl.exec_cmd("pgrep -x waybar > /dev/null || waybar")
hl.exec_cmd("pgrep -x mako > /dev/null || mako")
hl.exec_cmd("pgrep -x hypridle > /dev/null || hypridle")
hl.exec_cmd("pgrep -x nm-applet > /dev/null || nm-applet --indicator")
hl.exec_cmd("systemctl --user start hyprpolkitagent")
hl.exec_cmd("pgrep -f mullvad-gui > /dev/null || mullvad-vpn")
