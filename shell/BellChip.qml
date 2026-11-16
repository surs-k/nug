// Only on the bar when something is waiting.

import QtQuick

Chip {
	id: root

	visible: Notifs.waiting > 0

	Icon { name: "bell"; color: Notifs.important > 0 ? Theme.warn : Theme.fg; anchors.verticalCenter: parent.verticalCenter }
	Txt { text: Notifs.waiting; font.pixelSize: Cfg.bar.textSize; anchors.verticalCenter: parent.verticalCenter }

	glance: Component {
		Column {
			Txt { text: "Notifications"; font.weight: Font.DemiBold; bottomPadding: 4 }
			KV { k: "Important"; v: String(Notifs.important); vColor: Notifs.important > 0 ? Theme.warn : Theme.muted }
			KV { k: "Other"; v: String(Notifs.waiting - Notifs.important) }
			KV { k: "Silenced"; v: String(Notifs.all.length - Notifs.waiting) }
		}
	}
	deep: Component {
		Column {
			spacing: 4
			Repeater {
				model: Notifs.all.slice(-8).reverse()
				Item {
					id: nrow
					required property var modelData
					width: parent.width; height: 36
					Column {
						width: parent.width - 26
						anchors.verticalCenter: parent.verticalCenter
						Txt { width: parent.width; text: nrow.modelData.summary; font.weight: Font.DemiBold; color: Notifs.level(nrow.modelData) === "silent" ? Theme.muted : Theme.fg }
						Txt { width: parent.width; text: nrow.modelData.appName; color: Theme.muted; font.pixelSize: 11 }
					}
					Icon {
						anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
						name: "close"; size: 13; color: Theme.muted
						MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor; onClicked: nrow.modelData.dismiss() }
					}
				}
			}
			Toggle { label: "Mute unimportant pop-ups"; checked: Cfg.notifications.muteUnimportant; onToggled: on => Cfg.notifications.muteUnimportant = on }
			Btn { text: "Clear all"; onClicked: { Notifs.clear(); root.win.closePopup() } }
		}
	}
}
