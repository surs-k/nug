#!/usr/bin/env bash

# Ai - changes: the app that shows what is wrong and what changed, for this
#      install and any other project, and checks every hour

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Changes" "the Changes app and the hourly problem check"


step "App"

pac python-pyqt6 wl-clipboard libnotify
run "Changes in the launcher" python3 "$SCRIPTS/changes.py" --install


step "Check"

if has changes; then ok "Changes installed, SUPER + N opens it"; else warn "the changes command is missing"; fi
soft "first problem check" changes --check
