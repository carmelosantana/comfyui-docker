"""Thin ComfyUI nodes over DreamTechAI/Direct3D-S2 (image -> mesh).

The direct3d_s2 package, flash-attn, torchsparse and udf_ext are baked into the -3d image. They are
imported lazily so the nodes still register on a --cpu boot, where CUDA cannot initialise.
"""

import contextlib
import hashlib
import json
import os

import numpy as np
import torch
from PIL import Image

import folder_paths

# The published checkpoints were saved with torchsparse (keys "conv.kernel"); spconv names the same
# weights "conv.weight" in a different layout and fails a strict load. Forced, not defaulted, so a
# host-wide SPARSE_BACKEND cannot pick the wrong one.
os.environ["SPARSE_BACKEND"] = "torchsparse"

CATEGORY = "Direct3D-S2"
WEIGHTS_REPO = "wushuang98/Direct3D-S2"
WEIGHTS_REF = "8b04a8eddb7a56a0f4e89fe5f5b840c7d5610c00"  # MIT
WEIGHT_FILES = ("config.yaml", "model_dense.ckpt", "model_sparse_512.ckpt", "model_sparse_1024.ckpt",
                "model_refiner.ckpt", "model_refiner_1024.ckpt")
# Both run remote code on first use, so pin it. Licence-cleared chain: DINOv2 (Apache-2.0) and
# BiRefNet (MIT). Never swap in DINOv3 or RMBG-2.0 (non-commercial).
DINOV2_REPO = "facebookresearch/dinov2"
DINOV2_REF = "7764ea0f912e53c92e82eb78a2a1631e92725fc8"
DINOV2_CHECKPOINT = "dinov2_vitl14_reg4_pretrain.pth"
BIREFNET_REPO = "ZhengPeng7/BiRefNet"
BIREFNET_REF = "e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


@contextlib.contextmanager
def pinned_dinov2():
    """Upstream's config loads torch.hub "facebookresearch/dinov2" at its default branch. Rewrite
    just that repo to the pinned commit while the pipeline is built."""
    real = torch.hub.load

    def load(repo_or_dir, *args, **kwargs):
        if repo_or_dir == DINOV2_REPO:
            repo_or_dir = f"{DINOV2_REPO}:{DINOV2_REF}"
        return real(repo_or_dir, *args, **kwargs)

    torch.hub.load = load
    try:
        yield
    finally:
        torch.hub.load = real


def attach_birefnet(pipeline):
    """Pre-load the pipeline's lazy BiRefNet at the pinned revision (upstream uses main)."""
    from direct3d_s2.utils.rembg import BiRefNet
    from transformers import AutoModelForImageSegmentation

    rembg = BiRefNet.__new__(BiRefNet)
    rembg.device = pipeline.device
    rembg.birefnet_model = AutoModelForImageSegmentation.from_pretrained(
        BIREFNET_REPO, revision=BIREFNET_REF, trust_remote_code=True
    ).to(pipeline.device).eval()
    pipeline.birefnet_model = rembg


@contextlib.contextmanager
def determinism(enabled):
    """Deterministic PyTorch/cuDNN kernels for one run only, then restore ComfyUI's own settings.
    warn_only: an op with no deterministic kernel warns instead of failing the job. Custom kernels
    (torchsparse, flash-attn) are not covered, so this reduces run-to-run drift but cannot promise
    bit-identical meshes."""
    if not enabled:
        yield
        return
    saved = (torch.are_deterministic_algorithms_enabled(), torch.is_deterministic_algorithms_warn_only_enabled(),
             torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark)
    torch.use_deterministic_algorithms(True, warn_only=True)
    torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark = True, False
    try:
        yield
    finally:
        torch.use_deterministic_algorithms(saved[0], warn_only=saved[1])
        torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark = saved[2], saved[3]


def place(pipeline, device):
    """Move the pipeline and its attached BiRefNet, if any, to one device."""
    pipeline.to(device)
    rembg = getattr(pipeline, "birefnet_model", None)
    if getattr(rembg, "birefnet_model", None) is not None:
        rembg.birefnet_model.to(device)
        rembg.device = pipeline.device


# Every model upstream's pipeline holds, and the refiner each sparse stage runs after decoding.
PIPELINE_MODULES = ("dense_vae", "dense_dit", "sparse_vae_512", "sparse_dit_512", "sparse_vae_1024",
                    "sparse_dit_1024", "refiner", "refiner_1024", "dense_image_encoder", "sparse_image_encoder")
STAGE_REFINER = {"sparse512": "refiner", "sparse1024": "refiner_1024"}


@contextlib.contextmanager
def staged(pipeline, device):
    """Keep only the running stage's models on the GPU. Upstream holds all of them (two DINOv2 ViT-L
    copies included) for the whole job, so the 512-stage refiner, the peak, ran out of a 24 GB card
    inside ComfyUI. Each upstream stage is one inference() call naming its vae, dit and image encoder."""
    real = pipeline.inference

    def inference(image, vae, dit, conditioner, *args, **kwargs):
        keep = {id(vae), id(dit), id(conditioner)}
        refiner = getattr(pipeline, STAGE_REFINER.get(kwargs.get("mode", "dense"), ""), None)
        if refiner is not None:
            keep.add(id(refiner))
        modules = [m for m in (getattr(pipeline, name, None) for name in PIPELINE_MODULES) if m is not None]
        for module in modules:  # off first, so the stage's own models never share VRAM with the rest
            if id(module) not in keep:
                module.to("cpu")
        for module in modules:
            if id(module) in keep:
                module.to(device)
        return real(image, vae, dit, conditioner, *args, **kwargs)

    pipeline.inference = inference
    try:
        yield
    finally:
        del pipeline.inference


def to_pil(image, mask):
    """First image of a ComfyUI IMAGE batch -> PIL. A LoadImage MASK (1 = transparent) becomes the
    alpha channel, which tells the pipeline the background is already removed (skips BiRefNet).
    LoadImage gives a 64x64 zero mask for an image without alpha, and a fully opaque alpha removes no
    background either; both count as no mask, so BiRefNet runs."""
    rgb = (image[0].clamp(0, 1).cpu().numpy() * 255).round().astype(np.uint8)
    if mask is not None and (tuple(mask.shape[-2:]) != rgb.shape[:2] or not bool(mask[0].any())):
        mask = None
    if mask is None:
        return Image.fromarray(rgb, "RGB")
    alpha = ((1.0 - mask[0].clamp(0, 1)).cpu().numpy() * 255).round().astype(np.uint8)
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


class Direct3DS2ModelLoader:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"version": (["direct3d-s2-v-1-1", "direct3d-s2-v-1-0"],)}}

    RETURN_TYPES = ("D3DS2_PIPELINE",)
    RETURN_NAMES = ("pipeline",)
    FUNCTION = "load"
    CATEGORY = CATEGORY

    def load(self, version):
        from direct3d_s2.pipeline import Direct3DS2Pipeline
        from huggingface_hub import snapshot_download

        # Weights (~4.2 GB) download once into HF_HOME, on the models mount. With them staged,
        # HF_HUB_OFFLINE=1 resolves the same pinned snapshot with no network. Upstream loads the
        # .ckpt pickles with torch.load(weights_only=True).
        snapshot = snapshot_download(WEIGHTS_REPO, revision=WEIGHTS_REF, allow_patterns=[f"{version}/*"])
        weights_dir = os.path.join(snapshot, version)
        with pinned_dinov2():
            pipeline = Direct3DS2Pipeline.from_pretrained(weights_dir)
        # Held in CPU RAM; ImageToMesh moves it to the GPU only for the run.
        pipeline.to("cpu")
        weights = {name: sha256_file(os.path.join(weights_dir, name)) for name in WEIGHT_FILES}
        dinov2 = os.path.join(torch.hub.get_dir(), "checkpoints", DINOV2_CHECKPOINT)
        if os.path.isfile(dinov2):
            weights[DINOV2_CHECKPOINT] = sha256_file(dinov2)
        pipeline.provenance = {
            "weights_repo": WEIGHTS_REPO,
            "weights_revision": WEIGHTS_REF,
            "version": version,
            "weights": weights,
            "dinov2": f"{DINOV2_REPO}@{DINOV2_REF}",
        }
        return (pipeline,)


class Direct3DS2ImageToMesh:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "pipeline": ("D3DS2_PIPELINE",),
                "image": ("IMAGE",),
                # 512 needs ~10 GB VRAM, 1024 ~24 GB.
                "sdf_resolution": (["1024", "512"],),
                "seed": ("INT", {"default": 0, "min": 0, "max": 0xFFFFFFFFFFFFFFFF}),
            },
            # Optional so older API workflows keep validating; the defaults are upstream's __call__ ones.
            "optional": {
                "mask": ("MASK",),
                "dense_steps": ("INT", {"default": 50, "min": 1, "max": 200}),
                "dense_guidance": ("FLOAT", {"default": 7.0, "min": 0.0, "max": 30.0, "step": 0.1}),
                "sparse_512_steps": ("INT", {"default": 30, "min": 1, "max": 200}),
                "sparse_512_guidance": ("FLOAT", {"default": 7.0, "min": 0.0, "max": 30.0, "step": 0.1}),
                "sparse_1024_steps": ("INT", {"default": 15, "min": 1, "max": 200}),
                "sparse_1024_guidance": ("FLOAT", {"default": 7.0, "min": 0.0, "max": 30.0, "step": 0.1}),
                "mc_threshold": ("FLOAT", {"default": 0.2, "min": 0.0, "max": 1.0, "step": 0.01}),
                # Upstream applies this to the 1024 stage only (512 always removes the interior).
                "remove_interior": ("BOOLEAN", {"default": True}),
                # Same seed + deterministic kernels, for re-run checks. Slower; off by default.
                "deterministic": ("BOOLEAN", {"default": False}),
                # A 1024 run peaks near 21 GB; give the VRAM back to ComfyUI once the mesh is built.
                "unload_after": ("BOOLEAN", {"default": True}),
            },
        }

    RETURN_TYPES = ("D3DS2_MESH",)
    RETURN_NAMES = ("mesh",)
    FUNCTION = "generate"
    CATEGORY = CATEGORY

    def generate(self, pipeline, image, sdf_resolution, seed, mask=None, dense_steps=50, dense_guidance=7.0,
                 sparse_512_steps=30, sparse_512_guidance=7.0, sparse_1024_steps=15, sparse_1024_guidance=7.0,
                 mc_threshold=0.2, remove_interior=True, deterministic=False, unload_after=True):
        import comfy.model_management as mm

        pil = to_pil(image, mask)
        if pil.mode == "RGBA":
            background_removal = "none (RGBA input)"
        else:
            background_removal = f"{BIREFNET_REPO}@{BIREFNET_REF}"
        sampler = {
            "dense": {"steps": dense_steps, "guidance": dense_guidance},
            "sparse_512": {"steps": sparse_512_steps, "guidance": sparse_512_guidance},
            "sparse_1024": {"steps": sparse_1024_steps, "guidance": sparse_1024_guidance},
            "mc_threshold": mc_threshold,
            "remove_interior": remove_interior,
        }
        params = {stage: {"num_inference_steps": sampler[stage]["steps"], "guidance_scale": sampler[stage]["guidance"]}
                  for stage in ("dense", "sparse_512", "sparse_1024")}
        # Make room: evict ComfyUI's cached models before taking ~21 GB.
        mm.unload_all_models()
        try:
            place(pipeline, mm.get_torch_device())
            if pil.mode != "RGBA" and getattr(pipeline, "birefnet_model", None) is None:
                attach_birefnet(pipeline)
            generator = torch.Generator(device=pipeline.device).manual_seed(seed)
            with determinism(deterministic), staged(pipeline, pipeline.device):
                mesh = pipeline(
                    pil,
                    sdf_resolution=int(sdf_resolution),
                    dense_sampler_params=params["dense"],
                    sparse_512_sampler_params=params["sparse_512"],
                    sparse_1024_sampler_params=params["sparse_1024"],
                    generator=generator,
                    mc_threshold=mc_threshold,
                    remove_interior=remove_interior,
                    # Upstream's remesh needs nvdiffrast (research-only) and GPL pymeshfix/igraph; the
                    # image ships none of them, so it stays off.
                    remesh=False,
                )["mesh"]
        finally:
            if unload_after:
                place(pipeline, "cpu")
                mm.soft_empty_cache()
        mesh.metadata["direct3d_s2"] = {
            **getattr(pipeline, "provenance", {}),
            "seed": seed,
            "sdf_resolution": int(sdf_resolution),
            "sampler": sampler,
            "deterministic": deterministic,
            "sparse_backend": "torchsparse",
            "background_removal": background_removal,
            # Hash of the exact pixels the pipeline received (the source file is not visible here).
            "input": {"mode": pil.mode, "size": list(pil.size),
                      "pixel_sha256": hashlib.sha256(pil.tobytes()).hexdigest()},
        }
        return (mesh,)


class Direct3DS2SaveMesh:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "mesh": ("D3DS2_MESH",),
                "filename_prefix": ("STRING", {"default": "3d/direct3d_s2"}),
                "format": (["glb", "obj", "ply"],),
            }
        }

    RETURN_TYPES = ()
    FUNCTION = "save"
    OUTPUT_NODE = True
    CATEGORY = CATEGORY

    def save(self, mesh, filename_prefix, format):
        out_dir = folder_paths.get_output_directory()
        folder, name, counter, subfolder, _ = folder_paths.get_save_image_path(filename_prefix, out_dir)
        filename = f"{name}_{counter:05}_.{format}"
        path = os.path.join(folder, filename)
        mesh.export(path)
        # Provenance sidecar: weights/input sha256s, seed and resolution, plus this file's sha256.
        sidecar = {**mesh.metadata.get("direct3d_s2", {}),
                   "output": {"filename": filename, "sha256": sha256_file(path)}}
        with open(path + ".json", "w") as f:
            json.dump(sidecar, f, indent=2)
        return {"ui": {"meshes": [{"filename": filename, "subfolder": subfolder, "type": "output"}]}}
