// The bar: one per screen. See-through, with a background only behind each piece.
//   left    time, performance
//   middle  workspaces
//   right   tray, sound, connections, VPN, updates, notifications
// To reorder or remove a piece, move or delete its line below.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

PanelWindow {
	id: win

	required property var modelData
	screen: modelData

	anchors { top: true; left: true; right: true }
	implicitHeight: Cfg.bar.height + Cfg.bar.gap
	color: "transparent"
	WlrLayershell.namespace: "dream-bar"

	// ---- hover and click panels -------------------------------------------
	property Item popupChip: null      // the piece whose panel is showing
	property Item pendingChip: null    // the piece under the pointer
	property bool pinned: false        // true once clicked, panel then stays
	property real popX: 0
	property real popW: 0

	function hoverChip(c) {
		pendingChip = c
		leaveTimer.stop()
		if (pinned) return
		if (popupChip) popupChip = (c.glance || c.deep) ? c : null
		else openTimer.restart()
	}
	function unhoverChip(c) {
		if (pendingChip === c) pendingChip = null
		openTimer.stop()
		if (!pinned) leaveTimer.restart()
	}
	function pinChip(c) {
		if (popupChip === c && pinned) closePopup()
		else { popupChip = c; pinned = true }
	}
	function closePopup() { popupChip = null; pinned = false }

	onPopupChipChanged: {
		if (!popupChip) return
		popX = popupChip.mapToItem(null, 0, 0).x
		popW = popupChip.width
		Qt.callLater(() => pop.anchor.updateAnchor())
	}

	Timer { id: openTimer; interval: 280; onTriggered: if (win.pendingChip && (win.pendingChip.glance || win.pendingChip.deep)) win.popupChip = win.pendingChip }
	Timer { id: leaveTimer; interval: 260; onTriggered: if (!win.pinned && !popHover.hovered && !win.pendingChip) win.popupChip = null }

	HyprlandFocusGrab {
		windows: [win, pop]
		active: win.pinned
		onCleared: win.closePopup()
	}

	PopupWindow {
		id: pop
		anchor.window: win
		anchor.rect.x: win.popX
		anchor.rect.y: win.implicitHeight + 4
		anchor.rect.width: Math.max(1, win.popW)
		anchor.rect.height: 1
		anchor.edges: Edges.Bottom | Edges.Left
		anchor.gravity: Edges.Bottom | Edges.Right
		visible: win.popupChip !== null
		color: "transparent"
		implicitWidth: panel.width
		implicitHeight: panel.height

		Rectangle {
			id: panel
			width: body.width + 28
			height: body.height + 24
			color: Theme.panel
			radius: Theme.radius
			border.width: Theme.borderWidth
			border.color: Theme.border

			HoverHandler { id: popHover; onHoveredChanged: if (!hovered) leaveTimer.restart() }

			Column {
				id: body
				x: 14; y: 12
				width: 260
				spacing: 8

				Loader { width: parent.width; sourceComponent: win.popupChip?.glance ?? null; visible: item !== null }
				Txt {
					visible: !win.pinned && !!win.popupChip?.deep && text !== ""
					text: win.popupChip?.hint ?? ""
					color: Theme.accent
					font.pixelSize: 11
				}
				Rectangle { visible: deepLoader.visible && !!win.popupChip?.glance; width: parent.width; height: 1; color: Theme.line }
				Loader {
					id: deepLoader
					width: parent.width
					active: win.pinned && !!win.popupChip?.deep
					visible: active
					sourceComponent: win.popupChip?.deep ?? null
				}
			}
		}
	}

	// ---- the pieces ---------------------------------------------------------
	Item {
		anchors { fill: parent; topMargin: Cfg.bar.gap; leftMargin: 8; rightMargin: 8 }

		Row {
			id: leftRow
			anchors.left: parent.left
			spacing: 4
			ClockChip { win: win }
			PerfChip { win: win }
		}

		Workspaces { anchors.horizontalCenter: parent.horizontalCenter; win: win }

		Row {
			id: rightRow
			anchors.right: parent.right
			spacing: 4
			TrayChip { win: win }
			AudioChip { win: win }
			NetChip { win: win }
			VpnChip { win: win }
			UpdatesChip { win: win }
			BellChip { win: win }
		}
	}

	// right-click an empty part of the bar for Settings
	MouseArea {
		anchors.fill: parent
		z: -1
		acceptedButtons: Qt.RightButton
		onClicked: Ui.settingsOpen = true
	}
}
