#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
# Source the entrypoint WITHOUT running main (guarded in the script).
. "$HERE/../source/entrypoint.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Case A: a real stale ComfyUI-Manager dir is backed up and replaced by a symlink.
MANAGER_SRC="$workdir/baked-manager"; mkdir -p "$MANAGER_SRC"; echo v4 > "$MANAGER_SRC/marker"
CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
echo v3 > "$CUSTOM_NODES_DIR/ComfyUI-Manager/legacy"
link_manager
assert_true '[ -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir replaced by a symlink"
assert_eq "$MANAGER_SRC" "$(readlink "$CUSTOM_NODES_DIR/ComfyUI-Manager")" "symlink points at baked manager"
assert_true '[ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/legacy" ]' "old 3.x dir preserved in .bak"

# Case B: an existing symlink is refreshed (not backed up).
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR"
ln -s /some/old/path "$CUSTOM_NODES_DIR/ComfyUI-Manager"
link_manager
assert_eq "$MANAGER_SRC" "$(readlink "$CUSTOM_NODES_DIR/ComfyUI-Manager")" "existing symlink refreshed to baked manager"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak" ]' "no .bak created for a symlink"

# Case C: stale dir when a .bak already exists → stale copy dropped, existing .bak untouched.
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak"; echo keep > "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/keep"
link_manager
assert_true '[ -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir replaced even when .bak exists"
assert_true '[ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/keep" ]' "pre-existing .bak left intact"

finish
