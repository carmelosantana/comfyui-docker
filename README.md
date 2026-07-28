# ComfyUI Docker (carmelosantana)

> Forked from [lecode-official/comfyui-docker](https://github.com/lecode-official/comfyui-docker)
> (MIT © David Neumann). This fork ships ComfyUI-Manager **v4+**, fixes the stale-Manager
> shadowing bug on persistent `custom_nodes` mounts, adds RTX 3090 runtime defaults, and
> publishes to `ghcr.io/carmelosantana/comfyui-docker`.

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
| `MANAGER_SECURITY_LEVEL` | `weak` | Manager security level written to `user/__manager/config.ini`. `weak` is what lets the MCP do arbitrary-URL model + node-pack installs (clears the v3.x `405`/`500`); raise it (`normal`/`normal-`/`strong`) to lock those down |
| `MANAGER_NETWORK_MODE` | `public` | Manager network mode written to `user/__manager/config.ini` |

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
