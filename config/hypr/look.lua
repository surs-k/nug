-- Ai - the look, from config/theme.env, kept last in the file on purpose:
--      if a future Hyprland renames one of these, only the look is lost,
--      every key and program above has already been set

hl.config({
	general = {
		gaps_in = ${GAP},
		gaps_out = ${GAP_OUT},
		border_size = ${BORDER},
	},
	decoration = {
		rounding = ${RADIUS},
	},
	misc = {
		disable_hyprland_logo = true,
		force_default_wallpaper = 0,
		background_color = "rgb(${BG_RAW})",
	},
})

hl.config({
	general = {
		["col.active_border"] = "rgb(${ACCENT_RAW})",
		["col.inactive_border"] = "rgb(${OVERLAY_RAW})",
	},
})
