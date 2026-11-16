// Running programs that put an icon in the tray.
//   icon         hover for detail, click to open, right-click for the program's own menu
//   grid button  click to fold the icons away, right-click for the task manager

import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Services.SystemTray

Rectangle {
	id: root

	required property var win
	readonly property var items: SystemTray.items.values
	readonly property var hidden: Array.from(Cfg.tray.hidden)
	readonly property var shown: items.filter(i => hidden.indexOf(i.id) < 0)

	function setHidden(id, hide) {
		const rest = hidden.filter(h => h !== id)
		Cfg.tray.hidden = hide ? rest.concat([id]) : rest
	}

	height: Cfg.bar.height
	width: row.implicitWidth + 12
	radius: Math.min(Theme.chipRadius, height / 2)
	color: Theme.chip
	border.width: Theme.borderWidth
	border.color: Theme.border

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 7

		Repeater {
			model: Cfg.tray.folded ? [] : root.shown
			Item {
				id: it
				required property var modelData
				width: 16; height: 16

				property string hint: ""
				property Component deep: null
				property Component glance: Component {
					Column {
						spacing: 2
						Txt { width: parent.width; text: it.modelData.tooltipTitle || it.modelData.title || it.modelData.id; font.weight: Font.DemiBold }
						Txt { width: parent.width; visible: text !== ""; text: it.modelData.tooltipDescription; color: Theme.muted; wrapMode: Text.Wrap; maximumLineCount: 3 }
						Txt { text: "Click to open · right-click for options"; color: Theme.accent; font.pixelSize: 11 }
					}
				}

				IconImage { anchors.fill: parent; source: it.modelData.icon }
				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
					onEntered: root.win.hoverChip(it)
					onExited: root.win.unhoverChip(it)
					onClicked: m => {
						if (m.button === Qt.LeftButton && !it.modelData.onlyMenu) it.modelData.activate()
						else if (m.button === Qt.MiddleButton) it.modelData.secondaryActivate()
						else if (it.modelData.hasMenu) {
							root.win.closePopup()
							const p = it.mapToItem(null, 0, it.height + 8)
							it.modelData.display(root.win, p.x, p.y)
						}
					}
				}
			}
		}

		Item {
			id: fold
			width: 16; height: 16

			property string hint: "Click to fold · right-click for task manager"
			property Component glance: Component {
				Column {
					Txt { text: "Tray"; font.weight: Font.DemiBold; bottomPadding: 4 }
					KV { k: "Showing"; v: root.shown.length + (root.shown.length === 1 ? " program" : " programs") }
					KV { k: "Hidden"; v: String(root.items.length - root.shown.length) }
				}
			}
			property Component deep: Component {
				Column {
					spacing: 4
					Txt { text: "Task manager"; font.weight: Font.DemiBold }
					Txt { text: "In the tray"; color: Theme.muted; font.pixelSize: 11 }
					Repeater {
						model: root.items
						Item {
							id: trow
							required property var modelData
							readonly property bool isHidden: root.hidden.indexOf(modelData.id) >= 0
							width: parent.width; height: 28
							Txt { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 70; text: trow.modelData.title || trow.modelData.id; color: trow.isHidden ? Theme.muted : Theme.fg }
							Btn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: trow.isHidden ? "Show" : "Hide"; onClicked: root.setHidden(trow.modelData.id, !trow.isHidden) }
						}
					}
					Txt { text: "Open windows"; color: Theme.muted; font.pixelSize: 11; topPadding: 4 }
					Repeater {
						model: Hyprland.toplevels.values
						Item {
							id: wrow
							required property var modelData
							width: parent.width; height: 28
							Txt { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 70; text: wrow.modelData.title }
							Btn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Close"; onClicked: wrow.modelData.wayland?.close() }
						}
					}
				}
			}

			Icon { anchors.centerIn: parent; name: "tray"; color: Cfg.tray.folded ? Theme.accent : Theme.fg }
			MouseArea {
				anchors.fill: parent
				hoverEnabled: true
				acceptedButtons: Qt.LeftButton | Qt.RightButton
				onEntered: root.win.hoverChip(fold)
				onExited: root.win.unhoverChip(fold)
				onClicked: m => {
					if (m.button === Qt.RightButton) root.win.pinChip(fold)
					else Cfg.tray.folded = !Cfg.tray.folded
				}
			}
		}
	}
}
