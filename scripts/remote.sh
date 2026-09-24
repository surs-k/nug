#!/usr/bin/env bash

	# Ai - remote
	#      Sunshine runs only when you ask for it, never at login
	#      on makes the virtual screen first, then starts Sunshine, because
	#      Sunshine reads the screen name once when it starts
	#      off stops Sunshine, then removes the virtual screen, so nothing is
	#      left for the mouse or a window to wander into
	#      installed by 80-remote as /usr/local/bin/remote

set -euo pipefail

SCREEN="SUNSHINE"


#    Usage


usage() {
	cat << 'USAGEEOF'

  remote on       make the virtual screen, start Sunshine
  remote off      stop Sunshine, remove the virtual screen
  remote status   say whether it is running

USAGEEOF
}


#    Helpers


	# Ai - over ssh there is no Hyprland variable, so the newest session is used
if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
	SIG="$(ls -t "/run/user/$(id -u)/hypr" 2>/dev/null | head -n 1 || true)"
	[[ -n "$SIG" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
fi

	# Ai - upstream renamed the unit, whichever exists is used
unit() {
	local u
	for u in app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
		if systemctl --user cat "$u" > /dev/null 2>&1; then
			printf '%s' "$u"
			return 0
		fi
	done
	return 1
}

screen_up() {
	local mons
	mons="$(hyprctl monitors all 2>/dev/null || true)"
	[[ "$mons" == *"$SCREEN"* ]]
}


#    Main


case "${1:-status}" in
	on|up|start)
		U="$(unit)" || { printf 'Sunshine is not installed, run: rebuild --only 80-remote\n' >&2; exit 1; }
		screen_up || hyprctl output create headless "$SCREEN" > /dev/null
		systemctl --user start "$U"
		printf 'Sunshine is on, connect from the laptop with Moonlight\n' ;;

	off|down|stop)
		U="$(unit)" || { printf 'Sunshine is not installed\n'; exit 0; }
		systemctl --user stop "$U" || true
		if screen_up; then
			hyprctl output remove "$SCREEN" > /dev/null || true
		fi
		printf 'Sunshine is off\n' ;;

	status)
		U="$(unit)" || { printf 'Sunshine is not installed\n'; exit 0; }
		if systemctl --user is-active --quiet "$U"; then
			printf 'Sunshine is on\n'
		else
			printf 'Sunshine is off, start it with: remote on\n'
		fi ;;

	-h|--help|help)
		usage ;;

	*)
		printf 'unknown command: %s\n' "$1" >&2
		usage >&2
		exit 2 ;;
esac
