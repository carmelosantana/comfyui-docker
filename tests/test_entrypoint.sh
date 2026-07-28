#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
# Source the entrypoint WITHOUT running main (guarded in the script).
. "$HERE/../source/entrypoint.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Manager v4 is a pip-installed package activated by --enable-manager, NOT a v3 symlink into
# custom_nodes (ComfyUI rejects that path as IMPORT FAILED). remove_stale_manager must therefore
# purge any stale v3 ComfyUI-Manager from the custom_nodes mount and create NO symlink.

# Case A: a real stale ComfyUI-Manager dir is backed up to .bak; NO symlink is created.
MANAGER_SRC="$workdir/baked-manager"; mkdir -p "$MANAGER_SRC"; echo v4 > "$MANAGER_SRC/marker"
CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
echo v3 > "$CUSTOM_NODES_DIR/ComfyUI-Manager/legacy"
remove_stale_manager
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir removed from custom_nodes"
assert_true '[ ! -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "no symlink pointing at baked manager created"
assert_true '[ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/legacy" ]' "old 3.x dir preserved in .bak"

# Case B: an existing (v3) symlink is removed, not recreated, and no .bak is made.
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR"
ln -s /some/old/path "$CUSTOM_NODES_DIR/ComfyUI-Manager"
remove_stale_manager
assert_true '[ ! -L "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "existing symlink removed"
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak" ]' "no .bak created for a symlink"

# Case C: stale dir when a .bak already exists → stale copy dropped, existing .bak untouched.
rm -rf "$workdir/custom_nodes"; CUSTOM_NODES_DIR="$workdir/custom_nodes"; mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak"; echo keep > "$CUSTOM_NODES_DIR/ComfyUI-Manager.bak/keep"
remove_stale_manager
assert_true '[ ! -e "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]' "stale dir dropped even when .bak exists"
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

# --- Task 6: seed_manager_config copies only when absent ---
# NOTE: Manager v4 reads its config from get_system_user_directory("manager"),
# i.e. "$COMFYUI_DIR/user/__manager/config.ini" (verified against the built image),
# NOT the legacy "user/default/ComfyUI-Manager/config.ini" path.
COMFYUI_DIR="$workdir/opt2"; mkdir -p "$COMFYUI_DIR"
MANAGER_CONFIG_SRC="$workdir/default-config.ini"; printf '[default]\nsecurity_level = weak\n' > "$MANAGER_CONFIG_SRC"
dest="$COMFYUI_DIR/user/__manager/config.ini"
seed_manager_config
assert_true '[ -f "$dest" ]' "config seeded when absent"
assert_eq "weak" "$(sed -n 's/^security_level = //p' "$dest")" "seeded config has security_level weak"
# Now a user-modified config must NOT be overwritten.
printf '[default]\nsecurity_level = normal\n' > "$dest"
seed_manager_config
assert_eq "normal" "$(sed -n 's/^security_level = //p' "$dest")" "existing user config preserved"

# --- Task 6 fix: security level is env-overridable (default weak) ---
# Use FRESH COMFYUI_DIR dirs each time so dest is absent (seed no-ops if dest exists).
COMFYUI_DIR="$workdir/opt_seclvl_default"; mkdir -p "$COMFYUI_DIR"
MANAGER_CONFIG_SRC="$workdir/tmpl.ini"
printf '[default]\nsecurity_level = weak\nnetwork_mode = public\n' > "$MANAGER_CONFIG_SRC"
( unset MANAGER_SECURITY_LEVEL; seed_manager_config )
assert_eq "weak" "$(sed -n 's/^security_level = //p' "$COMFYUI_DIR/user/__manager/config.ini")" "default security_level is weak"

COMFYUI_DIR="$workdir/opt_seclvl_override"; mkdir -p "$COMFYUI_DIR"
MANAGER_SECURITY_LEVEL="normal" seed_manager_config
assert_eq "normal" "$(sed -n 's/^security_level = //p' "$COMFYUI_DIR/user/__manager/config.ini")" "MANAGER_SECURITY_LEVEL overrides to normal"

# --- Fix: maybe_bootstrap_nodes only runs the bootstrap when opted in ---
# Inject a fake bootstrap script that just touches a marker file.
bs_dir="$workdir/bootstrap"; mkdir -p "$bs_dir"
fake_script="$bs_dir/fake-bootstrap.sh"
marker="$bs_dir/marker"
cat > "$fake_script" <<'EOF'
#!/usr/bin/env bash
touch "$BOOTSTRAP_MARKER"
EOF
chmod +x "$fake_script"
export BOOTSTRAP_MARKER="$marker"

# (1) BOOTSTRAP_NODES unset -> no bootstrap, marker absent.
rm -f "$marker"
( unset BOOTSTRAP_NODES; BOOTSTRAP_SCRIPT="$fake_script" maybe_bootstrap_nodes )
assert_true '[ ! -e "$marker" ]' "bootstrap NOT run when BOOTSTRAP_NODES unset"

# (2) BOOTSTRAP_NODES=1 -> bootstrap runs, marker created.
rm -f "$marker"
BOOTSTRAP_NODES=1 BOOTSTRAP_SCRIPT="$fake_script" maybe_bootstrap_nodes
assert_true '[ -e "$marker" ]' "bootstrap run when BOOTSTRAP_NODES=1"

finish
