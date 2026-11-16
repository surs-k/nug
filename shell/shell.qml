//@ pragma UseQApplication

// Dream shell: where everything starts.
// Each block below switches one part on. Remove a block and that part is gone.

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
	// a bar on every screen
	Variants {
		model: Quickshell.screens
		Bar {}
	}

	// the launcher is only built while it is open, so it costs nothing when shut
	LazyLoader {
		active: Ui.launcherOpen
		Launcher {}
	}

	NotifPopups {}

	// the Settings window is only built while it is open
	LazyLoader {
		active: Ui.settingsOpen
		SettingsWindow {}
	}

	// lets keys and commands talk to the shell:  dream launcher, dream settings ...
	IpcHandler {
		target: "dream"
		function launcher(): void { Ui.launcherOpen = !Ui.launcherOpen }
		function settings(): void { Ui.settingsOpen = !Ui.settingsOpen }
		function look(name: string): void { Cfg.look = name }
		function nextLook(): void { Theme.next() }
		function looks(): string { return Theme.names.join("\n") }
	}
}
