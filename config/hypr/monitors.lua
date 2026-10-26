-- Ai - your two screens, matched by name so the cable port does not matter
--      the side screen stands on end, ROTATE in settings.conf: 1 is 90 degrees,
--      3 is 270, any other screen gets its best mode, placed automatically

hl.monitor({
	output = "desc:Sceptre Tech Inc Sceptre O34",
	mode = "3440x1440@165",
	position = "1080x233",
	scale = 1,
	transform = 0,
})

hl.monitor({
	output = "desc:Acer Technologies KG251Q T8ZAA00A8575",
	mode = "1920x1080@143.98",
	position = "0x0",
	scale = 1,
	transform = ${ROTATE},
})

hl.monitor({
	output = "",
	mode = "preferred",
	position = "auto",
	scale = 1,
	transform = 0,
})
