import QtQuick

Item {
	id: root

	property string label
	property string icon: ""
	property bool checked: false
	signal toggled(bool on)

	width: parent ? parent.width : 240
	implicitHeight: 26

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 8
		Icon { visible: root.icon !== ""; name: root.icon; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
		Txt { text: root.label; anchors.verticalCenter: parent.verticalCenter }
	}
	Rectangle {
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: 34; height: 18; radius: 9
		color: root.checked ? Theme.accent : Theme.line
		Rectangle {
			width: 14; height: 14; radius: 7; y: 2
			x: root.checked ? 18 : 2
			color: root.checked ? Theme.onAccent : Theme.fg
			Behavior on x { NumberAnimation { duration: 120 } }
		}
	}
	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		onClicked: root.toggled(!root.checked)
	}
}
