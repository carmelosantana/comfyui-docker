# ComfyUI Docker (carmelosantana)

> Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
> (MIT © David Neumann). This fork actually activates ComfyUI-Manager **v4+** (pip package +
> `--enable-manager`), clears any stale v3 Manager on persistent `custom_nodes` mounts, adds
> RTX 3090 runtime defaults, and publishes to `ghcr.io/carmelosantana/comfyui-docker`.

## Why this fork?

Upstream ([lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker))
is a clean, well-built image, but it ships ComfyUI-Manager in a way that never actually turns
Manager on. It bakes Manager `4.2.2` into the image, but it never `pip install`s the Manager
package and never passes `main.py --enable-manager`, so Manager v4's routes never register. The
result is that any tool driving Manager over its API — for example
[ComfyUI-MCP](https://github.com/artokun/comfyui-mcp) — hits dead endpoints:

- programmatic node-pack installs return **HTTP `405`**, and
- arbitrary-URL model downloads return **HTTP `500`** ("… REQUIRES Manager v4+").

This fork fixes that, and adds runtime defaults and version pinning on top. What's different:

- **Manager v4 is actually activated.** Manager v4 is a *pip package* enabled by a launch flag,
  not the v3 mechanism of a git clone symlinked into `custom_nodes` (which v4 rejects as
  `IMPORT FAILED`). So the image `pip install`s the Manager package **and** passes
  `--enable-manager`. On boot the entrypoint also backs up and removes any stale v3
  `custom_nodes/ComfyUI-Manager` (to `ComfyUI-Manager.bak`) so it can't shadow the pip package —
  **no** symlink is created. The `405`/`500` are gone, verified `200`/`200` against the shipped
  image (see [docs/acceptance-2026-07-28.md](docs/acceptance-2026-07-28.md)). The Manager v4 API
  lives under `/v2/manager/*`.
- **Research-backed RTX 3090 runtime defaults**, plus a per-GPU table, in
  [docs/gpu-settings.md](docs/gpu-settings.md).
- **Pinnable versions, tracked by CI.** Pin ComfyUI (`COMFYUI_REF`) and Manager
  (`COMFYUI_MANAGER_VERSION`); CI opens a weekly PR that bumps them to the latest releases.
- **Drop-in replacement.** It keeps lecode's environment-variable interface unchanged, so
  migrating is just swapping the image and redeploying — no compose rewrite.

## What's baked into the image

**All of these node packs are baked into the image and seeded into `custom_nodes` on every boot —
on by default, no setup.** Seeding is a local copy from the image (no git/network), idempotent, and
never overwrites a dir that already exists (your own edits win). Each pack belongs to a category you
can turn off with an env var; `SEED_BAKED_NODES=0` disables all seeding at once.

| Pack | Category (toggle) | Purpose |
| --- | --- | --- |
| [ComfyUI-Manager](https://github.com/Comfy-Org/ComfyUI-Manager) v4 | always on | Node/model management API (used by [ComfyUI-MCP](https://github.com/artokun/comfyui-mcp)). Activated as a `pip` package + `--enable-manager`, **not** seeded as a `custom_nodes` directory — see [Why this fork?](#why-this-fork) |
| [TTS-Audio-Suite](https://github.com/diodiogod/TTS-Audio-Suite) | audio (`SEED_AUDIO_NODES`) | TTS / voice-clone engines: ChatterBox, IndexTTS-2, F5-TTS, VibeVoice, Higgs Audio, CosyVoice3, RVC |
| [ComfyUI-WanVideoWrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper) | video (`SEED_VIDEO_NODES`) | Wan2.x video generation (S2V / InfiniteTalk) |
| [ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite) | video (`SEED_VIDEO_NODES`) | Video load/combine/encode (needs ffmpeg) |
| [ComfyUI-Frame-Interpolation](https://github.com/Fannovel16/ComfyUI-Frame-Interpolation) | video (`SEED_VIDEO_NODES`) | RIFE frame interpolation for smooth / 60fps output (works out of the box); cupy-accelerated methods like GIMM-VFI need `cupy` added separately — the image bakes the no-cupy requirements |
| [ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | helper (`SEED_HELPER_NODES`) | Helper nodes (resize/mask/get-set) the Wan graphs need |
| [ComfyUI_essentials](https://github.com/cubiq/ComfyUI_essentials) | helper (`SEED_HELPER_NODES`) | Common utility nodes many community workflows depend on |
| [ComfyUI_HuggingFace_Downloader](https://github.com/jnxmx/ComfyUI_HuggingFace_Downloader) | helper (`SEED_HELPER_NODES`) | In-graph HuggingFace model downloads |
| [comfyui-ollama](https://github.com/stavsap/comfyui-ollama) | llm (`SEED_LLM_NODES`) | In-graph Ollama LLM nodes (`OllamaGenerateV2`, vision, etc.) for prompt-building / captioning. Needs a reachable Ollama server (host or network) |

> **Audio models are ComfyUI core (no pack to seed):** on ComfyUI `0.33.1` the **MiniMax-Music3**
> (`MiniMaxMusic3TextEncode`, `EmptyMiniMaxMusic3LatentAudio`) and **ACE-Step** 1.0/1.5
> (`TextEncodeAceStepAudio`, `EmptyAceStepLatentAudio`, and the 1.5 variants) text-to-music nodes
> ship in ComfyUI itself — no custom node is seeded. Their model weights are downloaded separately
> (see [model weights](#model-weights-not-baked)).

> **Node code vs. model weights:** baking a pack installs its **nodes** (they appear in ComfyUI's
> menu), not the model checkpoints/LoRAs it uses. Those are downloaded on demand into the persistent
> `models` mount — TTS engines auto-download their weights on first node use; Wan/SD checkpoints you
> fetch via ComfyUI-Manager or the HuggingFace Downloader. See [model weights](#model-weights-not-baked) below.

> Each `SEED_*_NODES` flag defaults to `1` (on). Set one to `0` to skip that category
> (e.g. `SEED_VIDEO_NODES=0` on an audio-only box), or `SEED_BAKED_NODES=0` to disable all baked-node
> seeding. To add packs beyond the baked set, install them from ComfyUI-Manager, drop them into the
> `custom_nodes` mount, or list them in [`scripts/node-manifest.txt`](scripts/node-manifest.txt) and
> set `BOOTSTRAP_NODES=1` (a runtime git-clone, unlike the baked set).

> Any custom_nodes you drop into the mount — baked, bootstrapped, or your own — get their
> `requirements.txt` (and `install.py`) auto-installed on the next boot, keyed on a content hash
> so it only reinstalls when a pack's deps actually change (`FORCE_NODE_REQS=1` to force it).

> Baked packs are seeded into `custom_nodes` once and never overwrite an existing copy. To pick up
> a newer baked version after an image upgrade, delete that pack's directory from `custom_nodes`
> and reboot the container — it re-seeds from the image.

**System tools (apt):** `ffmpeg` (VideoHelperSuite decode/encode — `ffmpeg -version` works
in-container), `git`, `aria2` (fast model downloads), `espeak-ng` (phonemizer for TTS), plus the
`libgl1`/`libgl1-mesa-glx`/`libglib2.0-0` libraries OpenCV needs.

**Python (baked into the conda env, so they survive a container recreate):** `accelerate`,
`transformers`, `opencv-python-headless`, `imageio-ffmpeg`, `deepdiff`, `ollama` (0.6.0) + `dotenv`, `onnxruntime`,
`huggingface_hub[cli]`, plus everything TTS-Audio-Suite and Frame-Interpolation require. SageAttention
stays available on the `-sage` tags (compiled from pinned upstream source, not a prebuilt wheel).

### Model weights (not baked)

Baking a pack ships its **node code**, not the models it uses — model weights are **not** baked (that
keeps the image lean). TTS engines and other packs lazy-download their weights on first use into
`HF_HOME`/`TORCH_HOME`, which default to `models/.cache/…` inside the persistent `models` mount — so
first-use downloads survive `docker compose down && up`. Larger checkpoints (Wan, SD) you fetch
yourself via ComfyUI-Manager or the HuggingFace Downloader into the `models` mount.

**MiniMax-Music3 weights** (ComfyUI core node; download from HF `Comfy-Org/MiniMax-Music-3` into the
`models` mount — pick one DiT, fp16 for quality or int8 for lower VRAM):

| File | Target dir |
| --- | --- |
| `minimax_music3_dit_fp16.safetensors` (~4.9 GB) | `models/diffusion_models/` |
| `minimax_music3_dit_int8_convrot.safetensors` (~2.5 GB) | `models/diffusion_models/` |
| `minimax_music3_text_encoder_pruned_int8_convrot.safetensors` | `models/text_encoders/` |
| `minimax_music3_dav.safetensors` (audio VAE) | `models/vae/` |

**ACE-Step** (also core) uses `ace_step_v1_3.5b.safetensors` in `models/checkpoints/`. On a 3090,
MiniMax-Music3 needs dynamic VRAM enabled (fixed in ComfyUI 0.33.1's MiniMax + CUDA-Graphs work).

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
| `COMFYUI_PORT` | `8188` | Host port published to ComfyUI's `8188` |
| `GPU_COUNT` | `1` | Number of GPUs reserved for the container |
| `USER_ID` / `GROUP_ID` | `1000` | Host uid/gid that should own files in the mounts |
| `MODELS_PATH` | `./data/models` | Models mount (the 3090 sample sets its own host default) |
| `CUSTOM_NODES_PATH` | `./data/custom_nodes` | Custom nodes mount |
| `OUTPUT_PATH` | `./data/output` | Output mount |
| `INPUT_PATH` | `./data/input` | Input mount |
| `WORKFLOWS_PATH` | (3090 samples only) | Saved-workflows mount used by the 3090 sample stacks |
| `PYTORCH_ALLOC_CONF` | unset | Set to `expandable_segments:True` on torch 2.9 |
| `SEED_BAKED_NODES` | `1` | Baked node packs are seeded into `custom_nodes` on boot. Set `0` to disable all seeding (bare ComfyUI + Manager) |
| `SEED_AUDIO_NODES` | `1` | Set `0` to skip the audio pack (TTS-Audio-Suite) |
| `SEED_VIDEO_NODES` | `1` | Set `0` to skip the video packs (WanVideoWrapper, VideoHelperSuite, Frame-Interpolation) |
| `SEED_HELPER_NODES` | `1` | Set `0` to skip the helper packs (KJNodes, essentials, HuggingFace Downloader) |
| `SEED_LLM_NODES` | `1` | Set `0` to skip the LLM pack (comfyui-ollama) |
| `BOOTSTRAP_NODES` | unset | Set `1` to git-clone **extra** packs from `scripts/node-manifest.txt` on first boot. The supported packs are already baked in — this is only for additions |
| `MANAGER_NETWORK_MODE` | `personal_cloud` | Manager v4 network mode, **enforced** into `user/__manager/config.ini` every boot. `personal_cloud` is **required** to unlock the install/model management API on a box that listens on `0.0.0.0` — Manager blocks those actions for `public`/`private`/`offline` on a non-loopback listen. Set to `public` to lock the box down when exposed publicly |
| `MANAGER_SECURITY_LEVEL` | `normal` | Manager v4 security level, enforced into `user/__manager/config.ini` every boot. `normal` is the least-permissive level that still allows arbitrary git-URL node installs and arbitrary-URL model downloads via the API; `strong` blocks them |
| `USE_SAGE_ATTENTION` | `1` in `-sage` images, else unset | On the `-sage` image, appends `--use-sage-attention` (and drops `--use-pytorch-cross-attention`). Set `0` to disable. No effect on the base image |

## Updating

- **Pull a new image:** `docker compose pull && docker compose up -d`.
- **Bump ComfyUI core:** CI opens a weekly PR bumping `ARG COMFYUI_REF`/`COMFYUI_VERSION` to the
  latest release; merging rebuilds and republishes `latest` + pinned tags. To pin a specific
  version yourself, build with `--target base --build-arg COMFYUI_REF=v0.29.0`. The `-sage` image
  is built with `docker build --target sage .`.

## Node packs on by default (and how to disable)

The voice, video, and helper node packs listed in
[What's baked into the image](#whats-baked-into-the-image) are **baked in and on by default** — no
`BOOTSTRAP_NODES` needed. Turn a category off with an env var when you don't need it:

| Env | Default | Effect |
|---|---|---|
| `SEED_BAKED_NODES` | `1` | Set `0` to disable **all** baked-node seeding (bare ComfyUI + Manager) |
| `SEED_AUDIO_NODES` | `1` | Set `0` to skip TTS-Audio-Suite |
| `SEED_VIDEO_NODES` | `1` | Set `0` to skip WanVideoWrapper, VideoHelperSuite, Frame-Interpolation |
| `SEED_HELPER_NODES` | `1` | Set `0` to skip KJNodes, essentials, HuggingFace Downloader |
| `SEED_LLM_NODES` | `1` | Set `0` to skip comfyui-ollama |

To add packs **beyond** the baked set, install them from ComfyUI-Manager, drop them into the
`custom_nodes` mount, or list their git URLs in `scripts/node-manifest.txt` and set
`BOOTSTRAP_NODES=1` (a runtime git-clone on first boot, unlike the reliable baked set).

## Custom-node Python dependencies

The image bakes the heavy deps many video/vision packs need — `accelerate`,
`opencv-python-headless` (cv2), `transformers`, `deepdiff`, `ollama` — plus a system **`ffmpeg`**
on `PATH` (VideoHelperSuite shells out to it). On every boot the entrypoint also runs
`pip install -r requirements.txt` and `install.py` for each pack in `custom_nodes`, keyed on a
content hash stored **off** the persistent mount (`$COMFYUI_DIR/.node-deps-state`) — so deps are
reinstalled into the fresh conda env after a `docker compose down && up` (the env is not a mount).
A pack whose install fails logs a warning and never crashes boot. Force a reinstall with
`FORCE_NODE_REQS=1`.

## ComfyUI-MCP / Manager management API

The Manager v4 install/model API needs `network_mode = personal_cloud` (the default here) —
**not** `public` or `private` — because the container listens on `0.0.0.0` (non-loopback); Manager
blocks those actions in any other mode. The config is enforced into `user/__manager/config.ini`
before ComfyUI starts (Manager caches it on first read), so redeploying corrects a stale value.

If a client gets **`405 Method Not Allowed` on `/v2/manager/queue/start`**, that is a *client* bug,
not an image one: that route is **GET-only**. The correct v4 flow is `POST /v2/manager/queue/task`
(kind `install`/`install_model`) then `GET /v2/manager/queue/start`.

## SageAttention build (`-sage` tags)

For video generation on Ampere (RTX 3090), the `*-sage` / `latest-sage` image variant enables
ComfyUI's `--use-sage-attention` — the largest real attention speedup on that hardware. It is the
same image as the default, plus SageAttention 2.x compiled from pinned upstream source
(`thu-ml/SageAttention`) in the matching `pytorch/pytorch:…-devel` build stage — no untrusted
prebuilt wheels.

- **Run it:** point your stack at a `-sage` tag (e.g. `ghcr.io/carmelosantana/comfyui-docker:latest-sage`).
  Sage attention is **on by default** (`USE_SAGE_ATTENTION=1` baked in). Set `USE_SAGE_ATTENTION=0`
  in the environment to A/B against the default backend without a rebuild. `--use-sage-attention`
  replaces `--use-pytorch-cross-attention`, so drop that flag from your `command:`.
- **3090 sample:** `docker-compose-3090-sage-sample.yml` is the swap-and-go stack.
- **Requires an NVIDIA GPU at runtime** (the kernels are CUDA). CI only verifies the package builds
  and installs; real kernel execution is validated on the GPU.

> **⚠️ Do not use the global `--use-sage-attention` flag on fp8 image models.** SageAttention
> produces all-black / NaN output on fp8 **image** checkpoints (Qwen-Image, Flux). It is meant for
> **video** (Wan). On a mixed image+video box, keep `USE_SAGE_ATTENTION=0` (so image generation is
> correct) and enable Sage **per-workflow** on the video model with KJNodes'
> **"Patch Sage Attention KJ"** node — that scopes the speedup to the graph that benefits, instead
> of the process-wide flag that breaks image gen.

## Publishing (maintainer note)

CI publishes to `ghcr.io/carmelosantana/comfyui-docker` on pushes to `main`, version tags, and a
weekly schedule. **First-time setup:** enable Actions on the fork, and after the first publish set
the GHCR package visibility to public. The weekly bump PR also requires
*Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests"* to be
enabled. Pull requests build + smoke-test but do not push.

## Cleaning up a migrated install

If you bind-mounted an old full ComfyUI install directory, `scripts/cleanup-legacy-comfyui.sh`
reversibly moves everything except `models input output custom_nodes user` into a timestamped
backup folder. Dry-run first:

```bash
sudo bash scripts/cleanup-legacy-comfyui.sh --dry-run /path/to/ComfyUI
sudo bash scripts/cleanup-legacy-comfyui.sh --apply   /path/to/ComfyUI
```

## Credits

Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
(MIT © David Neumann).
