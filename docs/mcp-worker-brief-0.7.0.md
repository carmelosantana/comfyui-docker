# Brief: ComfyUI Docker `0.7.0-sage` — for the MCP image/video worker

**From:** Carmelo's ComfyUI Docker fork (`ghcr.io/carmelosantana/comfyui-docker`)
**Date:** 2026-07-29
**TL;DR:** New image bumps ComfyUI to **0.29.0** and ships SageAttention. Sage must **not** be
enabled globally if you do fp8 image gen — it black/NaNs Qwen-Image/Flux. Enable sage **per-workflow**
on video only, via KJNodes' patch node. Details below.

---

## 1. What to pull

| | value |
|---|---|
| Image | `ghcr.io/carmelosantana/comfyui-docker:0.7.0-sage` |
| ComfyUI | **0.29.0** (was 0.8.2 — the old core broke KJNodes' newer node schema) |
| ComfyUI-Manager | **4.2.2** |
| PyTorch / CUDA | 2.9.1 / cu128 |
| SageAttention | 2.2.0 (compiled into the `-sage` image) |

There is also a non-sage image (`:0.7.0`) with no SageAttention compiled in. If you want sage kernels
available at all, you need the **`-sage`** tag.

> Confirm on boot the banner reads `ComfyUI version: 0.29.0`. If it says `0.8.2`, the stack is still
> pulling `latest-sage` (the old image) — set `IMAGE_TAG=0.7.0-sage` explicitly.

## 2. The SageAttention rule (this is the important part)

SageAttention is an fp8/int8 attention kernel. It's a big speedup for **video** (Wan), but on
**fp8 image models (Qwen-Image, Flux)** the global flag produces **black / NaN images**. So:

- **Do NOT rely on the global `--use-sage-attention` flag** if the same server does image gen.
- Run the container with **`USE_SAGE_ATTENTION=0`** (env var). This keeps ComfyUI on standard
  PyTorch attention so image gen is correct.
- Turn sage on **per-workflow, on the video model only**, using the KJNodes patch node.

### The node: "Patch Sage Attention KJ"

- Pack: **ComfyUI-KJNodes** (baked into the image; internal class id is `PathchSageAttentionKJ`
  — note KJNodes' upstream misspelling of "Patch", so search the node menu for **"Sage"**).
- Shape: takes a `MODEL` in, returns a patched `MODEL` out. Insert it **between your model loader
  and the KSampler** (patch the model, then sample with the patched model).
- Effect: sage attention is applied only to that model's attention during sampling — scoped to the
  one workflow/branch, so your image workflows on the same server are unaffected.
- Use it on Wan / video model branches. Leave image (Qwen fp8) branches unpatched.

So the pattern for a mixed image+video MCP server is:
**`USE_SAGE_ATTENTION=0` globally  +  the Patch Sage Attention KJ node on video workflows only.**

## 3. Baked node packs (seeded into custom_nodes on boot, on by default)

KJNodes, WanVideoWrapper, VideoHelperSuite, Frame-Interpolation, ComfyUI_essentials,
HuggingFace_Downloader, TTS-Audio-Suite. Category toggles: `SEED_BAKED_NODES`,
`SEED_AUDIO_NODES`, `SEED_VIDEO_NODES`, `SEED_HELPER_NODES` (set any to `0` to skip).

Manager API is open for MCP installs on the LAN box (`network_mode=personal_cloud`,
`security_level=normal`).

## 4. Known-benign log noise (safe to ignore)

- `ComfyUI-Qwen-Omni ... IMPORT FAILED` / `No module named 'qwen_omni_utils'` — that pack requires
  `triton-windows` (Windows-only) and won't install on Linux. It's a user-added pack, not part of
  the baked set. Ignore unless you specifically need Qwen-Omni.
- `comfyui-rmbg` `sam3` / `SDMatte` "attempted relative import" / `submitit` / `pytest` errors — those
  are optional training/eval submodule scripts; rmbg still loads its 44 nodes fine.
- pip resolver warnings about `fish-speech`, `protobuf`, `descript-audiotools` — dependency-graph
  noise from the TTS set; the packages that matter import and run.

## 5. What to validate on your side

1. fp8 Qwen-Image gen with `USE_SAGE_ATTENTION=0` → real images (not black).
2. Wan video with the **Patch Sage Attention KJ** node → sage speedup, output correct.
3. Node menu is clean — no KJNodes `search_aliases` / `advanced` / LTXV import errors (those were the
   0.8.2 API-skew failures the bump fixes).

Please update your MCP docs to describe the per-workflow sage node (section 2) rather than the global
flag, since global sage is unsafe for the image half of your pipeline.
