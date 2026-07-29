#!/usr/bin/env bash
set -euo pipefail

# Configurable locations (overridable for tests).
COMFYUI_DIR="${COMFYUI_DIR:-/opt/comfyui}"
MANAGER_SRC="${MANAGER_SRC:-/opt/comfyui-manager}"
CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-$COMFYUI_DIR/custom_nodes}"
MANAGER_CONFIG_SRC="${MANAGER_CONFIG_SRC:-/opt/comfyui-manager-config.ini}"

MODEL_DIRECTORIES=(
    checkpoints clip clip_vision configs controlnet diffusers diffusion_models
    embeddings gligen hypernetworks loras photomaker style_models text_encoders
    unet upscale_models vae vae_approx audio_encoders
)

create_model_dirs() {
    mkdir -p "$CUSTOM_NODES_DIR"
    local d
    for d in "${MODEL_DIRECTORIES[@]}"; do
        mkdir -p "$COMFYUI_DIR/models/$d"
    done
}

# Manager v4 is a pip-installed package activated by `--enable-manager`; it is NOT loaded as a
# custom_nodes entry. A stale v3-era ComfyUI-Manager in the custom_nodes mount (a git-clone dir
# or the old symlink) must be removed so ComfyUI does not try to import it and log IMPORT FAILED.
# We deliberately create NO symlink: the pip package + --enable-manager provide the Manager.
remove_stale_manager() {
    local target="$CUSTOM_NODES_DIR/ComfyUI-Manager"
    if [ -L "$target" ]; then
        rm -f "$target"
    elif [ -e "$target" ]; then
        if [ ! -e "$target.bak" ]; then
            mv "$target" "$target.bak"
        else
            rm -rf "$target"
        fi
    fi
}

# Bind mounts that arrive host-owned and must NOT be recursively chowned every boot.
CHOWN_EXCLUDE=(models output input custom_nodes user)

# Print the directories that SHOULD be recursively chowned: the baked manager and the
# ComfyUI application directories, but never the large host bind mounts.
dirs_to_chown() {
    echo "$MANAGER_SRC"
    local entry base
    for entry in "$COMFYUI_DIR"/*/; do
        base="$(basename "$entry")"
        local skip=0 ex
        for ex in "${CHOWN_EXCLUDE[@]}"; do
            [ "$base" = "$ex" ] && skip=1 && break
        done
        [ "$skip" -eq 0 ] && echo "${entry%/}"
    done
}

# Recursively chown app dirs; the excluded mounts get only a shallow, cheap ownership fix
# (the container process writing as the target uid handles new files inside them).
chown_app_dirs() {
    local uid="$1" gid="$2" d
    while IFS= read -r d; do
        [ -e "$d" ] && chown --recursive "$uid:$gid" "$d" 2>/dev/null || true
    done < <(dirs_to_chown)
    local ex
    for ex in "${CHOWN_EXCLUDE[@]}"; do
        [ -e "$COMFYUI_DIR/$ex" ] && chown "$uid:$gid" "$COMFYUI_DIR/$ex" 2>/dev/null || true
    done
    # The Manager v4 state dir lives under the (otherwise-excluded) user mount and is created by
    # seed_manager_config as root; the runtime user must own it recursively so Manager can create
    # its snapshots/startup-scripts/cache/batch_history subdirs on start. It is small and ours.
    [ -e "$COMFYUI_DIR/user/__manager" ] && \
        chown --recursive "$uid:$gid" "$COMFYUI_DIR/user/__manager" 2>/dev/null || true
    # Shallow chown of the app root and its top-level files (not the mounts within).
    chown "$uid:$gid" "$COMFYUI_DIR" 2>/dev/null || true
    find "$COMFYUI_DIR" -maxdepth 1 -type f -exec chown "$uid:$gid" {} + 2>/dev/null || true
}

install_node_requirements() {
    local sentinel="$CUSTOM_NODES_DIR/.requirements-installed"
    if [ -f "$sentinel" ] && [ "${FORCE_NODE_REQS:-}" != "1" ]; then
        echo "Node requirements already installed (sentinel present); skipping."
        return 0
    fi
    local dir name
    for dir in "$CUSTOM_NODES_DIR"/*; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        [ "$name" = "ComfyUI-Manager" ] && continue
        if [ -f "$dir/requirements.txt" ]; then
            echo "Installing requirements for $name..."
            pip install --requirement "$dir/requirements.txt" || true
        fi
    done
    touch "$sentinel"
}

# Clone the supported node packs into custom_nodes when the user opts in with
# BOOTSTRAP_NODES=1. Runs before install_node_requirements so freshly-cloned packs'
# requirements get installed on the same first boot. Script path and manifest are
# overridable for tests; a missing script warns but never crashes boot.
maybe_bootstrap_nodes() {
    if [ "${BOOTSTRAP_NODES:-}" != "1" ]; then
        return 0
    fi
    local script="${BOOTSTRAP_SCRIPT:-/opt/scripts/bootstrap-nodes.sh}"
    if [ ! -f "$script" ]; then
        echo "BOOTSTRAP_NODES=1 but bootstrap script not found at $script; skipping."
        return 0
    fi
    export NODE_MANIFEST="${NODE_MANIFEST:-/opt/scripts/node-manifest.txt}"
    export CUSTOM_NODES_DIR
    echo "Bootstrapping node packs (BOOTSTRAP_NODES=1)..."
    bash "$script"
}

# Replace an INI key's line in $file, or append it under [default] if absent.
_set_ini_key() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^${key}[[:space:]]*=" "$file"; then
        sed -i "s|^${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
    else
        printf '%s = %s\n' "$key" "$val" >> "$file"
    fi
}

# Seed a Manager config at the path Manager v4 actually reads
# (folder_paths.get_system_user_directory("manager") -> user/__manager/config.ini),
# but only when no config exists yet, so a user's own config is never clobbered.
# The security_level/network_mode are env-overridable (default weak/public) so the
# MCP's arbitrary-URL installs work out of the box while a stricter posture stays
# one env var away.
seed_manager_config() {
    local dest_dir="$COMFYUI_DIR/user/__manager"
    local dest="$dest_dir/config.ini"
    mkdir -p "$dest_dir"
    if [ ! -f "$dest" ]; then
        if [ -f "$MANAGER_CONFIG_SRC" ]; then
            cp "$MANAGER_CONFIG_SRC" "$dest"
        else
            printf '[default]\n' > "$dest"
        fi
    fi
    # Manager v4 reads network_mode/security_level ONLY from this file, cached on first read, so we
    # enforce them here (before main.py). personal_cloud + normal is the only combo that unlocks the
    # install/model management API on a non-loopback (--listen 0.0.0.0) box. Env-overridable, and
    # enforced EVERY boot so a stale value from a prior image (e.g. public) is corrected on redeploy.
    # Any other user keys already in the file are left untouched.
    local level="${MANAGER_SECURITY_LEVEL:-normal}"
    local netmode="${MANAGER_NETWORK_MODE:-personal_cloud}"
    _set_ini_key "$dest" security_level "$level"
    _set_ini_key "$dest" network_mode "$netmode"
    echo "Manager config enforced at $dest (security_level=$level, network_mode=$netmode)."
}

# Transform the ComfyUI arg list for the sage-attention toggle. When USE_SAGE_ATTENTION=1,
# drop any --use-pytorch-cross-attention (sage replaces it) and append --use-sage-attention.
# Otherwise echo the args unchanged. Prints one arg per line (consumed via mapfile).
apply_sage_attention() {
    if [ "${USE_SAGE_ATTENTION:-0}" != "1" ]; then
        (( $# )) && printf '%s\n' "$@"
        return 0
    fi
    local a
    for a in "$@"; do
        [ "$a" = "--use-pytorch-cross-attention" ] && continue
        printf '%s\n' "$a"
    done
    printf '%s\n' "--use-sage-attention"
}

main() {
    echo "Creating model directories..."
    create_model_dirs
    echo "Removing any stale v3 ComfyUI Manager from custom_nodes..."
    remove_stale_manager
    echo "Seeding Manager config (if absent)..."
    seed_manager_config
    echo "Bootstrapping node packs (if opted in)..."
    maybe_bootstrap_nodes
    echo "Installing custom-node requirements (once)..."
    install_node_requirements

    mapfile -t COMFY_ARGS < <(apply_sage_attention "$@")

    if [ -z "${USER_ID:-}" ] || [ -z "${GROUP_ID:-}" ]; then
        echo "Running container as $(id -un)..."
        exec /opt/conda/bin/python main.py \
            --port 8188 --listen 0.0.0.0 --disable-auto-launch --enable-manager "${COMFY_ARGS[@]}"
    fi

    echo "Setting up non-root user ${USER_ID}:${GROUP_ID}..."
    getent group "$GROUP_ID" >/dev/null 2>&1 || groupadd --gid "$GROUP_ID" comfyui-user
    id -u "$USER_ID" >/dev/null 2>&1 || useradd --uid "$USER_ID" --gid "$GROUP_ID" --create-home comfyui-user
    chown_app_dirs "$USER_ID" "$GROUP_ID"
    export PATH="$PATH:/home/comfyui-user/.local/bin"

    echo "Running container as comfyui-user (${USER_ID}:${GROUP_ID})..."
    exec sudo --set-home --preserve-env=PATH --user "#${USER_ID}" \
        /opt/conda/bin/python main.py \
            --port 8188 --listen 0.0.0.0 --disable-auto-launch --enable-manager "${COMFY_ARGS[@]}"
}

# Only run when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
