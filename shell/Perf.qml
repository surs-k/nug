pragma Singleton

// CPU, memory and graphics card readings.
// A reading of -1 means "not known", and shows as a dash.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
	id: root

	property int cpu: -1
	property int ram: -1
	property int cputemp: -1
	property int gpu: -1
	property int gputemp: -1
	property int gpupower: -1

	// the order here is the order on the bar
	readonly property var metrics: [
		{ key: "cpu",      name: "Processor",            icon: "cpu",  unit: "%" },
		{ key: "gpu",      name: "Graphics card",        icon: "gpu",  unit: "%" },
		{ key: "ram",      name: "Memory",               icon: "ram",  unit: "%" },
		{ key: "cputemp",  name: "Processor heat",       icon: "temp", unit: "°" },
		{ key: "gputemp",  name: "Graphics card heat",   icon: "temp", unit: "°" },
		{ key: "gpupower", name: "Graphics card power",  icon: "pwr",  unit: " W" }
	]

	function find(key) { return metrics.find(m => m.key === key) }
	function show(key) {
		const m = find(key)
		if (!m) return "?"
		return root[key] < 0 ? "–" : root[key] + m.unit
	}

	Process {
		running: true
		command: ["bash", Quickshell.shellDir + "/perf.sh", String(Cfg.performance.everySeconds)]
		stdout: SplitParser {
			onRead: line => {
				const p = line.split(" ")
				root.cpu = +p[0]; root.ram = +p[1]; root.cputemp = +p[2]
			}
		}
	}

	// one long-lived nvidia-smi, it prints a line every few seconds by itself
	Process {
		running: true
		command: ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,power.draw",
			"--format=csv,noheader,nounits", "-l", String(Cfg.performance.everySeconds)]
		stdout: SplitParser {
			onRead: line => {
				const p = line.split(",")
				if (p.length < 3) return
				root.gpu = Math.round(+p[0]); root.gputemp = Math.round(+p[1]); root.gpupower = Math.round(+p[2])
			}
		}
	}
}
