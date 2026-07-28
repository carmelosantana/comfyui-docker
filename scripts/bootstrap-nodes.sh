#!/usr/bin/env bash
set -euo pipefail

CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-/opt/comfyui/custom_nodes}"
NODE_MANIFEST="${NODE_MANIFEST:-/opt/scripts/node-manifest.txt}"

if [ ! -f "$NODE_MANIFEST" ]; then
    echo "Node manifest not found at $NODE_MANIFEST; nothing to bootstrap."
    exit 0
fi

mkdir -p "$CUSTOM_NODES_DIR"

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [ -z "$line" ] && continue
    url="$(echo "$line" | awk '{print $1}')"
    ref="$(echo "$line" | awk '{print $2}')"
    name="$(basename "$url")"; name="${name%.git}"
    dest="$CUSTOM_NODES_DIR/$name"
    if [ -e "$dest" ]; then
        echo "Skipping $name (already present)."
        continue
    fi
    echo "Cloning $name..."
    git clone "$url" "$dest"
    if [ -n "$ref" ]; then
        git -C "$dest" checkout "$ref"
    fi
done < "$NODE_MANIFEST"

echo "Node bootstrap complete."
