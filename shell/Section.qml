// A fold-out block in the Settings window: a one-line summary until you open it.

import QtQuick

Column {
	id: root

	property string title
	property string summary
	property bool open: false
	default property alias content: inner.data

	width: parent ? parent.width : 400

	Rectangle {
		width: parent.width
		height: 50
		radius: Math.min(Theme.chipRadius, 12)
		color: head.containsMouse || root.open ? Theme.hover : "transparent"
		Column {
			x: 12
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width - 50
			Txt { text: root.title; font.weight: Font.DemiBold; font.pixelSize: 14 }
			Txt { width: parent.width; text: root.summary; color: Theme.muted; font.pixelSize: 12 }
		}
		Txt { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: root.open ? "−" : "+"; font.pixelSize: 18; color: Theme.muted }
		MouseArea { id: head; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.open = !root.open }
	}
	Column {
		id: inner
		visible: root.open
		x: 12
		width: parent.width - 24
		spacing: 6
		topPadding: 8
		bottomPadding: 14
	}
}
