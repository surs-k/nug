// The Settings window. Each block shows a one-line summary and opens on click.
// Everything here writes to ~/.config/dream/settings.json, nothing is hidden.

import QtQuick
import Quickshell

FloatingWindow {
	id: win

	title: "Dream settings"
	implicitWidth: 520
	implicitHeight: 680
	color: Theme.panelSolid
	visible: true
	onVisibleChanged: if (!visible) Ui.settingsOpen = false

	readonly property var programs: {
		const names = Object.keys(Cfg.notifications.programs)
		for (const s of Notifs.seen) if (names.indexOf(s) < 0) names.push(s)
		return names.sort()
	}
	function open(path) { Quickshell.execDetached(["xdg-open", path]) }

	Flickable {
		anchors.fill: parent
		anchors.margins: 14
		contentHeight: page.height
		clip: true

		Column {
			id: page
			width: parent.width
			spacing: 2

			Txt { text: "Dream settings"; font.pixelSize: 20; font.weight: Font.Bold; leftPadding: 12 }
			Txt { width: parent.width; text: "Changes apply at once and are saved for you."; color: Theme.muted; leftPadding: 12; bottomPadding: 10 }

			Section {
				title: "Look"
				summary: Cfg.look
				open: true
				Flow {
					width: parent.width
					spacing: 6
					Repeater {
						model: Theme.names
						Btn { required property string modelData; text: modelData; primary: modelData === Cfg.look; onClicked: Cfg.look = modelData }
					}
				}
				Txt { width: parent.width; wrapMode: Text.Wrap; color: Theme.muted; text: "To make your own: open the looks file, copy one block, give it a new name and change the colours. It appears here as soon as you save." }
				Btn { text: "Open the looks file"; onClicked: win.open(Cfg.dir + "/looks.json") }
			}

			Section {
				title: "Bar"
				summary: Cfg.bar.height + " pixels tall"
				Stepper { label: "Height"; value: Cfg.bar.height; from: 16; to: 48; unit: " px"; onChanged: to => Cfg.bar.height = to }
				Stepper { label: "Space above"; value: Cfg.bar.gap; from: 0; to: 20; unit: " px"; onChanged: to => Cfg.bar.gap = to }
				Stepper { label: "Text size"; value: Cfg.bar.textSize; from: 8; to: 20; unit: " px"; onChanged: to => Cfg.bar.textSize = to }
			}

			Section {
				title: "Clock"
				summary: Cfg.clock.hour24 ? "24-hour" : "12-hour, no am or pm"
				Toggle { label: "24-hour clock"; checked: Cfg.clock.hour24; onToggled: on => Cfg.clock.hour24 = on }
				Toggle { label: "Show seconds"; checked: Cfg.clock.seconds; onToggled: on => Cfg.clock.seconds = on }
				Toggle { label: "Show date on the bar"; checked: Cfg.clock.dateOnBar; onToggled: on => Cfg.clock.dateOnBar = on }
			}

			Section {
				title: "Performance"
				summary: Cfg.performance.onBar.length + " readings on the bar"
				Repeater {
					model: Perf.metrics
					Toggle {
						required property var modelData
						icon: modelData.icon
						label: modelData.name
						checked: Cfg.performance.onBar.indexOf(modelData.key) >= 0
						onToggled: on => {
							const now = Array.from(Cfg.performance.onBar)
							Cfg.performance.onBar = Perf.metrics.map(m => m.key).filter(k => k === modelData.key ? on : now.indexOf(k) >= 0)
						}
					}
				}
				Stepper { label: "Refresh every"; value: Cfg.performance.everySeconds; from: 1; to: 30; unit: " s"; onChanged: to => Cfg.performance.everySeconds = to }
				Txt { width: parent.width; wrapMode: Text.Wrap; color: Theme.muted; text: "A slower refresh uses less of the processor. A new speed starts after the shell reloads." }
			}

			Section {
				title: "Launcher"
				summary: Cfg.launcher.rows + " programs per page"
				Stepper { label: "Programs per page"; value: Cfg.launcher.rows; from: 3; to: 14; onChanged: to => Cfg.launcher.rows = to }
			}

			Section {
				title: "Notifications"
				summary: Cfg.notifications.muteUnimportant ? "Only important ones pop up" : "Important and normal ones pop up"
				Toggle { label: "Mute unimportant pop-ups"; checked: Cfg.notifications.muteUnimportant; onToggled: on => Cfg.notifications.muteUnimportant = on }
				Toggle { label: "Important only while a game is fullscreen"; checked: Cfg.notifications.importantOnlyInFullscreen; onToggled: on => Cfg.notifications.importantOnlyInFullscreen = on }
				Stepper { label: "Stay on screen"; value: Cfg.notifications.seconds; from: 2; to: 30; unit: " s"; onChanged: to => Cfg.notifications.seconds = to }
				Txt { text: "Per program"; font.weight: Font.DemiBold; topPadding: 6 }
				Txt { width: parent.width; wrapMode: Text.Wrap; color: Theme.muted; text: "A program shows up here after it has sent its first notification." }
				Repeater {
					model: win.programs
					Item {
						id: prow
						required property string modelData
						readonly property string level: Cfg.notifications.programs[modelData] ?? "normal"
						width: parent.width; height: 32
						Txt { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 250; text: prow.modelData }
						Row {
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							spacing: 4
							Repeater {
								model: ["important", "normal", "silent"]
								Btn { required property string modelData; text: modelData[0].toUpperCase() + modelData.slice(1); primary: prow.level === modelData; onClicked: Notifs.setLevel(prow.modelData, modelData) }
							}
						}
					}
				}
			}

			Section {
				title: "Desktops"
				summary: "Switch between Dream and HyDE"
				Txt { width: parent.width; wrapMode: Text.Wrap; text: "At the login screen, pick Dream or Hyprland in the session list. Hyprland is your HyDE desktop, kept as the backup." }
				Txt { width: parent.width; wrapMode: Text.Wrap; color: Theme.muted; text: "You can also swap the bar without logging out. Your windows stay where they are." }
				Row {
					spacing: 6
					Btn { text: "Use the HyDE bar now"; onClicked: Ui.run("dream off") }
				}
			}

			Section {
				title: "Change anything else"
				summary: "Where every file lives, and the guide"
				Txt { width: parent.width; wrapMode: Text.Wrap; text: "The guide lists every part of this desktop, what it is for, and the one file that changes it." }
				Flow {
					width: parent.width
					spacing: 6
					Btn { primary: true; text: "Open the guide"; onClicked: win.open(Cfg.dir + "/GUIDE.md") }
					Btn { text: "Settings file"; onClicked: win.open(Cfg.dir + "/settings.json") }
					Btn { text: "Looks file"; onClicked: win.open(Cfg.dir + "/looks.json") }
					Btn { text: "The shell's own files"; onClicked: win.open(Quickshell.shellDir) }
				}
			}
		}
	}
}
