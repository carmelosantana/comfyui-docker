#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/cleanup-legacy-comfyui.sh"

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT
target="$workdir/ComfyUI"; mkdir -p "$target"/{models,input,output,custom_nodes,user,comfy,web}
touch "$target/main.py" "$target/requirements.txt" "$target/comfy/x.py" "$target/models/keep.bin"

# Dry-run must move nothing and mention the movers.
out="$(BACKUP_STAMP=TEST bash "$SCRIPT" --dry-run "$target")"
assert_true '[ -f "$target/main.py" ]' "dry-run leaves main.py in place"
assert_true 'echo "$out" | grep -q "main.py"' "dry-run lists main.py as a move candidate"
assert_true '! echo "$out" | grep -qx "models"' "dry-run does not list allowlisted models"

# Apply must move non-allowlisted entries into the backup, keep the allowlist.
BACKUP_STAMP=TEST bash "$SCRIPT" --apply "$target" >/dev/null
bak="$target/_legacy_backup_TEST"
assert_true '[ -d "$target/models" ]' "models kept"
assert_true '[ -d "$target/custom_nodes" ]' "custom_nodes kept"
assert_true '[ -f "$bak/main.py" ]' "main.py moved to backup"
assert_true '[ -f "$bak/requirements.txt" ]' "requirements.txt moved to backup"
assert_true '[ -d "$bak/comfy" ]' "comfy/ moved to backup"
assert_true '[ ! -e "$target/main.py" ]' "main.py gone from target root"

# Refuse a non-ComfyUI dir.
plain="$workdir/plain"; mkdir -p "$plain"; touch "$plain/hello.txt"
if BACKUP_STAMP=TEST bash "$SCRIPT" --apply "$plain" >/dev/null 2>&1; then
  rc=0; else rc=1; fi
assert_eq "1" "$rc" "refuses a dir that is not a ComfyUI install"

finish
