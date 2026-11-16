import QtQuick
import Quickshell

Chip {
	id: root

	SystemClock {
		id: clock
		precision: Cfg.clock.seconds ? SystemClock.Seconds : SystemClock.Minutes
	}

	function timeText(d) {
		const h = d.getHours()
		let s = Cfg.clock.hour24 ? String(h).padStart(2, "0") : String(h % 12 || 12)
		s += ":" + String(d.getMinutes()).padStart(2, "0")
		if (Cfg.clock.seconds) s += ":" + String(d.getSeconds()).padStart(2, "0")
		if (Cfg.clock.dateOnBar) s += "   " + Qt.formatDate(d, "ddd d MMM")
		return s
	}

	Txt {
		text: root.timeText(clock.date)
		font.pixelSize: Cfg.bar.textSize
		font.weight: Font.Bold
	}

	glance: Component {
		Txt { text: Qt.formatDate(clock.date, "dddd d MMMM yyyy"); font.weight: Font.DemiBold }
	}
	deep: Component {
		Column {
			spacing: 2
			Toggle { label: "24-hour clock"; checked: Cfg.clock.hour24; onToggled: on => Cfg.clock.hour24 = on }
			Toggle { label: "Show seconds"; checked: Cfg.clock.seconds; onToggled: on => Cfg.clock.seconds = on }
			Toggle { label: "Show date on the bar"; checked: Cfg.clock.dateOnBar; onToggled: on => Cfg.clock.dateOnBar = on }
		}
	}
}
