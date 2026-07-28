#!/usr/bin/env bash
#
# cleanup-legacy-comfyui.sh
#
# Reversibly clean a migrated ComfyUI data directory (e.g. /mnt/Data/ComfyUI).
#
# Carmelo migrated a full local ComfyUI install onto TrueNAS and now bind-mounts
# only the data dirs (models/input/output/custom_nodes/user) into the
# carmelosantana/comfyui-docker image. The leftover full-install files
# (main.py, comfy/, web/, requirements.txt, venv/, .git, ...) now come FROM the
# image and just sit in the data dir causing potential conflicts + wasted space.
#
# This script NEVER deletes. It MOVES every non-allowlisted entry in the target
# directory into a timestamped `_legacy_backup_<ts>/` folder inside that same
# directory, and prints the exact `mv` recipe to undo it.
#
# Default is a DRY RUN. Nothing changes until you pass --apply.
#
# Usage:
#   sudo bash cleanup-legacy-comfyui.sh --dry-run /mnt/Data/ComfyUI   # preview (default)
#   sudo bash cleanup-legacy-comfyui.sh --apply   /mnt/Data/ComfyUI   # actually move
#   sudo bash cleanup-legacy-comfyui.sh --keep .env --apply /mnt/Data/ComfyUI
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Entries KEPT in place (never moved). Bind-mounted data + Carmelo's model-path
# config. Add more at runtime with --keep NAME (repeatable), e.g. --keep .env
KEEP=(
    models
    input
    output
    custom_nodes
    user
    extra_model_paths.yaml
)

# Prefix used for the timestamped backup folder(s). Any entry matching this
# prefix is always skipped so we never move a previous (or the current) backup.
BACKUP_PREFIX="_legacy_backup_"

# Absolute paths we refuse to operate on, no matter what.
FORBIDDEN_TARGETS=(
    / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc
    /root /run /sbin /srv /sys /tmp /usr /var
)

MODE="dry-run"   # dry-run | apply

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# in_array <needle> <haystack...>
in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE="dry-run"; shift ;;
        --apply)   MODE="apply";   shift ;;
        --keep)
            [[ $# -ge 2 ]] || { err "--keep needs a NAME"; exit 2; }
            KEEP+=("$2"); shift 2 ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) err "Unknown option: $1"; usage 2 ;;
        *)
            [[ -z "$TARGET" ]] || { err "Multiple target dirs given: '$TARGET' and '$1'"; exit 2; }
            TARGET="$1"; shift ;;
    esac
done
# Allow a target after a lone --
if [[ -z "$TARGET" && $# -gt 0 ]]; then TARGET="$1"; fi

if [[ -z "$TARGET" ]]; then
    err "No target directory given."
    usage 2
fi

# ---------------------------------------------------------------------------
# Safety guards
# ---------------------------------------------------------------------------

# Must exist and be a directory (before we resolve, so the message is clear).
if [[ ! -e "$TARGET" ]]; then
    err "Target does not exist: $TARGET"
    exit 1
fi
if [[ ! -d "$TARGET" ]]; then
    err "Target is not a directory: $TARGET"
    exit 1
fi

# Resolve to a canonical absolute path so all later checks are unambiguous.
if ! TARGET_ABS="$(cd "$TARGET" 2>/dev/null && pwd -P)"; then
    err "Cannot resolve target directory: $TARGET"
    exit 1
fi

# Refuse system roots and anything too shallow to be a data dir.
if in_array "$TARGET_ABS" "${FORBIDDEN_TARGETS[@]}"; then
    err "Refusing to operate on a system directory: $TARGET_ABS"
    exit 1
fi
# Depth guard: require at least two path components (e.g. /mnt/Data/ComfyUI is 3).
depth="$(awk -F/ '{print NF-1}' <<< "$TARGET_ABS")"
if [[ "$depth" -lt 2 ]]; then
    err "Target path is too shallow to be a ComfyUI data dir: $TARGET_ABS"
    exit 1
fi

# Sanity: does this actually look like a ComfyUI install / data dir?
# Accept if it has a source marker (main.py / comfy) OR the data dirs we manage.
looks_like_comfyui=false
for marker in main.py comfy comfyui_version.py nodes.py custom_nodes models; do
    if [[ -e "$TARGET_ABS/$marker" ]]; then
        looks_like_comfyui=true
        break
    fi
done
if [[ "$looks_like_comfyui" != true ]]; then
    err "Target does not look like a ComfyUI install (no main.py/comfy/custom_nodes/models): $TARGET_ABS"
    err "Refusing to touch it. Point me at the ComfyUI data directory."
    exit 1
fi

# ---------------------------------------------------------------------------
# Plan: decide what stays and what moves
# ---------------------------------------------------------------------------

declare -a TO_MOVE=()
declare -a TO_KEEP=()

# Iterate every direct child (including dotfiles), NUL-safe, no recursion.
while IFS= read -r -d '' path; do
    name="${path##*/}"

    # Never move a backup folder (previous runs or the one we're about to make).
    if [[ "$name" == "$BACKUP_PREFIX"* ]]; then
        continue
    fi

    if in_array "$name" "${KEEP[@]}"; then
        TO_KEEP+=("$name")
    else
        TO_MOVE+=("$name")
    fi
done < <(find "$TARGET_ABS" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

# BACKUP_STAMP overrides the timestamp for deterministic backup naming (used by tests).
TS="${BACKUP_STAMP:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DIR="$TARGET_ABS/${BACKUP_PREFIX}${TS}"

info "=========================================================================="
info "ComfyUI legacy-install cleanup (reversible — moves, never deletes)"
info "=========================================================================="
info "Target : $TARGET_ABS"
info "Mode   : $MODE$( [[ "$MODE" == dry-run ]] && echo '   (no changes will be made — pass --apply to act)')"
info "Backup : $BACKUP_DIR"
info ""
info "KEEP in place (${#TO_KEEP[@]}):"
if [[ ${#TO_KEEP[@]} -eq 0 ]]; then
    info "  (none of the allowlisted entries are present)"
else
    for name in "${TO_KEEP[@]}"; do info "  keep  $name"; done
fi
info ""
info "MOVE into backup (${#TO_MOVE[@]}):"
if [[ ${#TO_MOVE[@]} -eq 0 ]]; then
    info "  (nothing to move — directory is already clean)"
else
    for name in "${TO_MOVE[@]}"; do info "  move  $name  ->  ${BACKUP_PREFIX}${TS}/$name"; done
fi
info ""

# Nothing to do?
if [[ ${#TO_MOVE[@]} -eq 0 ]]; then
    info "Nothing to move. Done."
    exit 0
fi

# ---------------------------------------------------------------------------
# Dry run stops here
# ---------------------------------------------------------------------------

if [[ "$MODE" == "dry-run" ]]; then
    info "DRY RUN — no changes made."
    info "Re-run with --apply to move the ${#TO_MOVE[@]} entr$( [[ ${#TO_MOVE[@]} -eq 1 ]] && echo y || echo ies) above into:"
    info "  $BACKUP_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

mkdir -p -- "$BACKUP_DIR"

moved=0
for name in "${TO_MOVE[@]}"; do
    src="$TARGET_ABS/$name"
    dst="$BACKUP_DIR/$name"
    if [[ -e "$dst" ]]; then
        err "Skipping '$name': destination already exists ($dst)"
        continue
    fi
    mv -- "$src" "$dst"
    info "moved  $name"
    moved=$((moved + 1))
done

info ""
info "Moved $moved entr$( [[ $moved -eq 1 ]] && echo y || echo ies) into:"
info "  $BACKUP_DIR"
info ""
info "--------------------------------------------------------------------------"
info "REVERSAL RECIPE — undo everything this run just did:"
info "--------------------------------------------------------------------------"
info "# Move each entry back into place:"
for name in "${TO_MOVE[@]}"; do
    printf '  mv -- %q %q\n' "$BACKUP_DIR/$name" "$TARGET_ABS/$name"
done
info ""
info "# Or move them all back at once (handles dotfiles), then remove the empty backup folder:"
printf '  find %q -mindepth 1 -maxdepth 1 -exec mv -t %q -- {} + && rmdir -- %q\n' \
    "$BACKUP_DIR" "$TARGET_ABS" "$BACKUP_DIR"
info ""
info "Once you've confirmed ComfyUI still runs, you can delete the backup folder"
info "to reclaim space:"
printf '  rm -rf -- %q\n' "$BACKUP_DIR"
info "Done."
