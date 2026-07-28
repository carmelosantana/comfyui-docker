# ComfyUI Docker Ownership & Modernization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `carmelosantana/comfyui-docker` fork into an owned base image that ships ComfyUI-Manager v4+, reliably beats the stale-Manager shadowing bug, tracks ComfyUI core, publishes to GHCR, and carries research-backed RTX 3090 defaults plus two compose files and per-GPU docs.

**Architecture:** Fork of `lecode-official/comfyui-docker` (MIT). Image is `FROM pytorch/pytorch:*-runtime` with ARG-pinned ComfyUI + Manager cloned to fixed refs. A refactored, unit-tested `entrypoint.sh` fixes the Manager shadowing, trims the boot-time `chown`, installs node requirements once via a sentinel, and seeds a permissive-enough Manager `config.ini`. Two GitHub Actions workflows build/publish to GHCR and auto-bump the ComfyUI version. Node packs are installed on demand by an opt-in bootstrap script; a separate reversible script cleans up the legacy install directory.

**Tech Stack:** Docker, Bash (POSIX-ish, `bash`), GitHub Actions, ComfyUI 0.8.x, ComfyUI-Manager 4.x, PyTorch 2.9.1 / CUDA 12.8 runtime base. Shell tests use a dependency-free pure-bash harness (no bats/shellcheck required).

## Global Constraints

- **Git identity (do not override):** `Carmelo Santana <me@carmelosantana.com>` (the global default).
- **Do NOT push** any commit or image until Carmelo explicitly approves. All work is local commits on branch `design/ownership-modernization` (or task branches off it).
- **License:** upstream is MIT (Copyright (c) 2024 David Neumann). Preserve the MIT LICENSE text and original copyright line; add Carmelo's copyright line; keep a "forked from" attribution in the README.
- **lecode env-var compatibility (keep identical):** `IMAGE_TAG`, `USER_ID` (default `1000`), `GROUP_ID` (default `1000`), `MODELS_PATH`, `CUSTOM_NODES_PATH`, `OUTPUT_PATH`. New vars are additive only.
- **Image name:** `ghcr.io/carmelosantana/comfyui-docker`. In CI use `ghcr.io/${{ github.repository }}` so the fork resolves automatically.
- **Base image pin:** `PYTORCH_VERSION=2.9.1`, `CUDA_VERSION=12.8`, `CUDNN_VERSION=9`. ComfyUI pinned via `COMFYUI_REF` (tag or SHA). Manager pinned via `COMFYUI_MANAGER_VERSION` (v4+, default `4.0.5`).
- **3090 defaults (verified vs `comfy/cli_args.py`, do not deviate):** runtime flags `--use-pytorch-cross-attention --reserve-vram 1`; env `PYTORCH_ALLOC_CONF=expandable_segments:True`. Never bake `--highvram`, `--fast`, `--fp8_*-unet`, or the non-existent `--normalvram`.
- **Build host reality:** this dev box has no nvidia container runtime, so all local runtime verification is CPU-only (`--cpu`). Real-GPU validation happens later on the TrueNAS box (out of scope here).
- **`-sage` variant is a separate fast-follow plan** (Carmelo reviews the approach first). Do NOT add sage build steps or `-sage` CI tags in this plan.

## File Structure

```
comfyui-docker/
├─ Dockerfile                         # MOVED from source/Dockerfile → repo root (so `docker build .` works)
├─ .dockerignore                      # CREATE — keep build context small
├─ source/
│  ├─ entrypoint.sh                   # MODIFY — refactor into sourceable functions + fixes
│  └─ manager-config.ini              # CREATE — default Manager config (security level etc.)
├─ scripts/
│  ├─ bootstrap-nodes.sh              # CREATE — opt-in first-boot node-pack installer
│  ├─ node-manifest.txt               # CREATE — editable list of packs (url[ ref])
│  └─ cleanup-legacy-comfyui.sh       # CREATE — reversible legacy-install cleanup
├─ tests/
│  ├─ lib.sh                          # CREATE — tiny assert harness (no deps)
│  ├─ test_entrypoint.sh              # CREATE — unit tests for entrypoint functions
│  ├─ test_bootstrap_nodes.sh         # CREATE — unit tests for bootstrap
│  └─ test_cleanup_legacy.sh          # CREATE — unit tests for cleanup
├─ docker-compose.yml                 # CREATE — generic/portable
├─ docker-compose-3090-sample.yml     # CREATE — Carmelo's 1:1 stack + perf command/env
├─ .env.example                       # CREATE — documents all env vars
├─ .github/workflows/
│  ├─ build.yml                       # CREATE (replaces build-and-publish.yml) — build+smoke+publish
│  └─ bump.yml                        # CREATE — scheduled ComfyUI version bump PR
├─ docs/gpu-settings.md               # CREATE — 3090 defaults + per-GPU table
├─ README.md                          # MODIFY — quickstart, composes, update flow, attribution
├─ LICENSE                            # MODIFY — add Carmelo's copyright line
└─ CHANGELOG.md                       # MODIFY — add an "Ownership fork" entry
```

Upstream files to delete: `.github/workflows/build-and-publish.yml` (replaced), `compose.yml` (replaced by the two new composes), `CONTRIBUTORS.md` and `.cspell.json` (upstream-specific; optional to keep — this plan removes them for clarity).

---

## Task 1: Ownership baseline (LICENSE, README attribution, prune upstream-only files)

**Files:**
- Modify: `LICENSE`
- Modify: `README.md` (top attribution block only; full rewrite is Task 12)
- Modify: `CHANGELOG.md`
- Delete: `CONTRIBUTORS.md`, `.cspell.json`, `compose.yml`, `.github/workflows/build-and-publish.yml`

**Interfaces:**
- Produces: a clean fork baseline. No code interfaces.

- [ ] **Step 1: Add Carmelo's copyright to LICENSE (keep the MIT body and original line)**

Edit `LICENSE` so the copyright block reads exactly:

```
MIT License

Copyright (c) 2024 David Neumann
Copyright (c) 2026 Carmelo Santana

Permission is hereby granted, free of charge, to any person obtaining a copy
```

(Leave the rest of the MIT text unchanged.)

- [ ] **Step 2: Add a fork-attribution block at the very top of README.md**

Prepend to `README.md` (above the existing content, which Task 12 will fully replace):

```markdown
# ComfyUI Docker (carmelosantana)

> Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
> (MIT © David Neumann). This fork ships ComfyUI-Manager **v4+**, fixes the stale-Manager
> shadowing bug on persistent `custom_nodes` mounts, adds RTX 3090 runtime defaults, and
> publishes to `ghcr.io/carmelosantana/comfyui-docker`.
```

- [ ] **Step 3: Add a CHANGELOG entry**

Prepend under the top heading of `CHANGELOG.md`:

```markdown
## [Unreleased] — Ownership fork (carmelosantana)

- Forked from lecode-official/comfyui-docker (MIT).
- Ship ComfyUI-Manager v4+ and fix the custom_nodes Manager-shadowing bug.
- Add RTX 3090 runtime defaults, generic + 3090 compose files, per-GPU docs.
- New CI: build/smoke/publish to GHCR + scheduled ComfyUI version bump.
```

- [ ] **Step 4: Remove upstream-only files**

```bash
git rm CONTRIBUTORS.md .cspell.json compose.yml .github/workflows/build-and-publish.yml
```

- [ ] **Step 5: Commit**

```bash
git add LICENSE README.md CHANGELOG.md
git commit -m "chore: establish ownership baseline (attribution, license, prune upstream files)"
```

---

## Task 2: Dockerfile modernization (root Dockerfile, COMFYUI_REF, config copy, healthcheck)

**Files:**
- Create: `Dockerfile` (via `git mv source/Dockerfile Dockerfile`, then edit)
- Create: `.dockerignore`
- Modify: (paths inside the moved Dockerfile)

**Interfaces:**
- Consumes: `source/entrypoint.sh` (Task 3+), `source/manager-config.ini` (Task 6).
- Produces: an image whose entrypoint is `/entrypoint.sh`, ComfyUI at `/opt/comfyui`, Manager baked at `/opt/comfyui-manager`, default config at `/opt/comfyui-manager-config.ini`. Build ARGs: `PYTORCH_VERSION`, `CUDA_VERSION`, `CUDNN_VERSION`, `COMFYUI_REF`, `COMFYUI_MANAGER_VERSION`.

- [ ] **Step 1: Move the Dockerfile to repo root**

```bash
git mv source/Dockerfile Dockerfile
```

- [ ] **Step 2: Replace the Dockerfile contents**

Write `Dockerfile` exactly as:

```dockerfile
# syntax=docker/dockerfile:1

ARG PYTORCH_VERSION=2.9.1
ARG CUDA_VERSION=12.8
ARG CUDNN_VERSION=9

FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime

# ComfyUI is pinned by a ref (tag like "v0.8.2" or a commit SHA); Manager is pinned by a tag (v4+).
ARG COMFYUI_REF=v0.8.2
ARG COMFYUI_MANAGER_VERSION=4.0.5

# Keep COMFYUI_VERSION as an alias so CI version-extraction and image labels stay stable.
ARG COMFYUI_VERSION=0.8.2

RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends \
        git \
        sudo \
        curl \
        libgl1-mesa-glx \
        libglib2.0-0 && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*

RUN git clone https://github.com/Comfy-Org/ComfyUI.git /opt/comfyui && \
    cd /opt/comfyui && \
    git checkout "${COMFYUI_REF}"

RUN git clone https://github.com/Comfy-Org/ComfyUI-Manager.git /opt/comfyui-manager && \
    cd /opt/comfyui-manager && \
    git checkout "${COMFYUI_MANAGER_VERSION}"

RUN pip install \
    --requirement /opt/comfyui/requirements.txt \
    --requirement /opt/comfyui-manager/requirements.txt

# Default Manager config, seeded by the entrypoint only when the user has none.
COPY source/manager-config.ini /opt/comfyui-manager-config.ini

WORKDIR /opt/comfyui

EXPOSE 8188

# Healthcheck lets Portainer show real health and enables depends_on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
    CMD curl --fail --silent http://localhost:8188/ >/dev/null || exit 1

COPY source/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
```

- [ ] **Step 3: Create `.dockerignore`**

Write `.dockerignore`:

```
.git
data
docs
tests
*.md
docker-compose*.yml
.env
.env.example
```

- [ ] **Step 4: Verify the build succeeds** (entrypoint/config exist as upstream versions until later tasks refine them — build must still pass)

Because Task 3+ refine `entrypoint.sh` and Task 6 adds `manager-config.ini`, create a placeholder config now so the `COPY` resolves:

```bash
printf '[default]\n' > source/manager-config.ini
```

Run:

```bash
docker build -t comfyui-test .
```

Expected: build completes with `naming to docker.io/library/comfyui-test done` (downloads the pytorch runtime base + clones repos; several minutes).

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore source/manager-config.ini
git commit -m "feat: root Dockerfile with COMFYUI_REF, curl+healthcheck, manager-config copy"
```

---

## Task 3: Entrypoint refactor + Manager backup-then-replace (TDD)

**Files:**
- Modify: `source/entrypoint.sh` (refactor into sourceable functions; add `link_manager`)
- Create: `tests/lib.sh`
- Create: `tests/test_entrypoint.sh`

**Interfaces:**
- Produces (consumed by later entrypoint tasks + tests):
  - `link_manager` — env inputs `CUSTOM_NODES_DIR`, `MANAGER_SRC`. Ensures `$CUSTOM_NODES_DIR/ComfyUI-Manager` is a symlink → `$MANAGER_SRC`. If a real (non-symlink) `ComfyUI-Manager` exists, move it once to `ComfyUI-Manager.bak` (if no `.bak` yet), else `rm -rf` the stale copy. Removes a pre-existing symlink before recreating.
  - The file must be **sourceable without executing** (guarded `main`).

- [ ] **Step 1: Write the test harness `tests/lib.sh`**

```bash
#!/usr/bin/env bash
# Minimal dependency-free assertion harness.
set -u
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" != "$actual" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: ${msg} (expected='${expected}' actual='${actual}')"
  else
    echo "  ok:   ${msg}"
  fi
}

assert_true() {
  local cond_desc="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if eval "$1"; then
    echo "  ok:   ${cond_desc}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: ${cond_desc} (condition false: $1)"
  fi
}

finish() {
  echo "---- ${TESTS_RUN} checks, ${TESTS_FAILED} failed ----"
  [ "$TESTS_FAILED" -eq 0 ]
}
```

- [ ] **Step 2: Write the failing test `tests/test_entrypoint.sh` (link_manager cases)**

```bash
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

finish
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `bash tests/test_entrypoint.sh`
Expected: FAIL — `link_manager: command not found` (or all checks fail), because `source/entrypoint.sh` isn't refactored yet.

- [ ] **Step 4: Refactor `source/entrypoint.sh` into sourceable functions and implement `link_manager`**

Replace `source/entrypoint.sh` with:

```bash
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_entrypoint.sh`
Expected: `---- 7 checks, 0 failed ----` (exit 0).

- [ ] **Step 6: Commit**

```bash
git add source/entrypoint.sh tests/lib.sh tests/test_entrypoint.sh
git commit -m "feat(entrypoint): sourceable functions + Manager backup-then-replace (fixes v4 shadowing)"
```

---

## Task 4: Entrypoint lean chown (skip the big mounts) (TDD)

**Files:**
- Modify: `source/entrypoint.sh` (add `dirs_to_chown` + `chown_app_dirs`; wire USER_ID/GROUP_ID exec)
- Modify: `tests/test_entrypoint.sh` (append cases)

**Interfaces:**
- Consumes: `COMFYUI_DIR`, `MANAGER_SRC`.
- Produces: `dirs_to_chown` — prints, one per line, the directories that should be recursively chowned. MUST include `$MANAGER_SRC` and the ComfyUI app dirs, and MUST NOT include `$COMFYUI_DIR/models`, `$COMFYUI_DIR/output`, `$COMFYUI_DIR/input`, or `$COMFYUI_DIR/custom_nodes` (host-owned bind mounts; recursively chowning `models` on every boot is the perf bug we fix).

- [ ] **Step 1: Append failing tests to `tests/test_entrypoint.sh`** (before `finish`)

```bash
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
```

- [ ] **Step 2: Run tests and confirm the new cases fail**

Run: `bash tests/test_entrypoint.sh`
Expected: FAIL — `dirs_to_chown: command not found` for the new checks.

- [ ] **Step 3: Add `dirs_to_chown` + `chown_app_dirs` to `source/entrypoint.sh`** (insert after `link_manager`)

```bash
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
    # Top-level files in the app dir (main.py, etc.) — cheap, chown the app root shallowly.
    echo "$COMFYUI_DIR"
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
}
```

Note: `dirs_to_chown` echoes `$COMFYUI_DIR` itself last; `chown --recursive` on it would re-descend into the mounts. To keep the exclusion meaningful, change the final `echo "$COMFYUI_DIR"` to shallow files only by having `chown_app_dirs` treat the app root specially. Implement the app-root line as a non-recursive chown of `$COMFYUI_DIR` and its top-level regular files:

Replace the final `echo "$COMFYUI_DIR"` in `dirs_to_chown` with nothing (drop it), and in `chown_app_dirs` add after the loop:

```bash
    # Shallow chown of the app root and its top-level files (not the mounts within).
    chown "$uid:$gid" "$COMFYUI_DIR" 2>/dev/null || true
    find "$COMFYUI_DIR" -maxdepth 1 -type f -exec chown "$uid:$gid" {} + 2>/dev/null || true
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_entrypoint.sh`
Expected: `---- 13 checks, 0 failed ----`.

- [ ] **Step 5: Commit**

```bash
git add source/entrypoint.sh tests/test_entrypoint.sh
git commit -m "perf(entrypoint): lean chown that skips the large host bind mounts"
```

---

## Task 5: Entrypoint first-run sentinel for node requirements (TDD)

**Files:**
- Modify: `source/entrypoint.sh` (add `install_node_requirements`)
- Modify: `tests/test_entrypoint.sh` (append cases)

**Interfaces:**
- Consumes: `CUSTOM_NODES_DIR`; env `FORCE_NODE_REQS` (optional, `1` to force); a `pip` on PATH.
- Produces: `install_node_requirements` — for each `"$CUSTOM_NODES_DIR"/*/requirements.txt` (excluding `ComfyUI-Manager`), runs `pip install --requirement <file>` only if the sentinel `"$CUSTOM_NODES_DIR/.requirements-installed"` is absent OR `FORCE_NODE_REQS=1`. Writes the sentinel afterward. Second unforced run is a no-op.

- [ ] **Step 1: Append failing tests to `tests/test_entrypoint.sh`** (before `finish`)

```bash
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
```

- [ ] **Step 2: Run tests and confirm the new cases fail**

Run: `bash tests/test_entrypoint.sh`
Expected: FAIL — `install_node_requirements: command not found`.

- [ ] **Step 3: Add `install_node_requirements` to `source/entrypoint.sh`** (after `chown_app_dirs`)

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_entrypoint.sh`
Expected: `---- 17 checks, 0 failed ----`.

- [ ] **Step 5: Commit**

```bash
git add source/entrypoint.sh tests/test_entrypoint.sh
git commit -m "perf(entrypoint): install node requirements once via a sentinel"
```

---

## Task 6: Manager config seeding + default config file (TDD)

**Files:**
- Modify: `source/manager-config.ini` (real content, replacing the Task 2 placeholder)
- Modify: `source/entrypoint.sh` (add `seed_manager_config`; wire full `main`)
- Modify: `tests/test_entrypoint.sh` (append cases)

**Interfaces:**
- Consumes: `MANAGER_CONFIG_SRC`, `COMFYUI_DIR`.
- Produces: `seed_manager_config` — ensures a Manager config exists at the Manager's expected user path so arbitrary-URL model installs are not blocked. Copies `MANAGER_CONFIG_SRC` to the destination **only if the destination does not already exist** (never clobber a user's config). Destination path: `"$COMFYUI_DIR/user/default/ComfyUI-Manager/config.ini"`.

> IMPLEMENTATION NOTE (concrete, not a placeholder): before writing `source/manager-config.ini`, confirm the exact config keys/location for the pinned Manager version by reading them from a built image:
> `docker run --rm --entrypoint bash comfyui-test -lc 'find /opt/comfyui-manager -name "config.ini*" -o -name "*.ini" | head; sed -n "1,60p" /opt/comfyui-manager/**/config.ini 2>/dev/null'`
> Confirm the key that controls arbitrary-URL/model security (documented as `security_level`) and the destination path the Manager reads (`user/default/ComfyUI-Manager/config.ini` in v4). Use the real key names found there. The values below reflect the documented v4 keys; adjust names if the in-image sample differs.

- [ ] **Step 1: Write the real `source/manager-config.ini`**

```ini
[default]
# Permissive enough for programmatic control by ComfyUI-MCP:
# allow arbitrary-URL model installs and git-URL / pip installs from the API.
# See docs/gpu-settings.md and README for the security rationale.
security_level = weak
network_mode = public
```

- [ ] **Step 2: Append failing tests to `tests/test_entrypoint.sh`** (before `finish`)

```bash
# --- Task 6: seed_manager_config copies only when absent ---
COMFYUI_DIR="$workdir/opt2"; mkdir -p "$COMFYUI_DIR"
MANAGER_CONFIG_SRC="$workdir/default-config.ini"; printf '[default]\nsecurity_level = weak\n' > "$MANAGER_CONFIG_SRC"
dest="$COMFYUI_DIR/user/default/ComfyUI-Manager/config.ini"
seed_manager_config
assert_true '[ -f "$dest" ]' "config seeded when absent"
assert_eq "weak" "$(sed -n 's/^security_level = //p' "$dest")" "seeded config has security_level weak"
# Now a user-modified config must NOT be overwritten.
printf '[default]\nsecurity_level = normal\n' > "$dest"
seed_manager_config
assert_eq "normal" "$(sed -n 's/^security_level = //p' "$dest")" "existing user config preserved"
```

- [ ] **Step 3: Run tests and confirm failure**

Run: `bash tests/test_entrypoint.sh`
Expected: FAIL — `seed_manager_config: command not found`.

- [ ] **Step 4: Add `seed_manager_config` and finalize `main`/exec in `source/entrypoint.sh`**

Add after `install_node_requirements`:

```bash
seed_manager_config() {
    local dest_dir="$COMFYUI_DIR/user/default/ComfyUI-Manager"
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
```

Replace `main` and `run_comfyui` with the final wiring (USER_ID/GROUP_ID logic preserved from upstream, now calling our functions):

```bash
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
```

Delete the old `run_comfyui` function (now folded into `main`). Keep the `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi` guard at the end.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test_entrypoint.sh`
Expected: `---- 20 checks, 0 failed ----`.

- [ ] **Step 6: Rebuild image and confirm it still builds with the real config**

Run: `docker build -t comfyui-test .`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add source/entrypoint.sh source/manager-config.ini tests/test_entrypoint.sh
git commit -m "feat(entrypoint): seed permissive Manager config so arbitrary-URL installs work"
```

---

## Task 7: Node-pack bootstrap script (TDD)

**Files:**
- Create: `scripts/bootstrap-nodes.sh`
- Create: `scripts/node-manifest.txt`
- Create: `tests/test_bootstrap_nodes.sh`

**Interfaces:**
- Consumes: env `CUSTOM_NODES_DIR`, `NODE_MANIFEST` (path); a `git` on PATH.
- Produces: `scripts/bootstrap-nodes.sh` — reads `NODE_MANIFEST` (lines: `<git-url>[ <ref>]`, `#` comments and blanks ignored); for each pack, if the target dir (basename of the repo, `.git` stripped) is absent under `CUSTOM_NODES_DIR`, `git clone` it (and `git checkout <ref>` if given); if present, skip. Idempotent. Gated by `BOOTSTRAP_NODES=1` when invoked from the entrypoint (the script itself always runs when called directly).

- [ ] **Step 1: Write `scripts/node-manifest.txt`**

```
# ComfyUI node packs the image supports installing cleanly.
# Format: <git-url> [<git-ref>]   (ref optional; blank = default branch)
https://github.com/kijai/ComfyUI-WanVideoWrapper
https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite
https://github.com/diodiogod/TTS-Audio-Suite
https://github.com/jnxmx/ComfyUI_HuggingFace_Downloader
```

- [ ] **Step 2: Write the failing test `tests/test_bootstrap_nodes.sh`**

```bash
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
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `bash tests/test_bootstrap_nodes.sh`
Expected: FAIL — script does not exist yet (`No such file or directory`).

- [ ] **Step 4: Write `scripts/bootstrap-nodes.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-/opt/comfyui/custom_nodes}"
NODE_MANIFEST="${NODE_MANIFEST:-/opt/scripts/node-manifest.txt}"

if [ ! -f "$NODE_MANIFEST" ]; then
    echo "Node manifest not found at $NODE_MANIFEST; nothing to bootstrap."
    exit 0
fi

mkdir -p "$CUSTOM_NODES_DIR"

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [ -z "$line" ] && continue
    url="$(echo "$line" | awk '{print $1}')"
    ref="$(echo "$line" | awk '{print $2}')"
    name="$(basename "$url")"; name="${name%.git}"
    dest="$CUSTOM_NODES_DIR/$name"
    if [ -e "$dest" ]; then
        echo "Skipping $name (already present)."
        continue
    fi
    echo "Cloning $name..."
    git clone "$url" "$dest"
    if [ -n "$ref" ]; then
        git -C "$dest" checkout "$ref"
    fi
done < "$NODE_MANIFEST"

echo "Node bootstrap complete."
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_bootstrap_nodes.sh`
Expected: `---- 4 checks, 0 failed ----`.

- [ ] **Step 6: Commit**

```bash
chmod +x scripts/bootstrap-nodes.sh
git add scripts/bootstrap-nodes.sh scripts/node-manifest.txt tests/test_bootstrap_nodes.sh
git commit -m "feat(scripts): idempotent opt-in node-pack bootstrap + manifest"
```

---

## Task 8: Reversible legacy-install cleanup script (TDD)

**Files:**
- Create: `scripts/cleanup-legacy-comfyui.sh`
- Create: `tests/test_cleanup_legacy.sh`

**Interfaces:**
- Consumes: CLI `cleanup-legacy-comfyui.sh [--dry-run|--apply] <target-dir>` (default `--dry-run`).
- Produces: moves every top-level entry NOT in the keep-allowlist (`models input output custom_nodes user`) into `<target>/_legacy_backup_<stamp>/`. Never deletes. Refuses if target isn't a dir or doesn't look like a ComfyUI install (no `main.py` and no `comfy/`). Prints the reversal recipe. Stamp comes from `date +%Y%m%d-%H%M%S` at runtime (real box), but is overridable via `BACKUP_STAMP` for deterministic tests.

- [ ] **Step 1: Write the failing test `tests/test_cleanup_legacy.sh`**

```bash
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
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash tests/test_cleanup_legacy.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write `scripts/cleanup-legacy-comfyui.sh`**

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_cleanup_legacy.sh`
Expected: `---- 11 checks, 0 failed ----`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/cleanup-legacy-comfyui.sh
git add scripts/cleanup-legacy-comfyui.sh tests/test_cleanup_legacy.sh
git commit -m "feat(scripts): reversible legacy ComfyUI install cleanup (dry-run default)"
```

---

## Task 9: Compose files + `.env.example`

**Files:**
- Create: `docker-compose.yml`
- Create: `docker-compose-3090-sample.yml`
- Create: `.env.example`

**Interfaces:**
- Consumes: the published image `ghcr.io/carmelosantana/comfyui-docker` and the env-var contract.
- Produces: two validated compose files + a documented `.env.example`.

- [ ] **Step 1: Write the generic `docker-compose.yml`**

```yaml
name: comfyui

services:
  comfyui:
    image: ghcr.io/carmelosantana/comfyui-docker:${IMAGE_TAG:-latest}
    container_name: comfyui
    restart: unless-stopped
    environment:
      USER_ID: "${USER_ID:-1000}"
      GROUP_ID: "${GROUP_ID:-1000}"
    ports:
      - "${COMFYUI_PORT:-8188}:8188"
    volumes:
      - ${MODELS_PATH:-./data/models}:/opt/comfyui/models:rw
      - ${CUSTOM_NODES_PATH:-./data/custom_nodes}:/opt/comfyui/custom_nodes:rw
      - ${OUTPUT_PATH:-./data/output}:/opt/comfyui/output:rw
      - ${INPUT_PATH:-./data/input}:/opt/comfyui/input:rw
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${GPU_COUNT:-1}
              capabilities: [gpu]
```

- [ ] **Step 2: Write the `docker-compose-3090-sample.yml`** (1:1 with Carmelo's live stack; only the image owner changed, plus the perf `command`/env)

```yaml
name: comfyui-docker

# Opinionated sample for Carmelo's TrueNAS box (single RTX 3090, 24GB).
# A 1:1 replacement for the old lecode stack: only the image owner changed, plus a
# research-backed 3090 command/env. Drop this into Portainer over the old stack.
services:
  comfyui:
    image: ghcr.io/carmelosantana/comfyui-docker:${IMAGE_TAG:-latest}
    container_name: comfyui-lecode
    restart: unless-stopped
    extra_hosts:
      - "ollama:host-gateway"
    environment:
      USER_ID: "${USER_ID:-1000}"
      GROUP_ID: "${GROUP_ID:-1000}"
      PYTORCH_ALLOC_CONF: "expandable_segments:True"
    ports:
      - "8188:8188"
    volumes:
      - ${MODELS_PATH:-/mnt/Data/ComfyUI/models}:/opt/comfyui/models:rw
      - ${CUSTOM_NODES_PATH:-/mnt/Data/ComfyUI/custom_nodes}:/opt/comfyui/custom_nodes:rw
      - ${OUTPUT_PATH:-/mnt/Data/ComfyUI/output}:/opt/comfyui/output:rw
      - /mnt/Data/ComfyUI/input:/opt/comfyui/input:rw
      - /mnt/Data/ComfyUI/user/default/workflows:/opt/comfyui/user/default/workflows:rw
    command:
      - "--use-pytorch-cross-attention"
      - "--reserve-vram"
      - "1"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

- [ ] **Step 3: Write `.env.example`**

```dotenv
# Copy to .env and adjust. All values have sane defaults in the compose files.
IMAGE_TAG=latest

# Host user/group that should own files created in the mounts (avoids root-owned files).
USER_ID=1000
GROUP_ID=1000

# Generic compose paths (default under ./data). For the 3090 sample these default to /mnt/Data/ComfyUI/*.
MODELS_PATH=./data/models
CUSTOM_NODES_PATH=./data/custom_nodes
OUTPUT_PATH=./data/output
INPUT_PATH=./data/input

# Port on the host.
COMFYUI_PORT=8188

# GPUs to reserve for the generic compose.
GPU_COUNT=1

# Torch 2.9 allocator tuning (cuts fragmentation OOMs on long video decodes).
PYTORCH_ALLOC_CONF=expandable_segments:True

# Opt-in: bootstrap the supported node packs into the mounted custom_nodes on first boot.
# (Wire-up is documented in the README; leave unset to skip.)
BOOTSTRAP_NODES=
```

- [ ] **Step 4: Validate both compose files**

```bash
docker compose -f docker-compose.yml config >/dev/null && echo "generic OK"
docker compose -f docker-compose-3090-sample.yml config >/dev/null && echo "3090 sample OK"
```

Expected: `generic OK` and `3090 sample OK` (no errors).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml docker-compose-3090-sample.yml .env.example
git commit -m "feat: generic + 3090 compose files and .env.example"
```

---

## Task 10: CI — build, CPU smoke test, publish (`build.yml`)

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: root `Dockerfile`, its ARG defaults.
- Produces: a workflow that builds on PR/push/tag/schedule/dispatch, runs a CPU smoke test asserting Manager v4, and pushes to `ghcr.io/${{ github.repository }}` on non-PR events.

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: Build & Publish

on:
  push:
    branches: [main]
    tags: ['v[0-9]+.[0-9]+.[0-9]+']
  pull_request:
    branches: [main]
  schedule:
    - cron: '17 6 * * 1'   # weekly rebuild so "latest" tracks base-image/security updates
  workflow_dispatch: {}

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Read version ARGs from Dockerfile
        id: vers
        run: |
          comfyui="$(grep -oP '^ARG COMFYUI_VERSION=\K.*' Dockerfile)"
          echo "comfyui=${comfyui}" >> "$GITHUB_OUTPUT"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build image (load locally for smoke test)
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: comfyui-ci:smoke
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke test — boots on :8188 and Manager reports v4+
        run: |
          docker run -d --name smoke -p 8188:8188 comfyui-ci:smoke --cpu
          echo "Waiting for ComfyUI to answer on :8188..."
          for i in $(seq 1 60); do
            if curl -fsS http://localhost:8188/ >/dev/null 2>&1; then ok=1; break; fi
            sleep 5
          done
          [ "${ok:-}" = "1" ] || { echo "ComfyUI did not start"; docker logs smoke; exit 1; }
          ver="$(docker exec smoke git -C /opt/comfyui-manager describe --tags --always)"
          echo "Manager version: $ver"
          case "$ver" in 4.*|v4.*) echo "Manager v4+ OK" ;; *) echo "Manager is NOT v4+: $ver"; docker logs smoke; exit 1 ;; esac
          docker rm -f smoke

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Tags & labels
        id: meta
        if: github.event_name != 'pull_request'
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
            type=raw,value=comfyui-${{ steps.vers.outputs.comfyui }},enable=${{ github.ref == 'refs/heads/main' }}
            type=sha
            type=semver,pattern={{version}}
            type=semver,pattern={{version}}-comfyui-${{ steps.vers.outputs.comfyui }}
          labels: |
            org.opencontainers.image.title=ComfyUI Docker (carmelosantana)
            org.opencontainers.image.authors=Carmelo Santana <me@carmelosantana.com>

      - name: Build & push
        id: push
        if: github.event_name != 'pull_request'
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Attest provenance
        if: github.event_name != 'pull_request'
        uses: actions/attest-build-provenance@v3
        with:
          subject-name: ghcr.io/${{ github.repository }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
```

- [ ] **Step 2: Validate the workflow YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('build.yml YAML OK')"
```

Expected: `build.yml YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build + CPU smoke test (asserts Manager v4) + GHCR publish"
```

---

## Task 11: CI — scheduled ComfyUI version bump (`bump.yml`)

**Files:**
- Create: `.github/workflows/bump.yml`

**Interfaces:**
- Consumes: the `ARG COMFYUI_REF` / `ARG COMFYUI_VERSION` lines in `Dockerfile`, the GitHub API.
- Produces: a weekly job that opens a PR bumping ComfyUI to the latest release when the Dockerfile is behind.

- [ ] **Step 1: Write `.github/workflows/bump.yml`**

```yaml
name: Bump ComfyUI version

on:
  schedule:
    - cron: '23 5 * * 1'   # weekly, before the build cron
  workflow_dispatch: {}

jobs:
  bump:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Determine current vs latest ComfyUI
        id: check
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          current="$(grep -oP '^ARG COMFYUI_VERSION=\K.*' Dockerfile)"
          latest_tag="$(gh api repos/Comfy-Org/ComfyUI/releases/latest --jq .tag_name)"
          latest="${latest_tag#v}"
          echo "current=$current" >> "$GITHUB_OUTPUT"
          echo "latest=$latest" >> "$GITHUB_OUTPUT"
          echo "latest_tag=$latest_tag" >> "$GITHUB_OUTPUT"
          if [ "$current" != "$latest" ]; then echo "changed=1" >> "$GITHUB_OUTPUT"; else echo "changed=0" >> "$GITHUB_OUTPUT"; fi

      - name: Apply bump
        if: steps.check.outputs.changed == '1'
        run: |
          sed -i "s/^ARG COMFYUI_REF=.*/ARG COMFYUI_REF=${{ steps.check.outputs.latest_tag }}/" Dockerfile
          sed -i "s/^ARG COMFYUI_VERSION=.*/ARG COMFYUI_VERSION=${{ steps.check.outputs.latest }}/" Dockerfile

      - name: Open PR
        if: steps.check.outputs.changed == '1'
        uses: peter-evans/create-pull-request@v7
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          branch: bump/comfyui-${{ steps.check.outputs.latest }}
          title: "chore: bump ComfyUI to ${{ steps.check.outputs.latest_tag }}"
          body: |
            Automated bump from ComfyUI ${{ steps.check.outputs.current }} to ${{ steps.check.outputs.latest }}.
            Merging triggers a rebuild + publish of `latest` and the pinned version tags.
          commit-message: "chore: bump ComfyUI to ${{ steps.check.outputs.latest_tag }}"
```

- [ ] **Step 2: Validate the workflow YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/bump.yml')); print('bump.yml YAML OK')"
```

Expected: `bump.yml YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/bump.yml
git commit -m "ci: weekly PR to bump ComfyUI to the latest release"
```

---

## Task 12: Docs — README rewrite + per-GPU settings

**Files:**
- Modify: `README.md` (full body under the Task 1 attribution block)
- Create: `docs/gpu-settings.md`

**Interfaces:**
- Produces: user-facing docs. No code interfaces.

- [ ] **Step 1: Write `docs/gpu-settings.md`** (values verified against `comfy/cli_args.py`)

```markdown
# Per-GPU runtime settings

These are **boot flags** appended to ComfyUI's `main.py` (via the compose `command:`) and a
couple of env vars. They were verified against ComfyUI's `comfy/cli_args.py`. Golden rule for a
24 GB card: **pass no VRAM-mode flag** and let ComfyUI's DynamicVRAM/smart-memory manage.

## RTX 3090 (24 GB, Ampere) — the defaults in `docker-compose-3090-sample.yml`

- `command: ["--use-pytorch-cross-attention", "--reserve-vram", "1"]`
- `environment: PYTORCH_ALLOC_CONF=expandable_segments:True`

Why these and not the usual cargo-cult:
- **No `--highvram`/`--gpu-only`:** pinning a ~16 GB fp8 model + a TTS model + video VAE decode
  invites OOM. Smart memory already keeps things resident when they fit.
- **No `--fast` / `--fp8_*-unet`:** Ampere (sm_86) has **no fp8 tensor cores** — fp8 is
  storage-only (saves VRAM, zero compute speedup) and `--fast` is "untested / may degrade quality".
- **No `--normalvram`:** that flag does not exist and will crash startup. "Normal" = no flag.
- `--use-pytorch-cross-attention` uses torch SDPA (flash kernels) with **no extra deps**.
- `--reserve-vram 1` is a small OS safety margin; drop to `0` on a fully dedicated headless GPU.
- `expandable_segments:True` cuts fragmentation OOMs on long video decodes (torch 2.9 name;
  use `PYTORCH_CUDA_ALLOC_CONF` on older torch).

The one real Ampere speedup for video, `--use-sage-attention`, needs `sageattention`+`triton`
compiled into the image — shipped as a separate `-sage` image variant (see the roadmap).

## Per-GPU table

| GPU (arch) | VRAM mode | Attention | Precision notes | reserve-vram | Other |
|---|---|---|---|---|---|
| RTX 3090 24 GB (Ampere) | none (default) | `--use-pytorch-cross-attention` | bf16 native; fp8 = storage-only, no speedup | `1` (0 if dedicated) | `expandable_segments:True`; never `--highvram`/`--fast` |
| RTX 4090 24 GB (Ada) | none (default) | `--use-pytorch-cross-attention` (+sage if built) | native fp8 tensor cores → `--fast fp8_matrix_mult`/`fp16_accumulation` actually help | `1` | fp8 gives real speedup here |
| RTX 4080 16 GB (Ada) | none (default; auto-offload) | `--use-pytorch-cross-attention` | prefer fp8 model weights to fit 16 GB; native fp8 speedup | `0.5`–`1` | more offload/tiled VAE |
| RTX 3060 12 GB (Ampere) | none (expect auto-lowvram/offload); `--novram` only if a 16 GB model won't fit | `--use-pytorch-cross-attention` | fp8 storage to fit; no fp8 speedup | `0.5` | heavy offload; slow but works |

Sources: ComfyUI `comfy/cli_args.py`; https://docs.comfy.org/development/comfyui-server/startup-flags .
```

- [ ] **Step 2: Rewrite the `README.md` body** (keep the Task 1 attribution block at the very top; replace everything below it with the following)

````markdown
## What this image does

- Ships **ComfyUI-Manager v4+** (required for programmatic control: node-pack installs and
  arbitrary-URL model downloads — the v3.x `405`/`500` failures are gone).
- **Fixes the Manager shadowing bug:** on a persistent `custom_nodes` bind mount, a stale
  `ComfyUI-Manager/` directory used to shadow the image's v4. The entrypoint now backs it up
  once to `ComfyUI-Manager.bak` and symlinks the baked v4.
- Pinnable ComfyUI (`COMFYUI_REF`) + Manager (`COMFYUI_MANAGER_VERSION`), tracked by CI.
- RTX 3090 runtime defaults; per-GPU guidance in [docs/gpu-settings.md](docs/gpu-settings.md).

## Quick start (generic)

```bash
cp .env.example .env      # optional; defaults work
docker compose up -d
# open http://localhost:8188
```

Data lives under `./data/` by default (models, custom_nodes, output, input).

## RTX 3090 / TrueNAS

Use `docker-compose-3090-sample.yml`. It is a 1:1 replacement for the old
`lecode-official` stack — only the image owner changed, plus a research-backed 3090
`command:`/env. In Portainer, swap the compose and redeploy; the Manager fix applies on
recreate.

## Environment variables (compatible with lecode's image)

| Var | Default | Meaning |
|---|---|---|
| `IMAGE_TAG` | `latest` | Image tag to run |
| `USER_ID` / `GROUP_ID` | `1000` | Host uid/gid that should own files in the mounts |
| `MODELS_PATH` | `./data/models` (3090 sample: `/mnt/Data/ComfyUI/models`) | Models mount |
| `CUSTOM_NODES_PATH` | `./data/custom_nodes` (3090: `/mnt/Data/ComfyUI/custom_nodes`) | Custom nodes mount |
| `OUTPUT_PATH` | `./data/output` | Output mount |
| `INPUT_PATH` | `./data/input` | Input mount |
| `PYTORCH_ALLOC_CONF` | unset | Set to `expandable_segments:True` on torch 2.9 |
| `BOOTSTRAP_NODES` | unset | Set `1` to install the supported node packs on first boot |

## Updating

- **Pull a new image:** `docker compose pull && docker compose up -d`.
- **Bump ComfyUI core:** CI opens a weekly PR bumping `ARG COMFYUI_REF`/`COMFYUI_VERSION` to the
  latest release; merging rebuilds and republishes `latest` + pinned tags. To pin a specific
  version yourself, build with `--build-arg COMFYUI_REF=v0.8.2`.

## Installing the video/audio node packs

Set `BOOTSTRAP_NODES=1` (or run `scripts/bootstrap-nodes.sh` inside the container) to clone
WanVideoWrapper, VideoHelperSuite, TTS-Audio-Suite, and the HuggingFace Downloader into the
mounted `custom_nodes`. Edit `scripts/node-manifest.txt` to add your own.

## Publishing (maintainer note)

CI publishes to `ghcr.io/carmelosantana/comfyui-docker` on pushes to `main`, version tags, and a
weekly schedule. **First-time setup:** enable Actions on the fork, and after the first publish set
the GHCR package visibility to public. Pull requests build + smoke-test but do not push.

## Cleaning up a migrated install

If you bind-mounted an old full ComfyUI install directory, `scripts/cleanup-legacy-comfyui.sh`
reversibly moves everything except `models input output custom_nodes user` into a timestamped
backup folder. Dry-run first:

```bash
sudo bash scripts/cleanup-legacy-comfyui.sh --dry-run /mnt/Data/ComfyUI
sudo bash scripts/cleanup-legacy-comfyui.sh --apply   /mnt/Data/ComfyUI
```

## Credits

Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
(MIT © David Neumann).
````

- [ ] **Step 3: Sanity-check the docs render (no broken fences) and link exists**

```bash
grep -q "docs/gpu-settings.md" README.md && test -f docs/gpu-settings.md && echo "docs OK"
```

Expected: `docs OK`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/gpu-settings.md
git commit -m "docs: README rewrite (quickstart, update flow, attribution) + per-GPU settings"
```

---

## Task 13: Integration verification (the acceptance test)

**Files:** none (verification only). Produces an evidence log.

**Interfaces:**
- Consumes: the built image and the generic compose.
- Produces: proof that ComfyUI boots on :8188, Manager reports v4+, and the two v3.x failures
  (node-pack install `405`, arbitrary-URL model download `500`) are gone.

> This runs CPU-only on this build host (no nvidia runtime). Use a throwaway compose override so
> the GPU reservation doesn't block startup.

- [ ] **Step 1: Build the final image**

```bash
docker build -t comfyui-test .
```

Expected: build succeeds. Record the final line.

- [ ] **Step 2: Run all shell unit tests once more**

```bash
for t in tests/test_*.sh; do echo "== $t =="; bash "$t"; done
```

Expected: every file ends `---- N checks, 0 failed ----`.

- [ ] **Step 3: Boot the container CPU-only**

```bash
docker rm -f comfyui-accept 2>/dev/null || true
docker run -d --name comfyui-accept -p 8188:8188 \
  -e USER_ID=1000 -e GROUP_ID=1000 \
  comfyui-test --cpu
for i in $(seq 1 60); do curl -fsS http://localhost:8188/ >/dev/null 2>&1 && break; sleep 5; done
curl -sS http://localhost:8188/ | head
```

Expected: HTML from the ComfyUI UI.

- [ ] **Step 4: Assert Manager reports v4+**

```bash
docker exec comfyui-accept git -C /opt/comfyui-manager describe --tags --always
```

Expected: `4.x` (e.g. `4.0.5`).

- [ ] **Step 5: Discover the Manager v4 API routes, then exercise the two previously-failing calls**

First find the exact endpoints in the running container (concrete, not guesswork):

```bash
docker exec comfyui-accept bash -lc "grep -rInE '@routes\.(get|post)\(' /opt/comfyui-manager | grep -iE 'install|model|node' | head -40"
```

Then, using the route paths printed above, issue the two calls that returned `405`/`500` on
v3.x and confirm neither returns `405` nor `500`. Template (substitute the real route + payload
fields discovered above):

```bash
# a) node-pack install (was HTTP 405 on v3.x)
curl -s -o /tmp/np.out -w "node-install HTTP %{http_code}\n" \
  -X POST http://localhost:8188/<manager-node-install-route> \
  -H 'Content-Type: application/json' \
  -d '<discovered payload, e.g. {"id":"ComfyUI-VideoHelperSuite", ...}>'

# b) arbitrary-URL model download (was HTTP 500 on v3.x)
curl -s -o /tmp/md.out -w "model-download HTTP %{http_code}\n" \
  -X POST http://localhost:8188/<manager-model-install-route> \
  -H 'Content-Type: application/json' \
  -d '<discovered payload with an arbitrary model URL + target subdir>'
```

Expected: both print an HTTP status that is **not** `405` and **not** `500` (a `2xx`, or a
task-accepted/validation response — the point is the v3.x gating is gone). Capture the exact
status lines as evidence. If a call needs the `security_level=weak` config, confirm the seeded
config is present: `docker exec comfyui-accept cat /opt/comfyui/user/default/ComfyUI-Manager/config.ini`.

- [ ] **Step 6: Tear down and record results**

```bash
docker rm -f comfyui-accept
```

Paste the actual outputs of Steps 1–5 into the PR / summary. Do **not** claim success without
the real HTTP status lines.

- [ ] **Step 7: Commit any evidence doc (optional) and finish**

```bash
git add -A && git commit -m "test: integration acceptance evidence (Manager v4; 405/500 gone)" || echo "nothing to commit"
```

---

## Self-Review (completed against the spec)

- **Spec coverage:** ownership/attribution → T1; Dockerfile/ARGs/Manager v4/healthcheck → T2; shadowing fix → T3; chown perf (P1) → T4; node-req sentinel (P2) → T5; Manager config gating (P3) → T6; node-pack bootstrap → T7; legacy cleanup → T8; both composes + env compat → T9; CI build+publish+pin-and-bump → T10/T11; README update flow + per-GPU doc → T12; acceptance test (405/500 gone) → T13. The `-sage` variant (spec 6.2) is intentionally deferred to a fast-follow plan per Carmelo's sequencing — noted in Global Constraints.
- **Placeholder scan:** the only non-literal spots are the Manager config keys (T6) and the acceptance API routes/payloads (T13), each guarded by a concrete in-container discovery command rather than a hand-waved "TBD" — the engineer runs the command and uses the real values.
- **Type/name consistency:** `link_manager`, `dirs_to_chown`, `chown_app_dirs`, `install_node_requirements`, `seed_manager_config` are defined in T3–T6 and referenced consistently in `main`; env names (`CUSTOM_NODES_DIR`, `MANAGER_SRC`, `MANAGER_CONFIG_SRC`, `FORCE_NODE_REQS`, `BOOTSTRAP_NODES`) match across tasks and tests.

## Follow-on (separate plan, review first): `-sage` image variant

Add `--use-sage-attention` support (biggest real Ampere speedup for video) via a multi-stage
`sage` build target that installs `triton` + a `sageattention` wheel matched to torch 2.9.1/cu128,
published as `*-sage`/`latest-sage` tags. Carmelo reviews the single-vs-multi-stage approach and
wheel-vs-compile tradeoff before implementation.
