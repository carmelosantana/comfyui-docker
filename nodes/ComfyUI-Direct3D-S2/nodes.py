"""Thin ComfyUI nodes over DreamTechAI/Direct3D-S2 (image -> mesh).

The direct3d_s2 package, flash-attn, spconv and udf_ext are baked into the -3d image. They are
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

# spconv ships prebuilt wheels; upstream's default (torchsparse) would need a source build.
os.environ.setdefault("SPARSE_BACKEND", "spconv")

CATEGORY = "Direct3D-S2"
WEIGHTS_REPO = "wushuang98/Direct3D-S2"
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


def to_pil(image, mask):
    """First image of a ComfyUI IMAGE batch -> PIL. A LoadImage MASK (1 = transparent) becomes the
    alpha channel, which tells the pipeline the background is already removed (skips BiRefNet)."""
    rgb = (image[0].clamp(0, 1).cpu().numpy() * 255).round().astype(np.uint8)
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
        import comfy.model_management as mm
        from direct3d_s2.pipeline import Direct3DS2Pipeline
        from huggingface_hub import hf_hub_download

        # Weights (~4.2 GB) download once into HF_HOME, which lives on the models mount.
        with pinned_dinov2():
            pipeline = Direct3DS2Pipeline.from_pretrained(WEIGHTS_REPO, subfolder=version)
        pipeline.to(mm.get_torch_device())
        weights = {
            name: sha256_file(hf_hub_download(WEIGHTS_REPO, name, subfolder=version))
            for name in WEIGHT_FILES
        }
        dinov2 = os.path.join(torch.hub.get_dir(), "checkpoints", DINOV2_CHECKPOINT)
        if os.path.isfile(dinov2):
            weights[DINOV2_CHECKPOINT] = sha256_file(dinov2)
        pipeline.provenance = {
            "weights_repo": WEIGHTS_REPO,
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
                "remesh": ("BOOLEAN", {"default": False}),
                "simplify_ratio": ("FLOAT", {"default": 0.95, "min": 0.0, "max": 1.0, "step": 0.01}),
            },
            "optional": {"mask": ("MASK",)},
        }

    RETURN_TYPES = ("D3DS2_MESH",)
    RETURN_NAMES = ("mesh",)
    FUNCTION = "generate"
    CATEGORY = CATEGORY

    def generate(self, pipeline, image, sdf_resolution, seed, remesh, simplify_ratio, mask=None):
        pil = to_pil(image, mask)
        if pil.mode == "RGBA":
            background_removal = "none (RGBA input)"
        else:
            if getattr(pipeline, "birefnet_model", None) is None:
                attach_birefnet(pipeline)
            background_removal = f"{BIREFNET_REPO}@{BIREFNET_REF}"
        generator = torch.Generator(device=getattr(pipeline, "device", "cpu")).manual_seed(seed)
        mesh = pipeline(
            pil,
            sdf_resolution=int(sdf_resolution),
            generator=generator,
            remesh=remesh,
            simplify_ratio=simplify_ratio,
        )["mesh"]
        mesh.metadata["direct3d_s2"] = {
            **getattr(pipeline, "provenance", {}),
            "seed": seed,
            "sdf_resolution": int(sdf_resolution),
            "remesh": remesh,
            "simplify_ratio": simplify_ratio,
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
