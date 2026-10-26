#!/usr/bin/env bash

# Ai - apps: everything in config/apps.list that is on, see `rebuild apps`
exec bash "$(dirname "$(readlink -f "$0")")/../apps.sh" install
