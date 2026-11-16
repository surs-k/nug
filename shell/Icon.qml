// A small line icon, drawn from a path so it takes any colour and size.
// To add one: draw it on a 24 by 24 grid and add its SVG path below.

import QtQuick
import QtQuick.Shapes

Item {
	id: root

	property string name
	property color color: Theme.fg
	property real size: 15

	implicitWidth: size
	implicitHeight: size

	readonly property var paths: ({
		tray:  "M5 5h5v5H5zM14 5h5v5h-5zM5 14h5v5H5zM14 14h5v5h-5z",
		perf:  "M4 18a9 9 0 1 1 16 0M12 14l4-5",
		cpu:   "M7 7h10v10H7zM10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4",
		gpu:   "M2 7h20v9H2zM9.5 11.5a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0-5 0M6 16v3M10 16v3",
		ram:   "M3 8h18v7H3zM7 15v3M12 15v3M17 15v3M7 10.5v2M12 10.5v2M17 10.5v2",
		temp:  "M12 3a2 2 0 0 0-2 2v9a4 4 0 1 0 4 0V5a2 2 0 0 0-2-2zM12 10v6",
		pwr:   "M13 3L5 14h6l-1 7 8-11h-6z",
		vol:   "M4 9v6h4l5 4V5L8 9H4zM16 9a4 4 0 0 1 0 6",
		mute:  "M4 9v6h4l5 4V5L8 9H4zM16 9.5l5 5M21 9.5l-5 5",
		net:   "M2 9a15 15 0 0 1 20 0M5.5 12.5a10 10 0 0 1 13 0M9 16a5 5 0 0 1 6 0M12 19.5h.01",
		vpn:   "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4",
		vpnoff:"M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9.5 9.5l5 5M14.5 9.5l-5 5",
		upd:   "M12 4v11M7 11l5 5 5-5M5 20h14",
		bell:  "M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0",
		close: "M6 6l12 12M18 6L6 18",
		gear:  "M12 8.5a3.5 3.5 0 1 0 0 7a3.5 3.5 0 1 0 0-7M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2",
		prev:  "M17 6l-8 6 8 6zM7 6v12",
		next:  "M7 6l8 6-8 6zM17 6v12",
		play:  "M8 5l11 7-11 7z",
		pause: "M8 5v14M16 5v14"
	})

	Shape {
		width: 24
		height: 24
		anchors.centerIn: parent
		scale: root.size / 24
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: root.color
			strokeWidth: 1.9
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap
			joinStyle: ShapePath.RoundJoin
			PathSvg { path: root.paths[root.name] ?? "" }
		}
	}
}
