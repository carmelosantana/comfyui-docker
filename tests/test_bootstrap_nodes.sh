#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT
export CUSTOM_NODES_DIR="$workdir/cn"; mkdir -p "$CUSTOM_NODES_DIR"
export NODE_MANIFEST="$workdir/manifest.txt"
cat > "$NODE_MANIFEST" <<EOF
# comment line
https://github.com/kijai/ComfyUI-WanVideoWrapper
https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite abc123
EOF

# Fake git that records clones and simulates a successful clone by making the dir.
gitbin="$workdir/bin"; mkdir -p "$gitbin"
cat > "$gitbin/git" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$GIT_LOG"
if [ "$1" = "clone" ]; then
  # last arg is destination
  dest="${@: -1}"; mkdir -p "$dest"
fi
EOF
chmod +x "$gitbin/git"
export GIT_LOG="$workdir/git.log"; : > "$GIT_LOG"

# Pre-create one pack so it is skipped.
mkdir -p "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"

PATH="$gitbin:$PATH" bash "$HERE/../scripts/bootstrap-nodes.sh"
assert_eq "0" "$(grep -c 'ComfyUI-WanVideoWrapper' "$GIT_LOG" | tr -d '\n')" "existing pack not re-cloned"
assert_true 'grep -q "clone .*ComfyUI-VideoHelperSuite" "$GIT_LOG"' "absent pack cloned"
assert_true 'grep -q "checkout abc123" "$GIT_LOG"' "pinned ref checked out"

# Second run is a full no-op (both packs now present).
: > "$GIT_LOG"
PATH="$gitbin:$PATH" bash "$HERE/../scripts/bootstrap-nodes.sh"
assert_eq "0" "$(wc -l < "$GIT_LOG" | tr -d ' ')" "second run clones nothing"

finish
