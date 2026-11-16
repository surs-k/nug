pragma Singleton

// Mullvad state. It listens for changes, so nothing is polled.
// Addresses in the output are thrown away, never kept or shown.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	property string state: "Unknown"     // Connected, Connecting, Disconnected, Blocked, Unknown
	property string place: ""
	property string relay: ""
	readonly property bool connected: state === "Connected"

	function connect() { Quickshell.execDetached(["mullvad", "connect"]) }
	function disconnect() { Quickshell.execDetached(["mullvad", "disconnect"]) }

	Process {
		id: listen
		running: true
		command: ["mullvad", "status", "listen"]
		stdout: SplitParser {
			onRead: raw => {
				const line = raw.trim()
				const word = line.split(/[ :]/)[0]
				if (["Connected", "Connecting", "Disconnected", "Disconnecting", "Blocked"].includes(word)) {
					root.state = word === "Disconnecting" ? "Disconnected" : word
					if (word !== "Connected") { root.place = ""; root.relay = "" }
				} else if (line.startsWith("Relay:")) {
					root.relay = line.slice(6).trim()
				} else if (line.startsWith("Visible location:")) {
					root.place = line.slice(17).split(". IPv")[0].trim()
				}
			}
		}
		onExited: retry.start()
	}
	Timer { id: retry; interval: 10000; onTriggered: listen.running = true }
}
