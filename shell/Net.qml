pragma Singleton

// Wired, Wi-Fi and Bluetooth state.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

Singleton {
	id: root

	property bool wired: false
	property string wifi: "off"        // "connected", "disconnected" or "off"
	property string wifiName: ""
	readonly property bool online: wired || wifi === "connected"

	readonly property bool btOn: Bluetooth.defaultAdapter?.enabled ?? false
	readonly property var btDevices: Bluetooth.devices.values.filter(d => d.connected)

	function refresh() { poll.running = true }

	Process {
		id: poll
		running: true
		command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device", "status"]
		stdout: StdioCollector {
			onStreamFinished: {
				let wired = false, wifi = "off", name = ""
				for (const line of text.split("\n")) {
					const [type, state, conn] = line.split(":")
					if (type === "ethernet" && state === "connected") wired = true
					if (type === "wifi") {
						wifi = state === "connected" ? "connected" : state === "unavailable" ? "off" : "disconnected"
						if (state === "connected") name = conn ?? ""
					}
				}
				root.wired = wired; root.wifi = wifi; root.wifiName = name
			}
		}
	}
	Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }
}
