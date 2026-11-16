-- Dream shell on Hyprland.
--
-- Your HyDE config loads this file. It does nothing unless Dream is on:
--   the Dream login session turns it on, and so does the command "dream on".
-- When on, it keeps HyDE's windows, workspaces, animations and your own keys,
-- and swaps only the bar, the notifications and the app launcher.
--
-- Keys set here:
--   SUPER + A           app launcher
--   SUPER + I           settings
--   SUPER + ALT + Up    next look

local home = os.getenv("HOME") or ""
local runtime = os.getenv("XDG_RUNTIME_DIR") or "/tmp"

local function first_line(path)
	local h = io.open(path, "r")
	if not h then return nil end
	local s = h:read("l")
	h:close()
	return s
end

-- "dream on" and "dream off" leave a one-word note for this Hyprland session only
local sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local mine = sig and (runtime .. "/hypr/" .. sig) or runtime
local choice = first_line(mine .. "/dream-shell")
local on = choice == "on" or (choice ~= "off" and os.getenv("DREAM_SESSION") == "1")

if not on then return end

local dream = home .. "/.local/bin/dream"

-- HyDE restarts its own bar after every reload, this puts it down again
hl.exec_cmd(dream .. " hold")

-- what HyDE starts at login: Dream in place of its bar and notifications
if hyde and hyde.config and hyde.config.start then
	local s = hyde.config.start
	s.bar = dream .. " start"
	s.notifications = ""
	-- the Connections piece on the bar covers these two tray applets
	s.applet_network_manager = ""
	s.applet_bluetooth = ""
end

hl.unbind("SUPER + A")
hl.bind("SUPER + A", hl.dsp.exec_cmd(dream .. " launcher"), { description = "[Dream] app launcher" })

hl.unbind("SUPER + I")
hl.bind("SUPER + I", hl.dsp.exec_cmd(dream .. " settings"), { description = "[Dream] settings" })

hl.unbind("SUPER + ALT + Up")
hl.bind("SUPER + ALT + Up", hl.dsp.exec_cmd(dream .. " look next"), { description = "[Dream] next look" })

-- see-through looks get a blur behind them, the gaps between pieces do not
hl.layer_rule({
	name  = "dream_blur",
	match = { namespace = "^(dream-.*)$" },
	blur  = true,
})
hl.layer_rule({
	name         = "dream_ignore_alpha",
	match        = { namespace = "^(dream-.*)$" },
	ignore_alpha = 0.3,
})

hl.window_rule({
	name   = "dream-settings",
	match  = { title = "^(Dream settings)$" },
	float  = true,
	size   = "520 680",
	center = true,
})
