// The open workspaces, in one shared pill. Empty ones are not shown.
// Filled = showing on this screen. Coloured number = showing on another screen.

import QtQuick
import Quickshell.Hyprland

Rectangle {
	id: root

	required property var win
	readonly property var mon: Hyprland.monitorFor(win.screen)
	readonly property var list: Hyprland.workspaces.values.filter(w => w.id > 0).sort((a, b) => a.id - b.id)

	height: Cfg.bar.height
	width: row.implicitWidth + 6
	radius: Math.min(Theme.chipRadius, height / 2)
	color: Theme.chip
	border.width: Theme.borderWidth
	border.color: Theme.border

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 2
		Repeater {
			model: root.list
			Rectangle {
				id: cell
				required property var modelData
				readonly property bool here: root.mon?.activeWorkspace === modelData
				width: Math.max(22, label.implicitWidth + 10)
				height: root.height - 6
				radius: Math.min(Theme.chipRadius, height / 2)
				color: here ? Theme.accent : (area.containsMouse ? Theme.hover : "transparent")
				Txt {
					id: label
					anchors.centerIn: parent
					text: cell.modelData.name
					font.pixelSize: Cfg.bar.textSize
					font.weight: cell.here ? Font.Bold : Font.Normal
					color: cell.here ? Theme.onAccent : (cell.modelData.active ? Theme.accent : Theme.muted)
				}
				MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; onClicked: cell.modelData.activate() }
			}
		}
	}
}
