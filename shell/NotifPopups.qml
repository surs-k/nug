// Pop-up notifications, top right of the screen you are on.
//   click        put it away, it stays in the bell on the bar
//   right-click  dismiss it for good

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland

PanelWindow {
	id: win

	visible: Notifs.popups.length > 0
	screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
	anchors { top: true; right: true }
	margins { top: 6; right: 10 }
	exclusiveZone: 0
	color: "transparent"
	implicitWidth: 380
	implicitHeight: Math.max(1, col.implicitHeight)
	WlrLayershell.namespace: "dream-notifications"
	WlrLayershell.layer: WlrLayer.Overlay

	Column {
		id: col
		width: parent.width
		spacing: 8

		Repeater {
			model: Notifs.popups
			Rectangle {
				id: card
				required property var modelData
				readonly property bool important: Notifs.level(modelData) === "important"
				readonly property string picture: modelData.image !== "" ? modelData.image
					: modelData.appIcon !== "" ? Quickshell.iconPath(modelData.appIcon, true) : ""

				width: col.width
				height: inner.implicitHeight + 24
				color: Theme.panel
				radius: Theme.radius
				border.width: Theme.borderWidth
				border.color: important ? Theme.warn : Theme.border

				Timer {
					running: true
					interval: (card.important ? 3 : 1) * Cfg.notifications.seconds * 1000
					onTriggered: Notifs.hide(card.modelData)
				}
				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: m => m.button === Qt.RightButton ? card.modelData.dismiss() : Notifs.hide(card.modelData)
				}

				Row {
					id: inner
					x: 14; y: 12
					width: parent.width - 28
					spacing: 12

					Rectangle {
						width: 36; height: 36
						radius: Math.min(Theme.chipRadius, 18)
						color: card.important ? Theme.warn : Theme.hover
						IconImage { visible: card.picture !== ""; anchors.centerIn: parent; implicitSize: 24; source: card.picture }
						Icon { visible: card.picture === ""; anchors.centerIn: parent; name: "bell"; size: 18; color: card.important ? Theme.onAccent : Theme.fg }
					}
					Column {
						width: inner.width - 48
						spacing: 2
						Item {
							width: parent.width; height: 15
							Txt { text: card.modelData.appName || "Unknown program"; color: Theme.muted; font.pixelSize: 11 }
							Txt { visible: card.important; anchors.right: parent.right; text: "IMPORTANT"; color: Theme.warn; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8 }
						}
						Txt { width: parent.width; text: card.modelData.summary; font.weight: Font.DemiBold; wrapMode: Text.Wrap; maximumLineCount: 2 }
						Txt { width: parent.width; visible: text !== ""; text: card.modelData.body; color: Theme.muted; wrapMode: Text.Wrap; maximumLineCount: 3 }
						Row {
							visible: card.modelData.actions.length > 0
							spacing: 6
							topPadding: 6
							Repeater {
								model: card.modelData.actions
								Btn { required property var modelData; required property int index; primary: index === 0; text: modelData.text; onClicked: modelData.invoke() }
							}
						}
					}
				}
			}
		}
	}
}
