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

# Ensure custom_nodes/ComfyUI-Manager is a symlink to the baked (v4+) manager.
# A stale real directory from a legacy git-clone would otherwise shadow it.
link_manager() {
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
    ln -s "$MANAGER_SRC" "$target"
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

# Seed a permissive Manager config at the path Manager v4 actually reads
# (folder_paths.get_system_user_directory("manager") -> user/__manager/config.ini),
# but only when no config exists yet, so a user's own config is never clobbered.
seed_manager_config() {
    local dest_dir="$COMFYUI_DIR/user/__manager"
    local dest="$dest_dir/config.ini"
    if [ -f "$dest" ]; then
        echo "Manager config already present; leaving it untouched."
        return 0
    fi
    if [ -f "$MANAGER_CONFIG_SRC" ]; then
        mkdir -p "$dest_dir"
        cp "$MANAGER_CONFIG_SRC" "$dest"
        echo "Seeded default Manager config at $dest."
    fi
}

main() {
    echo "Creating model directories..."
    create_model_dirs
    echo "Linking ComfyUI Manager..."
    link_manager
    echo "Seeding Manager config (if absent)..."
    seed_manager_config
    echo "Installing custom-node requirements (once)..."
    install_node_requirements

    if [ -z "${USER_ID:-}" ] || [ -z "${GROUP_ID:-}" ]; then
        echo "Running container as $(id -un)..."
        exec /opt/conda/bin/python main.py \
            --port 8188 --listen 0.0.0.0 --disable-auto-launch "$@"
    fi

    echo "Setting up non-root user ${USER_ID}:${GROUP_ID}..."
    getent group "$GROUP_ID" >/dev/null 2>&1 || groupadd --gid "$GROUP_ID" comfyui-user
    id -u "$USER_ID" >/dev/null 2>&1 || useradd --uid "$USER_ID" --gid "$GROUP_ID" --create-home comfyui-user
    chown_app_dirs "$USER_ID" "$GROUP_ID"
    export PATH="$PATH:/home/comfyui-user/.local/bin"

    echo "Running container as comfyui-user (${USER_ID}:${GROUP_ID})..."
    exec sudo --set-home --preserve-env=PATH --user "#${USER_ID}" \
        /opt/conda/bin/python main.py \
            --port 8188 --listen 0.0.0.0 --disable-auto-launch "$@"
}

# Only run when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
