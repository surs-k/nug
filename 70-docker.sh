#!/usr/bin/env bash

set -Eeuo pipefail

source "$(dirname "$(readlink -f "$0")")/00-lib.sh"


#    Check


section "Check"

sudo_keepalive

require_stage 30-security

if [[ "${WANT_DOCKER:-yes}" != yes ]]; then
	note "self hosting turned off in $CONFIG"
	stage_done
	exit 0
fi

STACKS_SRC="$REPO/stacks"
STACKS_DIR="/srv/rebuild/stacks"



#    Docker


section "Docker"


## Install

pac docker docker-compose docker-buildx


## Storage

####### overlay2 on top of btrfs, not the btrfs storage driver
####### the btrfs driver is deprecated upstream
####### @docker keeps compression, so no chattr +C here, the two are
####### mutually exclusive and compression is worth more than the
####### fragmentation it costs on a home machine

$SUDO mkdir -p /etc/docker

if [[ -f /etc/docker/daemon.json ]]; then
	note "daemon.json already present, leaving it alone"
else
	$SUDO tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
fi


## Service

run "enable docker" $SUDO systemctl enable --now docker.service

####### docker info prints a page of text, only the answer matters here
docker_up() { $SUDO docker info > /dev/null 2>&1; }

wait_for 30 docker_up


## Group

####### deliberately NOT adding you to the docker group
####### the group grants unmediated access to the daemon socket, which means
####### anything running as you can mount the host root into a container and
####### own the machine, with no password prompt anywhere
####### sudo docker costs five keystrokes and closes that off
####### day to day you use the browser and Portainer, not the terminal

####### capture then match, a pipe into grep -q can read as false here
DGROUPS="$(id -nG "$USERNAME" 2>/dev/null || true)"

if [[ " $DGROUPS " == *" docker "* ]]; then
	flag "you are in the docker group, which is root equivalent"
	flag "remove it with: sudo gpasswd -d $USERNAME docker"
else
	note "not in the docker group, use sudo docker or Portainer"
fi


## Ownership

####### containers write bind mounted files as root unless told otherwise
####### that leaves your ComfyUI models and outputs undeletable from Dolphin
UID_GID="$(id -u "$USERNAME"):$(id -g "$USERNAME")"

save_cfg CONTAINER_UID "$UID_GID"

note "containers will run as $UID_GID so your files stay yours"



#    Gpu


section "Gpu"

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then

	pac nvidia-container-toolkit

	####### cdi is the current path, the old runtime hook is legacy
	####### this spec has to be regenerated after every driver update
	run "configure runtime" $SUDO nvidia-ctk runtime configure --runtime=docker
	run "set cdi mode"      $SUDO nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi

	$SUDO mkdir -p /etc/cdi
	run "generate cdi spec" $SUDO nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

	run "restart docker" $SUDO systemctl restart docker

	####### regenerate automatically so a driver update does not silently
	####### break every gpu container
	$SUDO mkdir -p /etc/pacman.d/hooks

	$SUDO tee /etc/pacman.d/hooks/99-nvidia-cdi.hook > /dev/null << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = nvidia-open-dkms
Target = nvidia-utils

[Action]
Description = Regenerating the NVIDIA CDI spec...
When = PostTransaction
Exec = /usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
EOF

	note "gpu containers use: --device nvidia.com/gpu=all"
else
	note "no NVIDIA card, skipping container gpu setup"
fi



#    Firewall


section "Firewall"

####### docker writes its own iptables chains and walks straight past ufw
####### a published port is reachable even when ufw says it is denied
####### ufw-docker adds the missing filter block
####### the stacks below also bind to 127.0.0.1 so nothing is exposed twice

if [[ -x /usr/local/bin/ufw-docker ]]; then
	note "ufw-docker already installed"
else
	run "fetch ufw-docker" $SUDO curl -fsSL -o /usr/local/bin/ufw-docker \
		https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker
	$SUDO chmod 755 /usr/local/bin/ufw-docker
fi

if $SUDO grep -q 'ufw-docker' /etc/ufw/after.rules 2>/dev/null; then
	note "ufw after.rules already patched"
else
	$SUDO cp /etc/ufw/after.rules /etc/ufw/after.rules.bak-docker
	soft "patch ufw rules" $SUDO /usr/local/bin/ufw-docker install
	soft "reload ufw"      $SUDO ufw reload
fi



#    Ollama


section "Ollama"

ollama_answers() { curl -fsS --max-time 3 http://127.0.0.1:11434/api/version > /dev/null 2>&1; }

####### native package, not a container
####### the container adds gpu plumbing for no benefit on a machine that
####### already has the driver installed

if [[ "${WANT_OLLAMA:-yes}" == yes ]]; then

	if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
		pac ollama-cuda
	else
		pac ollama
	fi

	####### models are large, keep them on the data disk
	####### the packaged service runs as its own user and hides all of /home
	####### from itself with ProtectHome, so the models folder was out of its
	####### reach and the service died a moment after starting
	####### ProtectHome=tmpfs with BindPaths shows it that one folder only,
	####### the rest of /home stays hidden, and the folder belongs to it
	OLLAMA_USER="$(systemctl show -p User --value ollama.service 2>/dev/null || true)"
	OLLAMA_USER="${OLLAMA_USER:-ollama}"

	$SUDO mkdir -p /home/ai/ollama

	if id -u "$OLLAMA_USER" &> /dev/null; then
		$SUDO chown -R "$OLLAMA_USER:$OLLAMA_USER" /home/ai/ollama
	else
		flag "no $OLLAMA_USER user, ollama may not be able to save models"
	fi

	$SUDO mkdir -p /etc/systemd/system/ollama.service.d

	$SUDO tee /etc/systemd/system/ollama.service.d/rebuild.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_MODELS=/home/ai/ollama"
Environment="OLLAMA_HOST=127.0.0.1:11434"
ProtectHome=tmpfs
BindPaths=/home/ai/ollama
EOF

	run "reload systemd" $SUDO systemctl daemon-reload
	run "enable ollama"  $SUDO systemctl enable --now ollama
	run "restart ollama" $SUDO systemctl restart ollama

	####### active is not proof, the old failure was active for one second
	####### an answer on its port is
	wait_for 20 ollama_answers || flag "ollama is not answering on 127.0.0.1:11434"

	note "pull a model with: ollama pull llama3.2"
else
	note "ollama turned off in $CONFIG"
fi



#    Stacks


section "Stacks"


## Helpers

####### one service failing no longer stops the ones after it
####### each failure is named with its reason, read out of the log, and the
####### stage still ends unfinished, so rebuild --retry comes back to it
####### Docker Hub limits downloads per address when you are not logged in,
####### and a VPN address is shared by many people, so hitting that limit
####### gets one automatic retry through a different Mullvad server

STACK_FAILS=0

mullvad_connected() {
	local st
	st="$(capture $SUDO mullvad status)"
	contains "$st" "Connected"
}

pull_reason() {
	local tail
	tail="$(tail -n 40 "$LOG" 2>/dev/null || true)"

	if contains "$tail" "toomanyrequests"; then
		printf 'Docker Hub download limit reached for this VPN address'
	elif contains "$tail" "manifest unknown" || contains "$tail" "not found: manifest"; then
		printf 'the image name or tag no longer exists'
	elif contains "$tail" "no such host" || contains "$tail" "i/o timeout" \
		|| contains "$tail" "TLS handshake timeout" || contains "$tail" "connection reset"; then
		printf 'could not reach the image registry'
	elif contains "$tail" "port is already allocated" || contains "$tail" "address already in use"; then
		printf 'its port is already taken by something else'
	elif contains "$tail" "invalid IP address"; then
		printf 'a bind address in its .env is not a real address'
	else
		printf 'the reason is in %s' "$LOG"
	fi
}

####### downloads, with the one retry described above
pull_images() {
	local name=$1; shift

	run "download $name" "$@" && return 0

	contains "$(pull_reason)" "download limit" || return 1

	note "Docker Hub limit on this VPN address, switching server, trying once more"
	soft "switch VPN server" $SUDO mullvad reconnect
	sleep 5
	wait_for 60 mullvad_connected || true
	wait_for 30 resolves || true

	run "download $name again" "$@"
}

stack_failed() {
	flag "$1 did not start: $(pull_reason)"
	STACK_FAILS=$(( STACK_FAILS + 1 ))
	WHY=""
}

####### everything after the name is handed to docker compose as is
stack_up() {
	local name=$1; shift

	if ! pull_images "$name" $SUDO docker compose "$@" pull; then
		stack_failed "$name"
		return 0
	fi

	if ! run "start $name" $SUDO docker compose "$@" up -d; then
		stack_failed "$name"
	fi
	return 0
}

####### the tailnet address is added as a second compose file, only when there
####### is one, the single file used to list 127.0.0.1 twice when there was not
####### COMPOSE_FILE in .env makes a plain docker compose in that folder pick up
####### the same files the script used
compose_files() {
	local dir=$1 var=$2 ip

	sed -i "/^$var=/d; /^COMPOSE_FILE=/d" "$dir/.env"

	FILES=(-f "$dir/compose.yaml")

	if ip="$(tailnet_ip)"; then
		printf '%s=%s\n' "$var" "$ip" >> "$dir/.env"
		printf 'COMPOSE_FILE=compose.yaml:tailnet.yaml\n' >> "$dir/.env"
		FILES+=(-f "$dir/tailnet.yaml")
		TS_IP="$ip"
		return 0
	fi

	TS_IP=""
	return 1
}


## Copy

$SUDO mkdir -p "$STACKS_DIR"

$SUDO cp -r "$STACKS_SRC/." "$STACKS_DIR/"

$SUDO chown -R "$USERNAME:$USERNAME" /srv/rebuild

ln -sfn "$STACKS_DIR" "$HOME/firelink/stacks"

####### nothing starts itself at boot any more, every compose file says
####### restart: "no", so a service runs only while you want it to
####### this is the command that starts and stops them by name
$SUDO install -m 755 "$REPO/stack.sh" /usr/local/bin/stack

WANT="${WANT_STACKS:-searxng}"

####### accept the shorthand even if it reached the config by hand
case "$WANT" in
	all|ALL)   WANT="searxng,portainer,invidious,comfyui,jellyfin" ;;
	none|NONE) WANT="" ;;
esac

note "stacks: ${WANT:-none}"


## Searxng

if contains "$WANT" "searxng"; then

	SX="$STACKS_DIR/searxng"

	if [[ -f "$SX/.env" ]]; then
		note "searxng secret already set"
	else
		printf 'SEARXNG_SECRET=%s\n' "$(openssl rand -hex 32)" > "$SX/.env"
		chmod 600 "$SX/.env"
	fi

	if compose_files "$SX" BIND_SEARXNG; then
		note "searxng will also listen on $TS_IP"
	else
		note "no tailnet, searxng listens on this machine only"
	fi

	stack_up searxng "${FILES[@]}" --env-file "$SX/.env"

	if ip link show tailscale0 &> /dev/null; then
		soft "searxng on tailnet" $SUDO ufw allow in on tailscale0 to any port 8080 proto tcp
	fi

	note "searxng at http://127.0.0.1:8080"
	[[ -n "$TS_IP" ]] && note "and at http://$TS_IP:8080 from your other devices"
fi


## Invidious

####### a local youtube backend for freetube
####### freetube can only talk to invidious, not piped, so this is the one
####### the companion key must be exactly 16 characters or invidious refuses

if contains "$WANT" "invidious"; then

	IV="$STACKS_DIR/invidious"

	if [[ -f "$IV/.env" ]]; then
		note "invidious secrets already set"
	else
		{
			printf 'DB_PASSWORD=%s\n'   "$(openssl rand -hex 16)"
			printf 'COMPANION_KEY=%s\n' "$(openssl rand -hex 8)"
			printf 'HMAC_KEY=%s\n'      "$(openssl rand -hex 16)"
		} > "$IV/.env"
		chmod 600 "$IV/.env"
	fi

	if compose_files "$IV" BIND_INVIDIOUS; then
		note "invidious will also listen on $TS_IP"
	else
		note "no tailnet, invidious listens on this machine only"
	fi

	stack_up invidious "${FILES[@]}" --env-file "$IV/.env"

	if ip link show tailscale0 &> /dev/null; then
		soft "invidious on tailnet" $SUDO ufw allow in on tailscale0 to any port 3000 proto tcp
	fi

	note "invidious at http://127.0.0.1:3000"
	[[ -n "$TS_IP" ]] && note "and at http://$TS_IP:3000 from your other devices"
	note "point FreeTube at it, see Guides/Selfhost.md"
fi


## Comfyui

if contains "$WANT" "comfyui" && [[ "${HAS_NVIDIA:-no}" != yes ]]; then
	note "skipping comfyui, it needs a GPU and this machine has none"

elif contains "$WANT" "comfyui"; then

	CU="$STACKS_DIR/comfyui"

	$SUDO mkdir -p /home/ai/comfyui/run /home/ai/comfyui/basedir
	$SUDO chown -R "$USERNAME:$USERNAME" /home/ai/comfyui

	####### the image honours these, so models and outputs come out owned by
	####### you instead of root
	{
		printf 'WANTED_UID=%s\n' "$(id -u "$USERNAME")"
		printf 'WANTED_GID=%s\n' "$(id -g "$USERNAME")"
	} > "$CU/.env"

	####### loopback only, you reach it through Sunshine from the laptop
	stack_up comfyui -f "$CU/compose.yaml" --env-file "$CU/.env"

	note "comfyui at http://127.0.0.1:8188, reach it via Sunshine"
fi


## Jellyfin

####### a library for the shows you study frame by frame
####### the server is the container, the player is not: jellyfin-mpv-shim
####### needs your screen, your sound and your keyboard, so it stays a desktop
####### app, see Guides/Selfhost.md
####### media is mounted read only, nothing in here can change your files

if contains "$WANT" "jellyfin"; then

	JF="$STACKS_DIR/jellyfin"
	MEDIA_DIR="${MEDIA_DIR:-$HOME/Videos}"

	mkdir -p "$MEDIA_DIR"
	$SUDO mkdir -p "$JF/config" "$JF/cache"
	$SUDO chown -R "$USERNAME:$USERNAME" "$JF"

	{
		printf 'WANTED_UID=%s\n' "$(id -u "$USERNAME")"
		printf 'WANTED_GID=%s\n' "$(id -g "$USERNAME")"
		printf 'MEDIA_DIR=%s\n'  "$MEDIA_DIR"
	} > "$JF/.env"

	save_cfg MEDIA_DIR "$MEDIA_DIR"

	stack_up jellyfin -f "$JF/compose.yaml" --env-file "$JF/.env"

	note "jellyfin at http://127.0.0.1:8096, media from $MEDIA_DIR"
	action "Open http://127.0.0.1:8096 and finish the Jellyfin setup wizard.

Add a library pointing at /media, which is $MEDIA_DIR on this PC."
fi


## Portainer

if contains "$WANT" "portainer"; then

	####### capture then match, same SIGPIPE reason as everywhere else
	NAMES="$(capture $SUDO docker ps -a --format '{{.Names}}')"

	if contains "$NAMES" "portainer"; then
		note "portainer already exists"

	elif ! pull_images portainer $SUDO docker pull portainer/portainer-ce:latest; then
		stack_failed portainer

	elif ! run "start portainer" $SUDO docker run -d \
		-p 127.0.0.1:9443:9443 \
		--name portainer \
		--restart no \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v portainer_data:/data \
		portainer/portainer-ce:latest; then
		stack_failed portainer

	else
		####### deliberately loopback only
		####### Portainer controls every container on the machine, so it is the
		####### one thing not worth exposing even to your own tailnet
		note "portainer at https://127.0.0.1:9443, this PC only"
		action "Open https://127.0.0.1:9443 and set the Portainer admin password.

It stops itself if no password is set within a few minutes, and then the
container needs restarting: sudo docker restart portainer"
	fi
fi



#    Verify


section "Verify"

check "docker active"    systemctl is-active --quiet docker
check "docker responds"  $SUDO docker info
####### you are deliberately NOT in the docker group, so this check could
####### never pass, and its failure was the whole reason the stage exited 1
####### the stacks were coming up fine
check "not in docker group" sh -c "id -nG $USERNAME > /tmp/_dg; ! grep -qw docker /tmp/_dg"
check "stacks copied"    test -d "$STACKS_DIR"
check "ufw-docker"       test -x /usr/local/bin/ufw-docker

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
	check "cdi spec"     test -f /etc/cdi/nvidia.yaml
	check "cdi hook"     test -f /etc/pacman.d/hooks/99-nvidia-cdi.hook
fi

if [[ "${WANT_OLLAMA:-yes}" == yes ]]; then
	check "ollama answers"     ollama_answers
fi

####### exact names, so searxng-valkey can never stand in for searxng
container_up() {
	local names
	names="$(capture $SUDO docker ps --format '{{.Names}}')"
	[[ $'\n'"$names"$'\n' == *$'\n'"$1"$'\n'* ]]
}

####### a service that did not start keeps this stage unfinished, so
####### rebuild --retry comes back to it once the reason is gone
check "chosen services started" test "$STACK_FAILS" -eq 0

if contains "$WANT" "searxng"; then
	check "searxng running"    container_up searxng
fi

if contains "$WANT" "invidious"; then
	check "invidious running"  container_up invidious
fi

####### a warning only, portainer stops itself when nobody sets a password
if contains "$WANT" "portainer"; then
	warn  "portainer running"  container_up portainer
fi

if contains "$WANT" "jellyfin"; then
	check "jellyfin running"   container_up jellyfin
fi

check "stack command"      test -x /usr/local/bin/stack

verify_done

stage_done



#    End


section "End"

printf '  Self hosting ready.\n'
printf '  Everything binds to 127.0.0.1 only. Nothing is on the internet.\n'
printf '  Nothing here starts itself at boot. Start what you need:\n\n'
printf '    stack list\n'
printf '    stack up searxng\n'
printf '    stack down searxng\n\n'
printf '  Read Guides/Selfhost.md for update and repair.\n\n'
printf '  Docker commands need sudo, on purpose.\n'
printf '  You are not in the docker group, it would be root without a password.\n\n'
