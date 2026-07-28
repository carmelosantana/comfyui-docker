# ComfyUI Docker (carmelosantana)

> Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
> (MIT © David Neumann). This fork actually activates ComfyUI-Manager **v4+** (pip package +
> `--enable-manager`), clears any stale v3 Manager on persistent `custom_nodes` mounts, adds
> RTX 3090 runtime defaults, and publishes to `ghcr.io/carmelosantana/comfyui-docker`.

## What this image does

- Ships **ComfyUI-Manager v4+** (required for programmatic control: node-pack installs and
  arbitrary-URL model downloads — the v3.x `405`/`500` failures are gone).
- **Actually activates Manager v4:** it is a pip package enabled by `main.py --enable-manager`
  — not a git-clone symlinked into `custom_nodes` (the v3 mechanism, which v4 rejects as
  `IMPORT FAILED`). The image `pip install`s it and passes the flag. The entrypoint also
  backs up/removes any stale v3 `custom_nodes/ComfyUI-Manager` (to `ComfyUI-Manager.bak`) so it
  can't shadow or import-fail — **no** symlink is created.
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
| `COMFYUI_PORT` | `8188` | Host port published to ComfyUI's `8188` |
| `GPU_COUNT` | `1` | Number of GPUs reserved for the container |
| `USER_ID` / `GROUP_ID` | `1000` | Host uid/gid that should own files in the mounts |
| `MODELS_PATH` | `./data/models` (3090 sample: `/mnt/Data/ComfyUI/models`) | Models mount |
| `CUSTOM_NODES_PATH` | `./data/custom_nodes` (3090: `/mnt/Data/ComfyUI/custom_nodes`) | Custom nodes mount |
| `OUTPUT_PATH` | `./data/output` | Output mount |
| `INPUT_PATH` | `./data/input` | Input mount |
| `PYTORCH_ALLOC_CONF` | unset | Set to `expandable_segments:True` on torch 2.9 |
| `BOOTSTRAP_NODES` | unset | Set `1` to install the supported node packs on first boot |
| `MANAGER_SECURITY_LEVEL` | `weak` | Manager security level written to `user/__manager/config.ini`. `weak` is what lets the MCP do arbitrary-URL model + node-pack installs (clears the v3.x `405`/`500`); raise it (`normal`/`normal-`/`strong`) to lock those down. Applied only when the config is first seeded — to change it later, edit `user/__manager/config.ini` directly (or delete it to re-seed from the env var) |
| `MANAGER_NETWORK_MODE` | `public` | Manager network mode written to `user/__manager/config.ini` |
| `USE_SAGE_ATTENTION` | `1` in `-sage` images, else unset | On the `-sage` image, appends `--use-sage-attention` (and drops `--use-pytorch-cross-attention`). Set `0` to disable. No effect on the base image |

## Updating

- **Pull a new image:** `docker compose pull && docker compose up -d`.
- **Bump ComfyUI core:** CI opens a weekly PR bumping `ARG COMFYUI_REF`/`COMFYUI_VERSION` to the
  latest release; merging rebuilds and republishes `latest` + pinned tags. To pin a specific
  version yourself, build with `--build-arg COMFYUI_REF=v0.8.2`.

## Installing the video/audio node packs

Set `BOOTSTRAP_NODES=1` (or run `/opt/scripts/bootstrap-nodes.sh` inside the container) to clone
WanVideoWrapper, VideoHelperSuite, TTS-Audio-Suite, and the HuggingFace Downloader into the
mounted `custom_nodes`. Edit `scripts/node-manifest.txt` to add your own.

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
sudo bash scripts/cleanup-legacy-comfyui.sh --dry-run /mnt/Data/ComfyUI
sudo bash scripts/cleanup-legacy-comfyui.sh --apply   /mnt/Data/ComfyUI
```

## Credits

Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
(MIT © David Neumann).
