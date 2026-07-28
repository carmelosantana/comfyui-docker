#!/usr/bin/env bash
set -euo pipefail

KEEP=(models input output custom_nodes user)

die() { echo "ERROR: $*" >&2; exit 1; }

mode="--dry-run"; target=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|--apply) mode="$arg" ;;
        -*) die "unknown flag: $arg" ;;
        *) target="$arg" ;;
    esac
done
[ -n "$target" ] || die "usage: $0 [--dry-run|--apply] <comfyui-dir>"
[ -d "$target" ] || die "not a directory: $target"
# Sanity: must look like a ComfyUI install.
if [ ! -f "$target/main.py" ] && [ ! -d "$target/comfy" ]; then
    die "does not look like a ComfyUI install (no main.py or comfy/): $target"
fi

stamp="${BACKUP_STAMP:-$(date +%Y%m%d-%H%M%S)}"
backup="$target/_legacy_backup_$stamp"

is_kept() {
    local name="$1" k
    for k in "${KEEP[@]}"; do [ "$name" = "$k" ] && return 0; done
    return 1
}

echo "Target:        $target"
echo "Mode:          $mode"
echo "Keep:          ${KEEP[*]}"
echo "Backup folder: $backup"
echo "----"

movers=()
for entry in "$target"/* "$target"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    [ "$name" = "$(basename "$backup")" ] && continue
    case "$name" in _legacy_backup_*) continue ;; esac
    if is_kept "$name"; then continue; fi
    movers+=("$name")
done

if [ "${#movers[@]}" -eq 0 ]; then
    echo "Nothing to move. Directory is already clean."
    exit 0
fi

for name in "${movers[@]}"; do echo "  move: $name"; done

if [ "$mode" = "--dry-run" ]; then
    echo "----"
    echo "Dry run only. Re-run with --apply to move the above into $backup"
    exit 0
fi

mkdir -p "$backup"
for name in "${movers[@]}"; do
    mv "$target/$name" "$backup/$name"
done
echo "----"
echo "Moved ${#movers[@]} entries into $backup"
echo "To reverse:"
echo "  for f in \"$backup\"/*; do mv \"\$f\" \"$target/\"; done && rmdir \"$backup\""
