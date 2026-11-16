import QtQuick

Item {
	id: root

	property real value: 0      // 0 to 1
	signal moved(real to)

	width: parent ? parent.width : 240
	implicitHeight: 18

	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		width: parent.width; height: 6; radius: 3
		color: Theme.line
		Rectangle {
			width: parent.width * Math.max(0, Math.min(1, root.value))
			height: parent.height; radius: 3
			color: Theme.accent
		}
	}
	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		function at(x) { root.moved(Math.max(0, Math.min(1, x / width))) }
		onPressed: m => at(m.x)
		onPositionChanged: m => { if (pressed) at(m.x) }
		onWheel: w => root.moved(Math.max(0, Math.min(1, root.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))))
	}
}
