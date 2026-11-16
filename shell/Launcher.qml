// The app launcher. There is no search box: just start typing.
//   scroll or arrows  move the outline one program at a time, pages flip at the ends
//   Enter or click    open it
//   Escape            close
// Programs opened from here most often rise to the top.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland

PanelWindow {
	id: win

	visible: true
	screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
	anchors { top: true; bottom: true; left: true; right: true }
	exclusionMode: ExclusionMode.Ignore
	color: "transparent"
	WlrLayershell.namespace: "dream-launcher"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

	property string query: ""
	property int index: 0
	readonly property int rows: Math.max(3, Cfg.launcher.rows)
	readonly property int rowHeight: 44
	readonly property int page: Math.floor(index / rows)
	readonly property int pages: Math.max(1, Math.ceil(apps.length / rows))

	readonly property var apps: {
		const q = query.toLowerCase()
		let list = DesktopEntries.applications.values.filter(a => !a.noDisplay)
		if (q !== "") list = list.filter(a => a.name.toLowerCase().includes(q)
			|| (a.genericName ?? "").toLowerCase().includes(q)
			|| a.keywords.some(k => k.toLowerCase().includes(q)))
		return list.sort((a, b) => {
			if (q !== "") {
				const as = a.name.toLowerCase().startsWith(q), bs = b.name.toLowerCase().startsWith(q)
				if (as !== bs) return as ? -1 : 1
			}
			const d = Usage.of(b.id) - Usage.of(a.id)
			return d !== 0 ? d : a.name.localeCompare(b.name)
		})
	}

	function move(by) { index = Math.max(0, Math.min(apps.length - 1, index + by)) }
	function close() { Ui.launcherOpen = false }
	function launch(app) {
		if (!app) return
		Usage.bump(app.id)
		app.execute()
		close()
	}

	Component.onCompleted: keys.forceActiveFocus()

	MouseArea { anchors.fill: parent; onClicked: win.close() }

	Item {
		id: keys
		focus: true
		Keys.onPressed: e => {
			e.accepted = true
			if (e.key === Qt.Key_Escape) win.close()
			else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) win.launch(win.apps[win.index])
			else if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) win.move(1)
			else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) win.move(-1)
			else if (e.key === Qt.Key_PageDown) win.move(win.rows)
			else if (e.key === Qt.Key_PageUp) win.move(-win.rows)
			else if (e.key === Qt.Key_Backspace) { win.query = win.query.slice(0, -1); win.index = 0 }
			else if (e.text.length === 1 && e.text >= " " && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
				win.query += e.text; win.index = 0
			}
		}
	}

	Rectangle {
		id: panel
		anchors.centerIn: parent
		width: 560
		height: win.rows * win.rowHeight + 20
		radius: Theme.radius
		color: Theme.panel
		border.width: Theme.borderWidth
		border.color: Theme.border

		MouseArea {
			anchors.fill: parent
			onWheel: w => win.move(w.angleDelta.y > 0 ? -1 : 1)
		}

		// the current wallpaper
		ClippingRectangle {
			id: picture
			x: 6; y: 6
			width: 184
			height: parent.height - 12
			radius: Math.max(0, Theme.radius - 4)
			color: "transparent"

			Image {
				anchors.fill: parent
				source: Cfg.launcher.picture !== "" ? "file://" + Cfg.launcher.picture : ""
				fillMode: Image.PreserveAspectCrop
				sourceSize.height: 600
				asynchronous: true
				cache: false
			}

			// what you have typed, shown only while there is something
			Rectangle {
				visible: win.query !== ""
				anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
				height: 30
				radius: Math.min(Theme.chipRadius, 15)
				color: Theme.panel
				Txt { anchors.centerIn: parent; width: parent.width - 16; horizontalAlignment: Text.AlignHCenter; text: win.query; font.weight: Font.DemiBold }
			}
		}

		Column {
			anchors { left: picture.right; right: parent.right; top: parent.top; margins: 10 }

			Repeater {
				model: win.apps.slice(win.page * win.rows, (win.page + 1) * win.rows)
				Rectangle {
					id: line
					required property var modelData
					required property int index
					readonly property bool selected: win.page * win.rows + index === win.index
					width: parent.width
					height: win.rowHeight
					radius: Math.min(Theme.chipRadius, height / 2)
					color: selected ? Theme.hover : "transparent"
					border.width: selected ? 1 : 0
					border.color: Theme.accent

					IconImage {
						id: icon
						x: 10
						anchors.verticalCenter: parent.verticalCenter
						implicitSize: 28
						source: Quickshell.iconPath(line.modelData.icon, "application-x-executable")
					}
					Txt {
						anchors { left: icon.right; leftMargin: 12; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
						text: line.modelData.name
						font.pixelSize: 14
					}
					MouseArea { anchors.fill: parent; onClicked: win.launch(line.modelData); onWheel: w => win.move(w.angleDelta.y > 0 ? -1 : 1) }
				}
			}
			Txt {
				visible: win.apps.length === 0
				topPadding: 14; leftPadding: 10
				text: "Nothing matches \"" + win.query + "\""
				color: Theme.muted
			}
		}
	}
}
