// Sound. Scroll on the icon to change volume, middle-click to mute.
// Media controls live here, under the click, never on the bar.

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris

Chip {
	id: root

	readonly property var sink: Pipewire.defaultAudioSink
	readonly property real vol: sink?.audio?.volume ?? 0
	readonly property bool muted: sink?.audio?.muted ?? false
	readonly property var streams: Pipewire.nodes.values.filter(n => n.isStream && n.audio !== null)
	readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? Mpris.players.values[0] ?? null

	function setVol(to) { if (sink?.audio) sink.audio.volume = Math.max(0, Math.min(1, to)) }
	function appName(n) { return n.properties["application.name"] ?? n.description ?? n.name }

	PwObjectTracker { objects: [root.sink].concat(root.streams).filter(o => o) }

	Icon { name: root.muted ? "mute" : "vol"; color: root.muted ? Theme.warn : Theme.fg; anchors.verticalCenter: parent.verticalCenter }

	onScrolled: up => setVol(vol + (up ? 0.05 : -0.05))
	onPressed: m => { if (m.button === Qt.MiddleButton && sink?.audio) sink.audio.muted = !muted }

	glance: Component {
		Column {
			spacing: 6
			Txt { width: parent.width; text: (root.sink?.description || "Sound") + " · " + (root.muted ? "muted" : Math.round(root.vol * 100) + "%"); font.weight: Font.DemiBold }
			Slider { value: root.vol; onMoved: to => root.setVol(to) }
		}
	}
	deep: Component {
		Column {
			spacing: 4
			Toggle { label: "Mute"; checked: root.muted; onToggled: on => { if (root.sink?.audio) root.sink.audio.muted = on } }
			Repeater {
				model: root.streams
				Column {
					id: srow
					required property var modelData
					width: parent.width
					spacing: 2
					KV { k: root.appName(srow.modelData); v: Math.round((srow.modelData.audio?.volume ?? 0) * 100) + "%" }
					Slider { value: srow.modelData.audio?.volume ?? 0; onMoved: to => { if (srow.modelData.audio) srow.modelData.audio.volume = to } }
				}
			}
			Item {
				visible: root.player !== null
				width: parent.width; height: 34
				Txt { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 90; text: root.player?.trackTitle || root.player?.identity || ""; color: Theme.muted }
				Row {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					spacing: 10
					Repeater {
						model: [
							{ icon: "prev", act: () => root.player.previous() },
							{ icon: root.player?.isPlaying ? "pause" : "play", act: () => root.player.togglePlaying() },
							{ icon: "next", act: () => root.player.next() }
						]
						Icon {
							required property var modelData
							name: modelData.icon; size: 16
							MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.modelData.act() }
						}
					}
				}
			}
			Btn { text: "Sound settings"; onClicked: { Ui.run(Cfg.apps.audio); root.win.closePopup() } }
		}
	}
}
