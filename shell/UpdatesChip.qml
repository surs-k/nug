// Shows how many updates are waiting. Nothing installs until you press the button.

import QtQuick

Chip {
	id: root

	Icon { name: "upd"; color: Updates.count > 0 ? Theme.accent : Theme.muted; anchors.verticalCenter: parent.verticalCenter }
	Txt { visible: Updates.count > 0; text: Updates.count; font.pixelSize: Cfg.bar.textSize; anchors.verticalCenter: parent.verticalCenter }

	glance: Component {
		Column {
			spacing: 2
			Txt { text: Updates.checking ? "Checking for updates…" : Updates.count === 0 ? "Up to date" : Updates.count + (Updates.count === 1 ? " update waiting" : " updates waiting"); font.weight: Font.DemiBold }
			Txt { width: parent.width; text: "Nothing installs until you start it."; color: Theme.muted }
		}
	}
	deep: Component {
		Column {
			spacing: 3
			Repeater {
				model: Updates.list.slice(0, 8)
				Txt { required property string modelData; width: parent.width; text: modelData; color: Theme.muted }
			}
			Txt { visible: Updates.count > 8; text: "and " + (Updates.count - 8) + " more"; color: Theme.muted }
			KV { k: "Snapshot first"; v: "Yes, by itself" }
			Row {
				spacing: 6
				topPadding: 4
				Btn { primary: true; visible: Updates.count > 0; text: "Update now"; onClicked: { Ui.inTerminal(Cfg.apps.update); root.win.closePopup() } }
				Btn { text: "Check again"; onClicked: Updates.check() }
			}
		}
	}
}
