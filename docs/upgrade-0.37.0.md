# ComfyUI v0.33.1 → v0.37.0

Prepared 2026-09-27 for Kanboard #4666. Latest confirmed using
`gh api repos/Comfy-Org/ComfyUI/releases/latest --jq .tag_name` → `v0.37.0`.
Both `base` (`latest`) and `sage` (`latest-sage`) inherit the updated core pin.
PyTorch 2.9.1, CUDA 12.8, Manager 4.2.2 and the baked custom-node pins are unchanged.

## Release review

Reviewed all four release notes, plus the v0.33.1 notes and the two tags' requirements.
The v0.34.0 release compares against v0.33.0 and includes changes already in v0.33.1.

| Release | Compatibility concerns for this deployment |
| --- | --- |
| [v0.34.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.34.0) | Introduces SAM 3D Body and BVH export. CreateVideo gains colorspace and changes bit_depth to a combo; PyAV minimum becomes 17. Python 3.10 deprecation warning; current server is Python 3.11. Retires some partner nodes/models (Kling v2 image, Tripo Refine/v2.0). |
| [v0.35.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.35.0) | RAM accounting now respects container limits. Introduces Comfy Compiler. MiniMax H3 controlnet moves to model-patch handling. Changes alpha-channel operations and 3D saved-output reporting; retires Veo 2/3.0 and other partner models. |
| [v0.36.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.36.0) | Generic loops change execution internals; assets records/content split. Tripo moves to v3, Gemini V2 is deprecated. These are not node classes used by the inspected fastfood workflows. |
| [v0.37.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.37.0) | Detects fast disks automatically; adds an opt-out. Dynamic VRAM places text encoders on GPU. Changes EmptyLatentImage defaults and node display names/categories. Wan memory optimizations and MiniMax Music CUDA-graph fix. |

No release-note item establishes a required rewrite of the inspected fastfood workflows, but
node registration alone cannot prove input compatibility, render quality or VRAM headroom.
Retain the 3090 sample settings, including `USE_SAGE_ATTENTION=0` globally in the sage sample;
validate video's per-workflow SageAttention and fp8 image generation after deployment.

Actual tag requirements (not just release-note descriptions):

| Dependency | v0.33.1 | v0.37.0 |
| --- | --- | --- |
| comfyui-frontend-package | 1.48.7 | 1.52.7 |
| comfyui-workflow-templates | 0.11.41 | 0.11.66 |
| comfyui-embedded-docs | 0.5.9 | 0.5.12 |
| av | >=16.0.0 | >=17.0.0 |
| comfy-kitchen | 0.2.31 | 0.2.35 |
| comfy-aimdo | 0.4.13 | 0.5.5 |

The v0.37.0 notes mention frontend 1.53.6, but the tagged requirements pin 1.52.7.
The Docker build follows the tagged requirements. Baked node installers can subsequently alter
Python dependencies, so CI must actually boot both final images.

The first CI attempt exposed an existing installer incompatibility: pip's vendored packaging
raised `InvalidVersion: '6.17.0-1022-azure'` while evaluating pixeloe's platform marker.
The base stage now pins pip 26.2.1 (PyPI release 2026-08-04). A four-case marker regression
check reproduces the crash with pip 25.2 and passes with 26.2.1; the build runs that check
before installing application dependencies. This also applies to the derived sage image.

## Validation and deployment gates

1. PR CI builds both `comfyui-ci:smoke` and `comfyui-ci:sage`, boots each with `--cpu`, checks
   Manager v4+, and queries `/object_info` with `tests/check_sam3d_nodes.py`. Sage CI also
   checks the SageAttention package. This does not exercise CUDA kernels or download weights.
2. Get Carmelo's deployment approval. Coordinate the window on Kanboard #4664 and #4665;
   recheck `GET /queue` immediately before replacing the container. Both `queue_running`
   and `queue_pending` must be empty. Never cancel, interrupt, or clear jobs.
3. Before replacement, save a custom-node snapshot with repo commits and local changes;
   record the running container's image tag, immutable image ID/digest, actual compose
   configuration and mounts. Preserve the previous image and snapshot for rollback.
4. On the GPU host, compare the version in `head -1 /proc/driver/nvidia/version` with
   `modinfo -F version nvidia` before the first GPU run. A mismatch blocks the run.
5. Deploy the approved image from this PR's commit (or a separately approved merge's published
   image). PR CI only loads images on its runners; it does not publish GHCR tags. Record the
   actual deployed tag/digest on Kanboard #4666; do not assume a mutable `latest-sage` is this PR.
6. Query `/object_info` for every `class_type` in fastfood's animation, sheet, cast, t2v and mesh
   workflows. The mesh workflow includes custom `BiRefNetRMBG`. Check input schemas as well.
   Confirm all six classes in `tests/check_sam3d_nodes.py` and run one cheap real fastfood render.
7. Ask Carmelo before downloading SAM 3D Body weights. Then execute a short clip through
   SAM3DBody prediction/smoothing and BuildPoseFile with BVH output. Validate nonempty BVH
   hierarchy/motion, frame count and timing. Record prompt ID and output path on the ticket.
8. If node checks or renders regress, coordinate an empty-queue rollback to the recorded
   previous image and restore the custom-node snapshot. Never stop another agent's render.
9. After Carmelo confirms success, show specific old/dangling images and build-cache candidates
   and ask before deleting. Never delete volumes or the model store.

## Baseline and blockers (before deployment)

The live HTTP API reports ComfyUI 0.33.1, Python 3.11.14, PyTorch 2.9.1+cu128.
All 50 unique classes in the five workflows in fastfood's main checkout are registered.
The mesh workflow is in the `sharp-feynman-b2d488` worktree; all 12 of its classes are registered,
including BiRefNetRMBG. No SAM3DBody classes or BuildPoseFile are registered before upgrade.
The new smoke check fails against this old server with all six required classes missing.

Host access is unresolved: `ssh` to `carmelo@comfyui` rejects the available key. Manager 4.2.2's
`GET /v2/snapshot/get_current` and `POST /v2/snapshot/save` both return HTTP 400. Therefore no
successful rollback snapshot or exact running image identification has been recorded yet.
These must be resolved before deployment. No deployment or GPU test has occurred.

## Auto-bump diagnosis

The 2026-09-21 run (35564854327) fails at create-pull-request with
`Input 'token' not supplied. Unable to continue.` Repository Actions secrets are empty.
The preceding September 7/14 runs also failed. `main` already requires `build` and `build-sage`
from GitHub Actions, and `allow_auto_merge=true`; no protection change is needed.
See README's Updating section for the owner-only PAT setup. Do not provide the token to an agent.

`create-pull-request@v7` also emits a Node 20 deprecation warning; this is separate from the
missing-token error. Action upgrades/SHA pinning are deferred from this core-version upgrade.
