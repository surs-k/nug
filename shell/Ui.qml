pragma Singleton

// What is open right now. Anything can flip these.

import QtQuick
import Quickshell

Singleton {
	property bool launcherOpen: false
	property bool settingsOpen: false

	function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }
	function inTerminal(cmd) { Quickshell.execDetached([Cfg.apps.terminal, "--hold", "-e", "sh", "-c", cmd]) }
}
