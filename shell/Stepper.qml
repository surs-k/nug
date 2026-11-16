import QtQuick

Item {
	id: root

	property string label
	property int value
	property int from: 0
	property int to: 100
	property string unit: ""
	signal changed(int to)

	width: parent ? parent.width : 240
	implicitHeight: 30

	Txt { text: root.label; anchors.verticalCenter: parent.verticalCenter }
	Row {
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		spacing: 8
		Btn { text: "−"; onClicked: if (root.value > root.from) root.changed(root.value - 1) }
		Txt { width: 54; horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter; text: root.value + root.unit }
		Btn { text: "+"; onClicked: if (root.value < root.to) root.changed(root.value + 1) }
	}
}
