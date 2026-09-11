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

wait_for 30 $SUDO docker info


## Group

####### deliberately NOT adding you to the docker group
####### the group grants unmediated access to the daemon socket, which means
####### anything running as you can mount the host root into a container and
####### own the machine, with no password prompt anywhere
####### sudo docker costs five keystrokes and closes that off
####### day to day you use the browser and Portainer, not the terminal

if id -nG "$USERNAME" | grep -qw docker; then
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
	$SUDO mkdir -p /home/ai/ollama
	$SUDO chown -R "$USERNAME:$USERNAME" /home/ai/ollama

	$SUDO mkdir -p /etc/systemd/system/ollama.service.d

	$SUDO tee /etc/systemd/system/ollama.service.d/rebuild.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_MODELS=/home/ai/ollama"
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF

	run "reload systemd" $SUDO systemctl daemon-reload
	run "enable ollama"  $SUDO systemctl enable --now ollama

	note "pull a model with: ollama pull llama3.2"
else
	note "ollama turned off in $CONFIG"
fi



#    Stacks


section "Stacks"

$SUDO mkdir -p "$STACKS_DIR"

$SUDO cp -r "$STACKS_SRC/." "$STACKS_DIR/"

$SUDO chown -R "$USERNAME:$USERNAME" /srv/rebuild

ln -sfn "$STACKS_DIR" "$HOME/firelink/stacks"

WANT="${WANT_STACKS:-searxng}"

####### accept the shorthand even if it reached the config by hand
case "$WANT" in
	all|ALL)   WANT="searxng,portainer,invidious,comfyui" ;;
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

	####### bound to loopback and the tailnet, so the laptop and phone reach
	####### it but nothing on the open LAN or the internet can
	TS_IP="$(capture tailscale ip -4)"
	TS_IP="${TS_IP//[[:space:]]/}"

	if [[ -n "$TS_IP" ]]; then
		printf 'BIND_SEARXNG=%s\n' "$TS_IP" >> "$SX/.env"
		note "searxng will also listen on $TS_IP"
	fi

	run "start searxng" $SUDO docker compose -f "$SX/compose.yaml" --env-file "$SX/.env" up -d

	soft "searxng on tailnet" $SUDO ufw allow in on tailscale0 to any port 8080 proto tcp

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

	TS_IP="$(capture tailscale ip -4)"
	TS_IP="${TS_IP//[[:space:]]/}"

	if [[ -n "$TS_IP" ]]; then
		printf 'BIND_INVIDIOUS=%s\n' "$TS_IP" >> "$IV/.env"
		note "invidious will also listen on $TS_IP"
	fi

	run "start invidious" $SUDO docker compose -f "$IV/compose.yaml" --env-file "$IV/.env" up -d

	soft "invidious on tailnet" $SUDO ufw allow in on tailscale0 to any port 3000 proto tcp

	note "invidious at http://127.0.0.1:3000"
	[[ -n "$TS_IP" ]] && note "and at http://$TS_IP:3000 from your other devices"
	note "point FreeTube at it, see Guides/Selfhost.md"
fi


## Comfyui

if contains "$WANT" "comfyui"; then

	CU="$STACKS_DIR/comfyui"

	$SUDO mkdir -p /home/ai/comfyui/run /home/ai/comfyui/basedir
	$SUDO chown -R "$USERNAME:$USERNAME" /home/ai/comfyui

	####### the image honours these, so models and outputs come out owned by
	####### you instead of root
	{
		printf 'WANTED_UID=%s\n' "$(id -u "$USERNAME")"
		printf 'WANTED_GID=%s\n' "$(id -g "$USERNAME")"
	} > "$CU/.env"

	####### pull first, so a missing or renamed image is reported as exactly
	####### that instead of a confusing compose failure
	if soft "pull comfyui image" $SUDO docker compose -f "$CU/compose.yaml" --env-file "$CU/.env" pull; then
		soft "start comfyui" $SUDO docker compose -f "$CU/compose.yaml" --env-file "$CU/.env" up -d
			####### loopback only, you reach it through Sunshine from the laptop
		note "comfyui at http://127.0.0.1:8188, reach it via Sunshine"
	else
		flag "comfyui image did not pull, the stack was not started"
		flag "check the image name in $CU/compose.yaml"
	fi
fi


## Portainer

if contains "$WANT" "portainer"; then

	####### capture then match, same SIGPIPE reason as everywhere else
	NAMES="$(capture $SUDO docker ps -a --format '{{.Names}}')"

	if contains "$NAMES" "portainer"; then
		note "portainer already exists"
	else
		run "start portainer" $SUDO docker run -d \
			-p 127.0.0.1:9443:9443 \
			--name portainer \
			--restart unless-stopped \
			-v /var/run/docker.sock:/var/run/docker.sock \
			-v portainer_data:/data \
			portainer/portainer-ce:latest
	fi

	####### deliberately loopback only
	####### Portainer controls every container on the machine, so it is the
	####### one thing not worth exposing even to your own tailnet
	note "portainer at https://127.0.0.1:9443, this PC only"
	note "set the admin password within a few minutes or restart the container"
fi



#    Verify


section "Verify"

check "docker active"    systemctl is-active --quiet docker
check "docker responds"  $SUDO docker info
check "user in group"    sh -c "id -nG $USERNAME > /tmp/_dg; grep -qw docker /tmp/_dg"
check "stacks copied"    test -d "$STACKS_DIR"
check "ufw-docker"       test -x /usr/local/bin/ufw-docker

if [[ "${HAS_NVIDIA:-no}" == yes ]]; then
	check "cdi spec"     test -f /etc/cdi/nvidia.yaml
	check "cdi hook"     test -f /etc/pacman.d/hooks/99-nvidia-cdi.hook
fi

if [[ "${WANT_OLLAMA:-yes}" == yes ]]; then
	warn "ollama active"  systemctl is-active --quiet ollama
fi

if contains "$WANT" "searxng"; then
	warn "searxng running" sh -c 'sudo docker ps --format "{{.Names}}" > /tmp/_dp; grep -q searxng /tmp/_dp'
fi

if contains "$WANT" "invidious"; then
	warn "invidious running" sh -c 'sudo docker ps --format "{{.Names}}" > /tmp/_di; grep -q invidious /tmp/_di'
fi

verify_done

stage_done



#    End


section "End"

printf '  Self hosting ready.\n'
printf '  Everything binds to 127.0.0.1 only. Nothing is on the internet.\n'
printf '  Read Guides/Selfhost.md for start, stop and update.\n\n'
printf '  The docker group applies at your next login.\n'
printf '  Until then, docker commands need sudo.\n\n'
