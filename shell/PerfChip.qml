import QtQuick

Chip {
	id: root

	Icon {
		visible: Cfg.performance.onBar.length === 0
		name: "perf"
		anchors.verticalCenter: parent.verticalCenter
	}
	Repeater {
		model: Cfg.performance.onBar
		Row {
			required property string modelData
			spacing: 3
			anchors.verticalCenter: parent.verticalCenter
			Icon { name: Perf.find(modelData)?.icon ?? "perf"; color: Theme.accent; size: 13; anchors.verticalCenter: parent.verticalCenter }
			Txt { text: Perf.show(modelData); font.pixelSize: Cfg.bar.textSize; anchors.verticalCenter: parent.verticalCenter }
		}
	}

	glance: Component {
		Column {
			Txt { text: "Performance"; font.weight: Font.DemiBold; bottomPadding: 4 }
			Repeater {
				model: Perf.metrics
				KV { required property var modelData; icon: modelData.icon; k: modelData.name; v: Perf.show(modelData.key) }
			}
		}
	}
	deep: Component {
		Column {
			spacing: 2
			Txt { text: "Show on the bar"; font.weight: Font.DemiBold; bottomPadding: 4 }
			Repeater {
				model: Perf.metrics
				Toggle {
					required property var modelData
					icon: modelData.icon
					label: modelData.name
					checked: Cfg.performance.onBar.indexOf(modelData.key) >= 0
					onToggled: on => {
						const now = Array.from(Cfg.performance.onBar)
						Cfg.performance.onBar = Perf.metrics.map(m => m.key)
							.filter(k => k === modelData.key ? on : now.indexOf(k) >= 0)
					}
				}
			}
		}
	}
}
