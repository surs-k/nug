import QtQuick

Rectangle {
	id: root

	property string text
	property bool primary: false
	signal clicked()

	implicitWidth: label.implicitWidth + 20
	implicitHeight: 26
	radius: Math.min(Theme.chipRadius, 13)
	color: primary ? Theme.accent : (area.containsMouse ? Theme.line : Theme.hover)

	Txt {
		id: label
		anchors.centerIn: parent
		text: root.text
		color: root.primary ? Theme.onAccent : Theme.fg
		font.pixelSize: 12
		font.weight: Font.DemiBold
	}
	MouseArea {
		id: area
		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.clicked()
	}
}
