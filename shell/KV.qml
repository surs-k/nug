// One line: a name on the left, its value on the right.

import QtQuick

Item {
	id: root

	property string k
	property string v
	property string icon: ""
	property color vColor: Theme.muted

	width: parent ? parent.width : 240
	implicitHeight: 22

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 8
		Icon { visible: root.icon !== ""; name: root.icon; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
		Txt { text: root.k; anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, root.width - val.implicitWidth - 40) }
	}
	Txt {
		id: val
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		text: root.v
		color: root.vColor
	}
}
