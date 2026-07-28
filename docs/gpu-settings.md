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
