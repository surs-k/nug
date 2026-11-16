import QtQuick

Chip {
	id: root

	Icon {
		name: Vpn.connected ? "vpn" : "vpnoff"
		color: Vpn.connected ? Theme.good : Theme.warn
		anchors.verticalCenter: parent.verticalCenter
	}

	glance: Component {
		Column {
			spacing: 2
			Txt {
				text: Vpn.connected ? "VPN connected" : Vpn.state === "Connecting" ? "VPN connecting…"
					: Vpn.state === "Blocked" ? "Internet blocked, VPN is off" : Vpn.state === "Unknown" ? "VPN state not known" : "VPN is off"
				font.weight: Font.DemiBold
				color: Vpn.connected ? Theme.fg : Theme.warn
			}
			Txt { width: parent.width; visible: text !== ""; text: Vpn.place; color: Theme.muted }
		}
	}
	deep: Component {
		Column {
			spacing: 4
			KV { visible: Vpn.relay !== ""; k: "Server"; v: Vpn.relay.split(" ")[0] }
			Row {
				spacing: 6
				topPadding: 4
				Btn { primary: !Vpn.connected; text: Vpn.connected ? "Disconnect" : "Connect"; onClicked: Vpn.connected ? Vpn.disconnect() : Vpn.connect() }
				Btn { text: "Open Mullvad"; onClicked: { Ui.run("mullvad-vpn"); root.win.closePopup() } }
			}
		}
	}
}
