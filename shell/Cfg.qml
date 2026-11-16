pragma Singleton

// Every setting the shell has, in one place.
// The values here are the defaults. Your own choices are saved in
// ~/.config/dream/settings.json, and the shell follows that file live:
// change it by hand or in the Settings window, the result is the same.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	readonly property string home: Quickshell.env("HOME")
	readonly property string dir: home + "/.config/dream"
	readonly property string stateDir: home + "/.local/state/dream"

	property alias look: adapter.look
	property alias bar: adapter.bar
	property alias clock: adapter.clock
	property alias performance: adapter.performance
	property alias tray: adapter.tray
	property alias launcher: adapter.launcher
	property alias notifications: adapter.notifications
	property alias apps: adapter.apps

	FileView {
		id: file
		path: root.dir + "/settings.json"
		watchChanges: true
		onFileChanged: reload()
		onAdapterUpdated: writeAdapter()
		onLoadFailed: firstWrite.start()

		JsonAdapter {
			id: adapter

			// name of a look from looks.json
			property string look: "Glass night"

			property JsonObject bar: JsonObject {
				property int height: 24        // pixels
				property int gap: 4            // space above the bar
				property int textSize: 12
			}
			property JsonObject clock: JsonObject {
				property bool hour24: false
				property bool seconds: false
				property bool dateOnBar: false
			}
			property JsonObject performance: JsonObject {
				// which readings sit on the bar: cpu gpu ram cputemp gputemp gpupower
				property list<string> onBar: ["cpu", "gpu", "gputemp"]
				property int everySeconds: 2
			}
			property JsonObject tray: JsonObject {
				property bool folded: false
				property list<string> hidden: []
			}
			property JsonObject launcher: JsonObject {
				property int rows: 8
				// picture shown beside the list, HyDE keeps the current wallpaper here
				property string picture: root.home + "/.cache/hyde/wall.set"
			}
			property JsonObject notifications: JsonObject {
				property bool muteUnimportant: false
				property bool importantOnlyInFullscreen: true
				property int seconds: 6
				// per program: "important", "normal" or "silent"
				property var programs: ({ "Claude": "silent" })
			}
			property JsonObject apps: JsonObject {
				property string terminal: "kitty"
				property string update: "sudo pacman -Syu"
				property string network: "nm-connection-editor"
				property string bluetooth: "blueman-manager"
				property string audio: "pavucontrol"
			}
		}
	}

	Timer { id: firstWrite; interval: 300; onTriggered: file.writeAdapter() }
	Process { running: true; command: ["mkdir", "-p", root.dir, root.stateDir] }
}
