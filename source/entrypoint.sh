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

main() {
    echo "Creating model directories..."
    create_model_dirs
    echo "Linking ComfyUI Manager..."
    link_manager
    # (config seeding, requirement install, chown, and exec are added in later tasks)
    run_comfyui "$@"
}

# Placeholder exec; replaced/extended by later tasks. Kept minimal so the file is runnable.
run_comfyui() {
    exec /opt/conda/bin/python main.py --port 8188 --listen 0.0.0.0 --disable-auto-launch "$@"
}

# Only run when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
