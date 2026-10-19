#!/usr/bin/env bash

	# Ai - changes
	#      every change to the install, newest first, one line each
	#      pick one and its exact lines open, red is removed, green is added
	#      changes              the v2 changes
	#      changes v1           the v1 changes
	#      changes --install    put Changes in the app launcher

set -uo pipefail

REPO="${REBUILD_REPO:-$HOME/rebuild}"
BRANCH="${1:-v2}"
COMPARE="Compare v1 with $BRANCH"


#    Install

	# Ai - a launcher entry, so it opens with a click like any other app
if [[ "$BRANCH" == --install ]]; then
	mkdir -p "$HOME/.local/share/applications"
	cat > "$HOME/.local/share/applications/changes.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Changes
Comment=What changed in the install, and the exact lines
Exec=changes
Icon=document-open-recent
Terminal=false
EOF
	printf 'Changes is in the app launcher\n'
	exit 0
fi


#    Fetch

	# Ai - quietly, an offline PC still shows what it fetched last time
git -C "$REPO" fetch -q origin v1 "$BRANCH" 2> /dev/null || true

REF="origin/$BRANCH"

if ! git -C "$REPO" rev-parse -q --verify "$REF" > /dev/null; then
	printf 'no branch %s in %s\n' "$BRANCH" "$REPO" >&2
	exit 1
fi


#    List

list() {
	printf '%s\n' "$COMPARE"
		# Ai - v2 lists only what changed since v1, v1 lists its whole history
	local range="$REF"
	[[ "$BRANCH" == v1 ]] || range="origin/v1..$REF"
	git -C "$REPO" log --date=short --format='%h  %ad  %s' "$range"
}

if [[ "${CHANGES_LIST:-}" == 1 ]]; then
	list
	exit 0
fi


#    Pick

	# Ai - rofi on the PC, fuzzel on the laptop, the terminal when neither is there
	#      each one takes a mouse click as well as Enter
pick() {
	if command -v rofi > /dev/null && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		rofi -dmenu -i -no-custom -p Changes
	elif command -v fuzzel > /dev/null && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		fuzzel --dmenu --prompt 'Changes  '
	elif command -v fzf > /dev/null; then
		fzf --prompt 'Changes  ' --no-sort
	else
		head -n 30 > /dev/tty
		return 1
	fi
}

CHOICE="$(list | pick)" || exit 0
[[ -n "$CHOICE" ]] || exit 0


#    Show

if [[ "$CHOICE" == "$COMPARE" ]]; then
	CMD=(git -C "$REPO" diff -M --stat --patch --color=always origin/v1 "$REF")
else
	CMD=(git -C "$REPO" show -M --stat --patch --color=always "${CHOICE%% *}")
fi

	# Ai - its own window when opened from the launcher, q closes it
if [[ -t 1 ]]; then
	"${CMD[@]}" | less -R
elif command -v kitty > /dev/null; then
	kitty --title Change sh -c "$(printf '%q ' "${CMD[@]}") | less -R"
else
	"${CMD[@]}"
fi
