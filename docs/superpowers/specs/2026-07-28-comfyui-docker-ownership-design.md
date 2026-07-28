# ComfyUI Docker — Ownership & Modernization Design (2026-07-28)

Owner: Carmelo Santana <me@carmelosantana.com>
Status: **Approved** (design gate passed; proceeding to writing-plans)

## 1. Problem & goal

The current base image (`ghcr.io/lecode-official/comfyui-docker`) ships **ComfyUI-Manager
3.x (legacy)** on Carmelo's live box, which blocks programmatic control: node-pack installs
return HTTP 405 and arbitrary-URL model downloads return HTTP 500 ("Arbitrary-URL model
installs REQUIRE Manager v4+"). The ComfyUI-MCP driving the box needs **Manager v4+**.

Goal: **own the base image** — a fork/re-home into `github.com/carmelosantana/comfyui-docker`
publishing `ghcr.io/carmelosantana/comfyui-docker`, that ships Manager v4+, tracks ComfyUI core
(pinnable + easy to bump), is trivial to update/pull, and carries research-backed default
runtime settings tuned for the RTX 3090.

## 2. Key findings (grounding the design)

1. **Upstream already ships Manager v4.** The current `lecode-official/comfyui-docker`
   Dockerfile pins `COMFYUI_MANAGER_VERSION=4.0.5` and `COMFYUI_VERSION=0.8.2` as clean build
   ARGs, `FROM pytorch/pytorch:2.9.1-cuda12.8-cudnn9-runtime`, git-cloning both repos to
   pinnable refs. Their tag scheme already matches the brief (`latest`, version, fully-pinned).

2. **Root cause of the 3.x lock-in = Manager shadowing.** The entrypoint bakes Manager into
   `/opt/comfyui-manager` (outside the mount) and **symlinks** it into
   `custom_nodes/ComfyUI-Manager`, but first runs only `rm --force` (no `-r`). Carmelo's
   `custom_nodes` is a **persistent bind mount** (`/mnt/Data/ComfyUI/custom_nodes`). A real
   `ComfyUI-Manager/` directory there (old 3.x git clone) cannot be removed by `rm -f`, the
   symlink silently fails, and ComfyUI loads the **stale 3.x from the mount** — shadowing the
   v4 in the image. UI/Portainer "updates" only pull the 3.x lineage forward. **A new image
   alone does not fix this** unless the entrypoint forces baked v4 to win.

3. **Upstream is MIT** (Copyright (c) 2024 David Neumann). Re-home via a **real GitHub fork**
   (`gh repo fork lecode-official/comfyui-docker`) — preserves full history + the MIT LICENSE
   automatically. Add Carmelo's copyright line to LICENSE and a "forked from" attribution in
   the README.

4. **3090 boot-flag research (verified against `comfy/cli_args.py`):**
   - `--normalvram` does **not** exist (would crash startup). "Normal" = pass no VRAM flag;
     DynamicVRAM/smart-memory manages a 24GB card. Default cache is already `--cache-ram`.
   - Do **not** force `--highvram`/`--gpu-only`/`--fast`/`--fp8_*-unet` on a 3090: Ampere
     (sm_86) has no fp8 tensor cores (fp8 = storage-only, zero compute speedup), and pinning a
     ~16GB model + TTS + video VAE decode invites OOM.
   - Safe, zero-dep 3090 defaults: `--use-pytorch-cross-attention --reserve-vram 1` plus env
     `PYTORCH_ALLOC_CONF=expandable_segments:True` (torch 2.9 name; cuts fragmentation OOMs).
   - The one real Ampere speedup for video is `--use-sage-attention`, which needs
     `sageattention` + `triton` compiled in (not in the `-runtime` base). → `-sage` variant.

## 3. Approved decisions

| Decision | Choice | Rationale |
|---|---|---|
| Base image | Fork lecode's `FROM pytorch/pytorch:*-runtime`, ARG-pinned ComfyUI + Manager | Already reproducible, pinnable, ships v4. Reinventing on raw CUDA buys nothing. |
| Manager shadowing fix | **Backup-then-replace** in entrypoint | If `custom_nodes/ComfyUI-Manager` is a real dir, move once to `ComfyUI-Manager.bak` (skip if a `.bak` already exists), then symlink baked v4. Path-agnostic; fixes the box. |
| Staying current | **Pin-and-bump via scheduled CI** | ARG defaults = known-good; scheduled job bumps + rebuilds + tags by version. Reproducible AND fresh. |
| GHCR publish | **Auto-publish on main + schedule** (GITHUB_TOKEN); PRs build-only | No extra secret for same-repo GHCR. Carmelo sets the package public once after first publish. |
| Node packs | **Opt-in first-boot bootstrap** (env flag) into the mounted custom_nodes | Whole custom_nodes is bind-mounted, so baked packs there are hidden. Bootstrap is lean + idempotent. |
| lecode env-var compat | **Keep identical** (`IMAGE_TAG`, `USER_ID/GROUP_ID`, `MODELS_PATH`, `CUSTOM_NODES_PATH`, `OUTPUT_PATH`) | Drop-in: switch by changing only the image owner. |
| `-sage` variant | **First-class near-term deliverable** | Video generation is the current workload; sage-attention is the biggest real Ampere speedup. |

## 4. Additional pain points to fix (found in upstream)

- **P1 — `chown -R /opt/comfyui` every boot** walks the mounted model tree (→60GB) on every
  start = very slow restarts. Fix: chown only app dirs, not the big bind mounts.
- **P2 — re-`pip install` of every node's requirements every boot** = slow + drift/breakage
  risk (WanVideo + TTS-Audio-Suite dep conflicts). Fix: first-run sentinel so it runs once.
- **P3 — Manager v4 arbitrary-URL installs still gated by `config.ini`** (`security_level`,
  `allow_git_url_install`, `allow_pip_install`). Ship a sane Manager config (or set it in the
  entrypoint) so the acceptance test actually passes even after v4 loads.
- **P4 — `-runtime` base has no compilers/CUDA dev headers.** Node packs / sage-attention that
  compile native code may fail to install cleanly. Verify per-pack; the `-sage` variant adds
  build tooling. Default image stays lean.
- **P5 — no healthcheck.** Add a `curl :8188` healthcheck for Portainer health + `depends_on`.

## 5. Repository layout

```
comfyui-docker/
├─ source/{Dockerfile, entrypoint.sh, manager-config.ini}
├─ scripts/{bootstrap-nodes.sh, node-manifest.txt, cleanup-legacy-comfyui.sh}
├─ docker-compose.yml               # generic / portable
├─ docker-compose-3090-sample.yml   # Carmelo's 1:1 stack + perf command/env
├─ .env.example
├─ .github/workflows/{build.yml, bump.yml}
├─ docs/gpu-settings.md
├─ README.md
├─ LICENSE                          # MIT, upstream copyright preserved + Carmelo's added
└─ CHANGELOG.md
```

## 6. Component design

### 6.1 Dockerfile (`source/Dockerfile`)
- `FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime`.
- ARGs: `PYTORCH_VERSION=2.9.1`, `CUDA_VERSION=12.8`, `CUDNN_VERSION=9`,
  `COMFYUI_REF` (default a known-good tag e.g. `v0.8.2`), `COMFYUI_MANAGER_VERSION` (default
  `4.0.5`, i.e. v4+). Git-clone both to the refs, `pip install` requirements.
- Copy `manager-config.ini` into the image as the default Manager config (P3).
- Add `HEALTHCHECK` hitting `:8188` (P5).
- `EXPOSE 8188`; entrypoint `/entrypoint.sh`.

### 6.2 `-sage` variant
- Build path that adds `build-essential`/CUDA dev bits + installs `triton` + `sageattention`
  matched to torch 2.9.1/cu128, published as a `*-sage` tag (and `latest-sage`).
- Decision to make at implementation: separate `Dockerfile.sage` (clear, larger) vs a
  `WITH_SAGE` build-arg stage in one Dockerfile. Recommend a multi-stage single Dockerfile with
  a `sage` target to share layers. The 3090 sample can then set `--use-sage-attention` when
  pointed at a `-sage` tag. **Carmelo wants to review this immediately after the core lands.**

### 6.3 Entrypoint (`source/entrypoint.sh`)
Keep upstream's model-dir creation and USER_ID/GROUP_ID logic, plus:
- **Manager backup-then-replace** (decision above) — the crux of the acceptance test.
- **Leaner chown** (P1): chown app dirs only, never the mounted models/output/input.
- **First-run sentinel** (P2): install node requirements once, marked by a sentinel file in
  the custom_nodes mount; re-run only when a pack's requirements change (or a force env flag).
- **Manager config seeding** (P3): if no user Manager config exists, drop the sane default.
- Append the 3090 perf flags via compose `command:`/`"$@"` (not hard-coded in the image).
- **TDD**: this script has real branching → test with a bats/shell harness (stale-dir present
  vs symlink present vs absent; sentinel present vs absent; chown scope).

### 6.4 Node-pack bootstrap (`scripts/bootstrap-nodes.sh` + `node-manifest.txt`)
- Env-gated (`BOOTSTRAP_NODES=1`). Idempotently git-clones into the mounted custom_nodes only
  if absent: ComfyUI-WanVideoWrapper (Kijai), ComfyUI-VideoHelperSuite, TTS-Audio-Suite
  (diodiogod), ComfyUI_HuggingFace_Downloader (jnxmx). Skips any present. Manifest is the
  editable source of truth (repo URL + optional pinned ref per line).

### 6.5 Legacy-install cleanup (`scripts/cleanup-legacy-comfyui.sh`)
- Carmelo migrated a full ComfyUI install to `/mnt/Data/ComfyUI` and bind-mounts models/
  output/input/custom_nodes from it. Leftover full-install files there can conflict + waste
  space. **Reversible** cleanup: given a target dir, KEEP an allowlist and MOVE everything else
  into a timestamped `_legacy_backup_<ts>/` folder (never delete).
  - **KEEP:** `models`, `input`, `output`, `custom_nodes`, `user` (workspace/workflows/Manager
    config live here). Consider also keeping `.env`-like configs if present.
  - **MOVE aside:** the rest of the migrated install (`main.py`, `comfy/`, `web/`,
    `requirements.txt`, `venv/`, `.git`, etc. — these come from the image now).
  - `--dry-run` default; `--apply` to act; prints an exact `mv` reversal recipe.
  - Runs on the TrueNAS box with `sudo` (Carmelo executes). A background-task chip tracks this.

### 6.6 Compose files
**Generic `docker-compose.yml`** — portable defaults (`./data/*` relative mounts), single GPU,
standard port, USER_ID/GROUP_ID, input+workflows parity, `${GPU_COUNT:-1}`.

**`docker-compose-3090-sample.yml`** — faithful **1:1** of Carmelo's live stack, changing ONLY
the image owner, plus the evidence-backed perf block:
```yaml
name: comfyui-docker
services:
  comfyui:
    image: ghcr.io/carmelosantana/comfyui-docker:${IMAGE_TAG:-latest}
    container_name: comfyui-lecode
    restart: unless-stopped
    extra_hosts: ["ollama:host-gateway"]
    environment:
      USER_ID: "${USER_ID:-1000}"
      GROUP_ID: "${GROUP_ID:-1000}"
      PYTORCH_ALLOC_CONF: "expandable_segments:True"
    ports: ["8188:8188"]
    volumes:
      - ${MODELS_PATH:-/mnt/Data/ComfyUI/models}:/opt/comfyui/models:rw
      - ${CUSTOM_NODES_PATH:-/mnt/Data/ComfyUI/custom_nodes}:/opt/comfyui/custom_nodes:rw
      - ${OUTPUT_PATH:-/mnt/Data/ComfyUI/output}:/opt/comfyui/output:rw
      - /mnt/Data/ComfyUI/input:/opt/comfyui/input:rw
      - /mnt/Data/ComfyUI/user/default/workflows:/opt/comfyui/user/default/workflows:rw
    command: ["--use-pytorch-cross-attention", "--reserve-vram", "1"]
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```
Portainer swap = change the image owner line (and it remaps to `/mnt/Data/ComfyUI/*` via the
defaults). The shadowing fix rides in the image entrypoint.

### 6.7 CI
- **`build.yml`**: on PR/push/tag/schedule → build; CPU smoke test (boot with `--cpu`, `curl
  :8188`, assert Manager v4 via its API); push to GHCR on main/tags/schedule (GITHUB_TOKEN);
  tags `latest`, ComfyUI version, fully-pinned. Also builds+publishes the `-sage` variant tags.
- **`bump.yml`**: scheduled → query latest ComfyUI release; if newer than the ARG default, bump
  it (PR or direct commit) → triggers build → reproducible fresh publish. Publishing may await
  Carmelo enabling package write perms / setting the package public — noted in README.

### 6.8 Docs
- **README.md**: quickstart, both composes, **how to update ComfyUI core + pull new releases**,
  the shadowing note, node-pack bootstrap, `-sage` usage, upstream attribution.
- **docs/gpu-settings.md**: 3090 defaults (the researched flags + env) and a per-GPU table
  (3090 24GB / 4090 24GB / 4080 16GB / 3060 12GB) with VRAM mode, attention backend, precision
  notes, reserve-vram, and a "why not X" cargo-cult list. Backed by the cli_args.py research.

## 7. Verification / Definition of Done

- `docker build -t comfyui-test .` succeeds (CPU build host, no GPU runtime here).
- `docker compose -f docker-compose.yml up -d` (with a CPU override) boots ComfyUI on :8188;
  `curl -sS http://localhost:8188/ | head` returns the UI.
- Manager reports **v4+** via its API endpoint.
- **Acceptance test:** against the running container, a node-pack install AND an arbitrary-URL
  model download both succeed (405/500 gone).
- README documents core-update + image-pull flow.
- `docs/gpu-settings.md` committed with the per-GPU table.
- GHCR Actions workflow present (publishing may await Carmelo enabling package perms).
- Report every check with actual command output.

## 8. Out of scope

Downloading the ~60GB model set; building video workflows; deploying to the live TrueNAS box
(Carmelo switches over himself); anything in the latex-pics repo. GPU-passthrough verification
is impossible on this build host (no nvidia container runtime) — real-GPU validation happens on
the TrueNAS box.
