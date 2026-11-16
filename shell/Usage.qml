pragma Singleton

// Remembers how often each program was opened from the launcher,
// so the ones you use most rise to the top.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	property var counts: ({})

	function of(id) { return counts[id] ?? 0 }
	function bump(id) {
		const c = Object.assign({}, counts)
		c[id] = (c[id] ?? 0) + 1
		counts = c
		file.setText(JSON.stringify(c, null, "\t"))
	}

	FileView {
		id: file
		path: Cfg.stateDir + "/launcher-usage.json"
		printErrors: false
		onLoaded: { try { root.counts = JSON.parse(text()) } catch (e) {} }
	}
}
