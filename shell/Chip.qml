// One pill on the bar.
//   glance  what shows when the pointer rests on it
//   deep    what is added underneath when it is clicked
// Anything placed inside a Chip is laid out in a row.

import QtQuick

Rectangle {
	id: chip

	required property var win
	property Component glance: null
	property Component deep: null
	property string hint: "Click for more"
	property bool opensOnClick: true
	default property alias content: row.data

	signal pressed(var mouse)
	signal scrolled(bool up)

	readonly property bool open: win.popupChip === chip

	height: Cfg.bar.height
	width: row.implicitWidth + 14
	radius: Math.min(Theme.chipRadius, height / 2)
	color: open ? Theme.panelSolid : Theme.chip
	border.width: Theme.borderWidth
	border.color: open || area.containsMouse ? Theme.accent : Theme.border

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 5
	}
	MouseArea {
		id: area
		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
		onEntered: chip.win.hoverChip(chip)
		onExited: chip.win.unhoverChip(chip)
		onClicked: m => {
			chip.pressed(m)
			if (chip.opensOnClick && m.button === Qt.LeftButton) chip.win.pinChip(chip)
		}
		onWheel: w => chip.scrolled(w.angleDelta.y > 0)
	}
}
