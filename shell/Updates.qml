pragma Singleton

// Counts waiting updates. It only looks, it never installs anything.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	property var list: []
	property bool checking: false
	readonly property int count: list.length

	function check() { if (!checker.running) { root.checking = true; checker.running = true } }

	Process {
		id: checker
		command: ["checkupdates"]
		stdout: StdioCollector {
			onStreamFinished: root.list = text.split("\n").filter(l => l.trim() !== "").map(l => l.split(" ")[0])
		}
		onExited: root.checking = false
	}
	Timer { interval: 15000; running: true; onTriggered: root.check() }
	Timer { interval: 30 * 60 * 1000; running: true; repeat: true; onTriggered: root.check() }
}
