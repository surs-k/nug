// Wired, Wi-Fi and Bluetooth in one place.

import QtQuick

Chip {
	id: root

	Icon { name: "net"; color: Net.online ? Theme.fg : Theme.warn; anchors.verticalCenter: parent.verticalCenter }

	readonly property string btText: !Net.btOn ? "Off"
		: Net.btDevices.length === 0 ? "No devices"
		: Net.btDevices.map(d => d.name).join(", ")

	glance: Component {
		Column {
			Txt { text: "Connections"; font.weight: Font.DemiBold; bottomPadding: 4 }
			KV { k: "Wired"; v: Net.wired ? "Connected" : "Not connected"; vColor: Net.wired ? Theme.good : Theme.muted }
			KV { visible: Net.wifi === "connected"; k: "Wi-Fi"; v: Net.wifiName }
			KV { visible: Net.btDevices.length > 0; k: "Bluetooth"; v: root.btText }
		}
	}
	deep: Component {
		Column {
			spacing: 4
			KV { k: "Wi-Fi"; v: Net.wifi === "connected" ? Net.wifiName : Net.wifi === "off" ? "Off" : "Not connected" }
			KV { k: "Bluetooth"; v: root.btText }
			Row {
				spacing: 6
				topPadding: 4
				Btn { text: "Network settings"; onClicked: { Ui.run(Cfg.apps.network); root.win.closePopup() } }
				Btn { text: "Bluetooth devices"; onClicked: { Ui.run(Cfg.apps.bluetooth); root.win.closePopup() } }
			}
		}
	}
}
