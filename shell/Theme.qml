pragma Singleton

// Turns the chosen look into colours and sizes the rest of the shell uses.
// Looks live in looks.json. The copy in ~/.config/dream/ wins over the one
// shipped next to this file, so that is the one to edit or add to.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	property var shipped: ({})
	property var mine: ({})
	readonly property var all: Object.assign({}, shipped, mine)
	readonly property var names: Object.keys(all)
	readonly property var l: Object.assign({}, fallback, all[Cfg.look] ?? {})

	readonly property var fallback: ({
		text: "#eef0ff", muted: "#a9add0", accent: "#8fb4ff", onAccent: "#0c1030",
		good: "#7fe0b0", warn: "#f0705c", chip: "#141632", chipOpacity: 0.55,
		panel: "#181a3a", panelOpacity: 0.9, border: "#ffffff", borderOpacity: 0.16,
		borderWidth: 1, radius: 14, chipRadius: 9, font: "Cantarell", wallpaper: ""
	})

	function parse(view) {
		try { return JSON.parse(view.text()) }
		catch (e) { console.warn("looks.json could not be read:", e); return {} }
	}
	function fade(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

	FileView {
		path: Qt.resolvedUrl("looks.json")
		onLoaded: root.shipped = root.parse(this)
	}
	FileView {
		path: Cfg.dir + "/looks.json"
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: root.mine = root.parse(this)
	}

	readonly property color fg: l.text
	readonly property color muted: l.muted
	readonly property color accent: l.accent
	readonly property color onAccent: l.onAccent
	readonly property color good: l.good
	readonly property color warn: l.warn
	readonly property color chipBase: l.chip
	readonly property color panelBase: l.panel
	readonly property color borderBase: l.border

	readonly property color chip: fade(chipBase, l.chipOpacity)
	readonly property color panel: fade(panelBase, l.panelOpacity)
	readonly property color panelSolid: panelBase
	readonly property color border: fade(borderBase, l.borderOpacity)
	readonly property color hover: fade(fg, 0.09)
	readonly property color line: fade(fg, 0.16)

	readonly property int borderWidth: l.borderWidth
	readonly property int radius: l.radius
	readonly property int chipRadius: l.chipRadius
	readonly property string font: l.font
	readonly property string wallpaper: l.wallpaper ?? ""

	function next() {
		const i = names.indexOf(Cfg.look)
		Cfg.look = names[(i + 1) % names.length]
	}

	// a look may name a wallpaper, it is applied when the look is chosen
	onWallpaperChanged: if (wallpaper !== "") Quickshell.execDetached(["awww", "img", wallpaper])
}
