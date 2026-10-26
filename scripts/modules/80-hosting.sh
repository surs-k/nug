#!/usr/bin/env bash

# Ai - hosting: a start for local AI and small services, nothing reachable
#      from outside this PC
#      Ollama runs models, on the GPU when it is NVIDIA, its models live in
#      /home/ai on the data disk, so a reinstall keeps them
#      Podman runs services without root, the start for SearXNG, Invidious
#      and the rest, which come in a later step

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "$0")")/../lib.sh"

title "Hosting" "Podman and Ollama for local AI"


step "Ollama"

OLLAMA=(ollama)
if grep -qs 0x10de /sys/bus/pci/devices/*/vendor; then OLLAMA+=(ollama-cuda); fi
pac "${OLLAMA[@]}"

	# Ai - only this PC can talk to it, and the models go to the data disk
quiet $SUDO install -d -o ollama -g ollama /home/ai/ollama
put /etc/systemd/system/ollama.service.d/nug.conf << 'CONF'
[Service]
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=OLLAMA_MODELS=/home/ai/ollama
CONF
run "reload services" $SUDO systemctl daemon-reload
run "Ollama on" $SUDO systemctl enable --now ollama


step "Podman"

	# Ai - services in containers that run as you, not as root, so one that
	#      is broken into cannot take the whole PC
pac podman podman-compose passt
ok "Podman ready for services, none are set up yet"


step "Check"

if wait_for 20 curl -fs http://127.0.0.1:11434/api/version; then ok "Ollama answers on this PC only"; else warn "Ollama did not answer"; fi
todo "Try a model:  ollama run llama3.2   (it downloads once, about 2 GB)"
