pragma Singleton

// Receives every notification and decides what happens to it.
//   important  always pops up, even over a game
//   normal     pops up unless muted, or a fullscreen window has focus
//   silent     never pops up, waits quietly in the panel
// A program's level is set in settings.json under notifications.programs.
// Without a rule, a program's own "critical" flag makes it important.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications

Singleton {
	id: root

	readonly property var all: server.trackedNotifications.values
	readonly property var loud: all.filter(n => level(n) !== "silent")
	readonly property int waiting: loud.length
	readonly property int important: all.filter(n => level(n) === "important").length
	readonly property bool fullscreen: Hyprland.focusedWorkspace?.hasFullscreen ?? false

	property var popups: []
	property var seen: []       // program names met this session, for the Settings window

	function level(n) {
		const rule = Cfg.notifications.programs[n.appName]
		if (rule) return rule
		return n.urgency === NotificationUrgency.Critical ? "important" : "normal"
	}
	function setLevel(program, lvl) {
		const map = Object.assign({}, Cfg.notifications.programs)
		if (lvl === "normal") delete map[program]; else map[program] = lvl
		Cfg.notifications.programs = map
	}
	function wantsPopup(n) {
		const lvl = level(n)
		if (lvl === "silent") return false
		if (lvl === "important") return true
		if (Cfg.notifications.muteUnimportant) return false
		return !(Cfg.notifications.importantOnlyInFullscreen && fullscreen)
	}
	function hide(n) { popups = popups.filter(p => p !== n) }
	function clear() { for (const n of all.slice()) n.dismiss() }

	NotificationServer {
		id: server
		keepOnReload: true
		bodySupported: true
		actionsSupported: true
		imageSupported: true

		onNotification: n => {
			n.tracked = true
			if (n.appName !== "" && root.seen.indexOf(n.appName) < 0) root.seen = root.seen.concat([n.appName])
			n.closed.connect(() => root.hide(n))
			if (root.wantsPopup(n)) root.popups = root.popups.concat([n])
			// keep the pile bounded, oldest go first
			const all = root.all
			for (let i = 0; i < all.length - 60; i++) all[i].dismiss()
		}
	}
}
