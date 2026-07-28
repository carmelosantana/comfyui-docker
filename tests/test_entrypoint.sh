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

# --- Task 4: dirs_to_chown excludes the big bind mounts ---
COMFYUI_DIR="$workdir/opt/comfyui"; MANAGER_SRC="$workdir/opt/comfyui-manager"
mkdir -p "$COMFYUI_DIR"/{models,output,input,custom_nodes,web,comfy,app} "$MANAGER_SRC"
chown_list="$(dirs_to_chown)"
assert_true 'echo "$chown_list" | grep -qx "$MANAGER_SRC"' "chowns the baked manager"
assert_true 'echo "$chown_list" | grep -qx "$COMFYUI_DIR/web"' "chowns the app web dir"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/models"' "does NOT chown the models mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/output"' "does NOT chown the output mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/input"' "does NOT chown the input mount"
assert_true '! echo "$chown_list" | grep -qx "$COMFYUI_DIR/custom_nodes"' "does NOT chown the custom_nodes mount"

# --- Task 5: node requirements install runs once (sentinel) ---
CUSTOM_NODES_DIR="$workdir/cn"; mkdir -p "$CUSTOM_NODES_DIR/PackA"
echo "somepkg==1.0" > "$CUSTOM_NODES_DIR/PackA/requirements.txt"
pipbin="$workdir/bin"; mkdir -p "$pipbin"
cat > "$pipbin/pip" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$PIP_LOG"
EOF
chmod +x "$pipbin/pip"
export PIP_LOG="$workdir/pip.log"; : > "$PIP_LOG"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_true '[ -f "$CUSTOM_NODES_DIR/.requirements-installed" ]' "sentinel written after first run"
assert_eq "1" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "PackA requirements installed once"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="" install_node_requirements
assert_eq "1" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "second unforced run is a no-op"
PATH="$pipbin:$PATH" FORCE_NODE_REQS="1" install_node_requirements
assert_eq "2" "$(grep -c 'PackA/requirements.txt' "$PIP_LOG")" "FORCE_NODE_REQS reinstalls"

finish
