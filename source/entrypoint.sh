#!/usr/bin/env bash
set -euo pipefail

# Configurable locations (overridable for tests).
COMFYUI_DIR="${COMFYUI_DIR:-/opt/comfyui}"
MANAGER_SRC="${MANAGER_SRC:-/opt/comfyui-manager}"
CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-$COMFYUI_DIR/custom_nodes}"
MANAGER_CONFIG_SRC="${MANAGER_CONFIG_SRC:-/opt/comfyui-manager-config.ini}"
# Per-pack node-dep install markers. MUST live off the persistent custom_nodes mount so a
# container recreate (fresh, ephemeral conda env) reinstalls; $COMFYUI_DIR is an image layer.
NODE_DEPS_STATE_DIR="${NODE_DEPS_STATE_DIR:-$COMFYUI_DIR/.node-deps-state}"
# Baked node packs staged OUTSIDE the custom_nodes bind mount (which would shadow them). Seeded
# into the live mount on boot so a fresh/scratch custom_nodes dir still gets the shipped packs.
BAKED_NODES_DIR="${BAKED_NODES_DIR:-/opt/comfyui-baked-nodes}"
# Persistent lazy-download cache for model weights (TTS engines, HF hub, torch hub). Lives UNDER the
# models bind mount so first-use downloads survive a container recreate without a new volume.
HF_CACHE_DIR="${HF_CACHE_DIR:-$COMFYUI_DIR/models/.cache}"

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
    # The lazy-download cache lives under the (excluded) models mount. main.py runs as the target
    # user, so weights it downloads are already user-owned; only the root-created cache root dirs
    # need fixing. Shallow-chown just those — never recurse (the cache grows to many GB).
    local cachedir
    for cachedir in "${HF_HOME:-$HF_CACHE_DIR/huggingface}" "${TORCH_HOME:-$HF_CACHE_DIR/torch}"; do
        [ -e "$cachedir" ] && chown "$uid:$gid" "$cachedir" 2>/dev/null || true
    done
    # Shallow chown of the app root and its top-level files (not the mounts within).
    chown "$uid:$gid" "$COMFYUI_DIR" 2>/dev/null || true
    find "$COMFYUI_DIR" -maxdepth 1 -type f -exec chown "$uid:$gid" {} + 2>/dev/null || true
}

# Content signature for a node pack's dependency inputs. Changes when requirements.txt or
# install.py change, so the on-boot installer re-runs only when a pack's deps actually changed.
node_dep_signature() {
    local dir="$1" reqs="$1/requirements.txt" inst="$1/install.py"
    { [ -f "$reqs" ] && cat "$reqs"; [ -f "$inst" ] && echo "install.py:$(wc -c < "$inst")"; true; } \
        | sha256sum | cut -d' ' -f1
}

install_node_requirements() {
    mkdir -p "$NODE_DEPS_STATE_DIR"
    local dir name reqs inst sig hashfile
    for dir in "$CUSTOM_NODES_DIR"/*; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        [ "$name" = "ComfyUI-Manager" ] && continue
        reqs="$dir/requirements.txt"
        inst="$dir/install.py"
        [ -f "$reqs" ] || [ -f "$inst" ] || continue
        # Content signature; changes when a pack's requirements or install.py change.
        sig="$(node_dep_signature "$dir")"
        hashfile="$NODE_DEPS_STATE_DIR/$name.hash"
        if [ "${FORCE_NODE_REQS:-}" != "1" ] && [ -f "$hashfile" ] && [ "$(cat "$hashfile")" = "$sig" ]; then
            continue
        fi
        if [ -f "$reqs" ]; then
            echo "Installing requirements for $name..."
            pip install --requirement "$reqs" || echo "WARN: requirements install failed for $name (continuing)"
        fi
        if [ -f "$inst" ]; then
            echo "Running install.py for $name..."
            ( cd "$dir" && python install.py ) || echo "WARN: install.py failed for $name (continuing)"
        fi
        echo "$sig" > "$hashfile"
    done
}

# Map a baked pack directory name to its seeding category (audio|video|helper), or "" if
# uncategorized. Categories let a user disable a whole class of baked packs via SEED_{CAT}_NODES
# without touching the others. Adding a baked pack (in the Dockerfile) should add it here too.
baked_node_category() {
    case "$1" in
        TTS-Audio-Suite) echo audio ;;
        ComfyUI-WanVideoWrapper|ComfyUI-VideoHelperSuite|ComfyUI-Frame-Interpolation) echo video ;;
        ComfyUI-KJNodes|ComfyUI_essentials|ComfyUI_HuggingFace_Downloader) echo helper ;;
        *) echo "" ;;
    esac
}

# Whether a seeding category is enabled. Each SEED_{AUDIO,VIDEO,HELPER}_NODES defaults to 1 (on).
# An uncategorized pack ("") is always enabled — it is gated only by the master SEED_BAKED_NODES.
category_enabled() {
    case "$1" in
        audio)  [ "${SEED_AUDIO_NODES:-1}"  = "1" ] ;;
        video)  [ "${SEED_VIDEO_NODES:-1}"  = "1" ] ;;
        helper) [ "${SEED_HELPER_NODES:-1}" = "1" ] ;;
        *)      return 0 ;;
    esac
}

# Copy the baked node packs from the (non-mounted) staging dir into the live custom_nodes mount.
# Runs BEFORE bootstrap/requirements so their deps are considered on the same boot. Idempotent:
# an existing dir (a user's own copy or a prior seed) is left untouched, never clobbered.
# On by default; SEED_BAKED_NODES=0 disables ALL seeding, and each SEED_{AUDIO,VIDEO,HELPER}_NODES=0
# disables just that category. This is a local copy from the image — no git/network involved.
seed_baked_nodes() {
    if [ "${SEED_BAKED_NODES:-1}" != "1" ]; then
        echo "SEED_BAKED_NODES=${SEED_BAKED_NODES:-1} — skipping all baked node seeding."
        return 0
    fi
    [ -d "$BAKED_NODES_DIR" ] || return 0
    mkdir -p "$CUSTOM_NODES_DIR"
    local src name dest cat
    for src in "$BAKED_NODES_DIR"/*; do
        [ -d "$src" ] || continue
        name="$(basename "$src")"
        cat="$(baked_node_category "$name")"
        if ! category_enabled "$cat"; then
            echo "Skipping baked pack $name (category '${cat:-uncategorized}' disabled via SEED_*_NODES)."
            continue
        fi
        dest="$CUSTOM_NODES_DIR/$name"
        if [ -e "$dest" ]; then
            continue
        fi
        echo "Seeding baked node pack $name into custom_nodes..."
        cp -a "$src" "$dest"
    done
}

# Pre-seed on-boot node-dep markers for the baked packs (run at BUILD time). Their Python deps are
# baked into the image, so the on-boot install loop should treat them as already satisfied and skip
# the (heavy) reinstall on every boot/recreate. Markers live in the image layer, so they persist.
write_baked_node_markers() {
    [ -d "$BAKED_NODES_DIR" ] || return 0
    mkdir -p "$NODE_DEPS_STATE_DIR"
    local src name
    for src in "$BAKED_NODES_DIR"/*; do
        [ -d "$src" ] || continue
        name="$(basename "$src")"
        [ -f "$src/requirements.txt" ] || [ -f "$src/install.py" ] || continue
        node_dep_signature "$src" > "$NODE_DEPS_STATE_DIR/$name.hash"
    done
}

# Create the persistent lazy-download cache dirs under the models mount. Env HF_HOME/TORCH_HOME
# (set in the Dockerfile) point here, so engine/HF weights land on a bind mount and survive recreate.
create_cache_dirs() {
    mkdir -p "${HF_HOME:-$HF_CACHE_DIR/huggingface}" "${TORCH_HOME:-$HF_CACHE_DIR/torch}"
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
    echo "Creating persistent model/HF cache directories..."
    create_cache_dirs
    echo "Removing any stale v3 ComfyUI Manager from custom_nodes..."
    remove_stale_manager
    echo "Seeding Manager config (if absent)..."
    seed_manager_config
    echo "Seeding baked node packs into custom_nodes..."
    seed_baked_nodes
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
