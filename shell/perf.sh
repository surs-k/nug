#!/usr/bin/env bash
# Prints "cpu% memory% cpu-temperature" every N seconds, for the bar.
# Reads straight from the kernel, so each round starts no other program.

every="${1:-2}"

hw=""
for h in /sys/class/hwmon/hwmon*; do
	case "$(< "$h/name")" in coretemp|k10temp|zenpower) hw="$h" ;; esac
done

pt=0 pi=0
while :; do
	read -r _ u n s i w q sq st _ < /proc/stat
	t=$((u + n + s + i + w + q + sq + st)) id=$((i + w))
	dt=$((t - pt)) di=$((id - pi)) pt=$t pi=$id
	cpu=$((dt > 0 ? (100 * (dt - di) + dt / 2) / dt : 0))

	while read -r k v _; do
		case "$k" in MemTotal:) mt=$v ;; MemAvailable:) ma=$v; break ;; esac
	done < /proc/meminfo
	ram=$(((100 * (mt - ma) + mt / 2) / mt))

	temp=-1
	[[ -n "$hw" && -r "$hw/temp1_input" ]] && temp=$(($(< "$hw/temp1_input") / 1000))

	echo "$cpu $ram $temp"
	sleep "$every"
done
