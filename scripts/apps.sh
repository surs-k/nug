#!/usr/bin/env bash

# Ai - apps, run as `rebuild apps`
#      rebuild apps               every app, on or off, and whether it is here
#      rebuild apps on NAME ...   turn apps on, they install with the next rebuild apps install
#      rebuild apps off NAME ...  turn apps off, they stay installed until you remove them
#      rebuild apps install       install every app that is on, and set its key
#      the list itself is config/apps.list, a new app is one new line there

STEPS=2
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

CATALOG="$CONF/apps.list"
NUG="$HOME/.config/nug"


#    Catalog

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

	# Ai - one line per app, name|default|key|from|packages|command|what, trimmed
rows() {
	local n d k f p c w
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CATALOG" | while IFS='|' read -r n d k f p c w; do
		printf '%s|%s|%s|%s|%s|%s|%s\n' "$(trim "$n")" "$(trim "$d")" "$(trim "$k")" "$(trim "$f")" \
			"$(trim "$p")" "$(trim "$c")" "$(trim "$w")"
	done
}

	# Ai - read once, a pipe into grep -q would close early and count as failing
ROWS="$(rows)"

state_of() { choice "app_$1" "$2"; }

here() {
	local from=$1 p
	for p in $2; do
		if [[ "$from" == flat ]]; then
			flatpak info "$p" > /dev/null 2>&1 && return 0
		else
			installed "$p" && return 0
		fi
	done
	return 1
}


#    List

list() {
	local n d k f p c w s mark
	printf '\n  %snug %s%s  ·  apps\n\n' "$C_B" "$NUG_VERSION" "$C_0"
	while IFS='|' read -r n d k f p c w; do
		s="$(state_of "$n" "$d")"
		if here "$f" "$p"; then mark="${C_GOOD}here${C_0}"; else mark="${C_DIM}  - ${C_0}"; fi
		if [[ "$s" == on ]]; then s="${C_B}on ${C_0}"; else s="${C_DIM}off${C_0}"; fi
		printf '    %s  %s  %-16s %s%-3s%s %s%s%s\n' "$s" "$mark" "$n" "$C_DIM" "$k" "$C_0" "$C_DIM" "$w" "$C_0"
	done <<< "$ROWS"
	printf '\n    %srebuild apps on NAME, then  rebuild apps install%s\n\n' "$C_DIM" "$C_0"
}


#    Switch

switch() {
	local to=$1 n
	shift
	(( $# )) || die "name at least one app, see: rebuild apps"
	for n in "$@"; do
		grep -q "^$n|" <<< "$ROWS" || die "no app called $n, see: rebuild apps"
		set_choice "app_$n" "$to"
		ok "$n is $to"
	done
	if [[ "$to" == on ]]; then
		dim "Install it now with:  rebuild apps install"
	else
		dim "It stays installed and loses its key. To remove it: sudo pacman -Rns NAME, or flatpak uninstall"
	fi
}


#    Install

	# Ai - the few apps that need more than a package
before() {
	case "$1" in
		mullvad-browser)
			# Ai - signed by the Tor Browser developers, who rotate the key, so
			#      the current one is fetched from them first
			soft "Mullvad Browser signing key" gpg --auto-key-locate nodefault,wkd \
				--locate-keys torbrowser@torproject.org ;;
	esac
	return 0
}

after() {
	case "$1" in
		brightness)
			# Ai - the screens are dimmed over DDC/CI, through the kernel's i2c
			#      module, your hours are in ~/.config/wluma/config.toml
			pac ddcutil
			any "ddcutil-service" ddcutil-service || true
			put /etc/modules-load.d/i2c-dev.conf <<< "i2c-dev"
			soft "screen control module" $SUDO modprobe i2c-dev
			if [[ ! -f "$HOME/.config/wluma/config.toml" ]]; then
				put_mine "$HOME/.config/wluma/config.toml" < "$CONF/wluma.toml"
			fi
			soft "brightness at login" systemctl --user enable wluma.service ;;
	esac
	return 0
}

install_all() {
	local n d k f p c w lua="" conf="" keys=""
	title "Apps" "install what is on, and give each its key"

	step "Install"
	if grep -q '|flat|' <<< "$ROWS"; then
		has flatpak || pac flatpak
		soft "Flathub" flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	fi
	while IFS='|' read -r n d k f p c w; do
		[[ "$(state_of "$n" "$d")" == on ]] || continue
		if here "$f" "$p"; then
			ok "$n already here"
		else
			before "$n"
			if [[ "$f" == flat ]]; then
				# shellcheck disable=SC2086
				soft "install $n" flatpak install --user -y --noninteractive flathub $p
			else
				# shellcheck disable=SC2086
				any "$n" $p || true
			fi
		fi
		if here "$f" "$p"; then after "$n"; fi
	done <<< "$ROWS"

	step "Keys"
	while IFS='|' read -r n d k f p c w; do
		[[ -n "$k" && "$(state_of "$n" "$d")" == on ]] || continue
		here "$f" "$p" || continue
		lua+="hl.unbind(\"SUPER + $k\")"$'\n'
		lua+="hl.bind(\"SUPER + $k\", hl.dsp.exec_cmd(\"$c\"), { description = \"[nug] $n\" })"$'\n'
		conf+="unbind = SUPER, $k"$'\n'"bind = SUPER, $k, exec, $c"$'\n'
		keys+="$(printf 'SUPER + %-14s %s' "$k" "$w")"$'\n'
	done <<< "$ROWS"
	if (( DRY == 0 )); then
		mkdir -p "$NUG"
		printf -- '-- Ai - your app keys, from config/apps.list\n%s' "$lua" > "$NUG/apps.lua"
		printf '# Ai - your app keys, from config/apps.list\n%s' "$conf" > "$NUG/apps.conf"
		printf '%s' "$keys" > "$NUG/apps-keys.txt"
	fi
	run "app keys" bash "$SCRIPTS/hypr.sh"
}


case "${1:-}" in
	""|list)  list ;;
	on|off)   to=$1; shift; switch "$to" "$@" ;;
	install)
		install_all
		if [[ -z "${NUG_RUN_DIR:-}" ]]; then finish; fi ;;
	*)        die "unknown: $1, see: rebuild apps" ;;
esac
