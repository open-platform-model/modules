#!/bin/sh
# init-entrypoint.sh — Wolf config-init init container entrypoint.
#
# Ensures the on-disk config file exists (empty on first start),
# then runs the CUE merge tool to produce the final config.toml.
#
# Mount layout:
#   /etc/wolf-init/cfg/config.toml  — incoming config from ConfigMap (read-only)
#   /etc/wolf/cfg/config.toml       — on-disk config on the persistent PVC (read-write)
set -e

CONFIG_DIR="/etc/wolf/cfg"
CONFIG_FILE="$CONFIG_DIR/config.toml"

# Ensure the config directory and file exist.
# On first start the file is empty — the CUE tool treats this as "no paired_clients"
# and writes the full incoming config to disk.
mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"

echo "config-init: running CUE merge tool"
exec cue cmd merge
