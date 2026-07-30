# SageAttention for video — quick brief

**Image:** `ghcr.io/carmelosantana/comfyui-docker:latest-sage` (ComfyUI 0.29.0, SageAttention 2.2.0 baked in).

## The rule

Run the container with **`USE_SAGE_ATTENTION=0`** and turn sage on **per-workflow, on the video model only**.
The global `--use-sage-attention` flag is all-or-nothing and NaNs/black-frames fp8 image models (Qwen-Image/Flux),
so we keep it off globally and scope sage to the Wan video branch with a node.

## How to enable it on a Wan/video workflow

Add the **"Patch Sage Attention KJ"** node (from ComfyUI-KJNodes, already in the image):

```
Load model (Wan)  ──►  Patch Sage Attention KJ  ──►  KSampler / sampler
                          (MODEL in → MODEL out)
```

- Insert it **between the model loader and the sampler** — patch the model, then sample with the patched model.
- Search the node menu for **"Sage"** (its internal class id is `PathchSageAttentionKJ` — note the upstream typo).
- Leave the `mode` on its default (auto) unless you're benchmarking kernels.
- Sage now applies only to that model's attention during sampling. Any image (Qwen fp8) branch on the same server
  stays on standard attention and renders correctly.

## Sanity checks

- Global attention should read `Using pytorch attention` in the boot log (i.e. `USE_SAGE_ATTENTION=0` took effect).
- If video output is NaN/garbage, confirm the patch node is actually wired inline (a stray/unconnected node does nothing).
- Sage is a video speedup on the 3090; expect faster sampling on Wan, no quality regression.
