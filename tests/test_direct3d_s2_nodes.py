"""Unit tests for the baked ComfyUI-Direct3D-S2 pack. No GPU or weights needed.

Run inside the -3d image (it has torch, PIL and ComfyUI's folder_paths):
  docker run --rm --entrypoint python -v "$PWD:/repo:ro" -w /opt/comfyui comfyui-docker:3d \
      /repo/tests/test_direct3d_s2_nodes.py

The checkpoint-compat test also needs the v1.1 weights (~4.2 GB, not baked). Mount a directory
holding config.yaml and the five .ckpt files and point D3DS2_WEIGHTS at it:
  docker run --rm --entrypoint python -v "$PWD:/repo:ro" -v /path/to/direct3d-s2-v-1-1:/w:ro \
      -e D3DS2_WEIGHTS=/w -w /opt/comfyui comfyui-docker:3d /repo/tests/test_direct3d_s2_nodes.py
"""

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest

import torch
from PIL import Image

sys.path.insert(0, os.getcwd())  # /opt/comfyui, for folder_paths
import folder_paths  # noqa: E402

PACK = os.path.join(os.path.dirname(__file__), "..", "nodes", "ComfyUI-Direct3D-S2", "__init__.py")
spec = importlib.util.spec_from_file_location("d3ds2_pack", PACK, submodule_search_locations=[os.path.dirname(PACK)])
pack = importlib.util.module_from_spec(spec)
sys.modules["d3ds2_pack"] = pack
spec.loader.exec_module(pack)
nodes = sys.modules["d3ds2_pack.nodes"]


REPO = os.path.join(os.path.dirname(__file__), "..")
EXAMPLE_WORKFLOW = os.path.join(REPO, "workflows", "direct3d-s2-image-to-mesh.api.json")


class FakeModelManagement(types.SimpleNamespace):
    """Stands in for comfy.model_management, which needs a GPU driver to import."""

    def __init__(self):
        super().__init__(calls=[])

    def get_torch_device(self):
        return "cpu"

    def unload_all_models(self):
        self.calls.append("unload_all_models")

    def soft_empty_cache(self):
        self.calls.append("soft_empty_cache")


def cutout_mask():
    """A LoadImage MASK with a transparent corner (1 = transparent), as from a background-removed PNG."""
    mask = torch.zeros(1, 4, 6)
    mask[0, 0, 0] = 1.0
    return mask


class FakeRembg:
    def __init__(self):
        self.device = "cpu"
        self.birefnet_model = types.SimpleNamespace(moves=[])
        self.birefnet_model.to = lambda device: self.birefnet_model.moves.append(str(device))


class FakeMesh:
    def __init__(self):
        self.metadata = {}

    def export(self, path):
        with open(path, "w") as f:
            f.write("mesh")


class FakePipeline:
    def __init__(self):
        self.calls = []
        self.moves = []
        self.seen_determinism = None
        self.provenance = {"weights": {"model_dense.ckpt": "abc"}}

    def to(self, device):
        self.moves.append(str(device))
        self.device = device

    def inference(self, *args, **kwargs):  # upstream's per-stage step; wrapped by nodes.staged
        return [None]

    def __call__(self, image, **kwargs):
        self.calls.append((image, kwargs))
        self.seen_determinism = (torch.are_deterministic_algorithms_enabled(),
                                 torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark)
        return {"mesh": FakeMesh()}


class FakeMMTestCase(unittest.TestCase):
    def setUp(self):
        self.mm = FakeModelManagement()
        self._saved_mm = sys.modules.get("comfy.model_management")
        sys.modules["comfy.model_management"] = self.mm

    def tearDown(self):
        if self._saved_mm is None:
            sys.modules.pop("comfy.model_management", None)
        else:
            sys.modules["comfy.model_management"] = self._saved_mm

    def generate(self, pipe, **kwargs):
        args = {"image": torch.ones(1, 4, 6, 3), "sdf_resolution": "512", "seed": 7, "mask": cutout_mask()}
        args.update(kwargs)
        return nodes.Direct3DS2ImageToMesh().generate(pipe, **args)


class MappingTests(unittest.TestCase):
    def test_registers_three_nodes(self):
        self.assertEqual(
            set(pack.NODE_CLASS_MAPPINGS),
            {"Direct3DS2ModelLoader", "Direct3DS2ImageToMesh", "Direct3DS2SaveMesh"},
        )
        self.assertEqual(set(pack.NODE_DISPLAY_NAME_MAPPINGS), set(pack.NODE_CLASS_MAPPINGS))


class ToPilTests(unittest.TestCase):
    def test_no_mask_gives_rgb(self):
        img = nodes.to_pil(torch.ones(1, 4, 6, 3), None)
        self.assertEqual((img.mode, img.size), ("RGB", (6, 4)))
        self.assertEqual(img.getpixel((0, 0)), (255, 255, 255))

    def test_loadimage_mask_becomes_inverted_alpha(self):
        mask = torch.zeros(1, 4, 6)
        mask[0, 0, 0] = 1.0  # LoadImage: 1 = transparent
        img = nodes.to_pil(torch.ones(1, 4, 6, 3), mask)
        self.assertEqual(img.mode, "RGBA")
        self.assertEqual(img.getpixel((0, 0))[3], 0)
        self.assertEqual(img.getpixel((1, 0))[3], 255)

    def test_loadimage_placeholder_mask_means_no_alpha(self):
        # LoadImage returns a 64x64 zero mask for an image without an alpha channel.
        img = nodes.to_pil(torch.ones(1, 4, 6, 3), torch.zeros(1, 64, 64))
        self.assertEqual(img.mode, "RGB")

    def test_fully_opaque_mask_means_no_alpha(self):
        # Nothing was cut out, so the background still needs removing (BiRefNet).
        img = nodes.to_pil(torch.ones(1, 4, 6, 3), torch.zeros(1, 4, 6))
        self.assertEqual(img.mode, "RGB")


class BackendTests(unittest.TestCase):
    def test_forces_torchsparse_backend(self):
        # The published checkpoints were saved with torchsparse; spconv names the weights differently.
        self.assertEqual(os.environ.get("SPARSE_BACKEND"), "torchsparse")

    def test_sparse_conv_uses_checkpoint_key_layout(self):
        from direct3d_s2.modules import sparse as sp

        self.assertEqual(sp.BACKEND, "torchsparse")
        conv = sp.SparseConv3d(4, 8, 3)
        # Checkpoints carry e.g. "encoder.downsample.0.out_layers.0.conv.kernel".
        self.assertEqual(set(conv.state_dict()), {"conv.kernel", "conv.bias"})
        self.assertEqual(tuple(conv.conv.kernel.shape), (27, 4, 8))


# config.yaml section -> (checkpoint file, key inside it), as upstream's from_pretrained loads them.
CHECKPOINT_PARTS = {
    "dense_vae": ("model_dense.ckpt", "vae"),
    "dense_dit": ("model_dense.ckpt", "dit"),
    "sparse_vae_512": ("model_sparse_512.ckpt", "vae"),
    "sparse_dit_512": ("model_sparse_512.ckpt", "dit"),
    "sparse_vae_1024": ("model_sparse_1024.ckpt", "vae"),
    "sparse_dit_1024": ("model_sparse_1024.ckpt", "dit"),
    "refiner": ("model_refiner.ckpt", "refiner"),
    "refiner_1024": ("model_refiner_1024.ckpt", "refiner"),
}


@unittest.skipUnless(os.environ.get("D3DS2_WEIGHTS"), "set D3DS2_WEIGHTS to a direct3d-s2-v-1-1 weights dir")
class CheckpointCompatTests(unittest.TestCase):
    def test_every_checkpoint_loads_strictly_under_the_chosen_backend(self):
        from direct3d_s2.utils import instantiate_from_config
        from omegaconf import OmegaConf

        weights = os.environ["D3DS2_WEIGHTS"]
        cfg = OmegaConf.load(os.path.join(weights, "config.yaml"))
        by_file = {}
        for part, (filename, key) in CHECKPOINT_PARTS.items():
            by_file.setdefault(filename, []).append((part, key))
        for filename, parts in by_file.items():
            state = torch.load(os.path.join(weights, filename), map_location="cpu", weights_only=True)
            for part, key in parts:
                with self.subTest(part=part):
                    model = instantiate_from_config(cfg[part])
                    # Raises on any missing/unexpected key or shape mismatch.
                    model.load_state_dict(state[key], strict=True)
                    del model
            del state


class ImageToMeshTests(FakeMMTestCase):
    def test_passes_settings_and_seeded_generator(self):
        pipe = FakePipeline()
        pipe.birefnet_model = object()  # skip loading the real BiRefNet
        (mesh,) = self.generate(pipe, mask=None)
        self.assertIsInstance(mesh, FakeMesh)
        image, kwargs = pipe.calls[0]
        self.assertIsInstance(image, Image.Image)
        self.assertEqual(kwargs["sdf_resolution"], 512)
        # remesh needs nvdiffrast (research-only) and GPL pymeshfix/igraph, none of which ship.
        self.assertFalse(kwargs["remesh"])
        self.assertEqual(kwargs["generator"].initial_seed(), 7)


    def test_records_provenance_on_mesh(self):
        pipe = FakePipeline()
        (mesh,) = self.generate(pipe, sdf_resolution="1024", seed=42)
        prov = mesh.metadata["direct3d_s2"]
        image = pipe.calls[0][0]
        self.assertEqual((prov["seed"], prov["sdf_resolution"]), (42, 1024))
        self.assertEqual(prov["weights"], {"model_dense.ckpt": "abc"})
        self.assertEqual(prov["input"]["mode"], "RGBA")
        self.assertEqual(prov["input"]["pixel_sha256"], hashlib.sha256(image.tobytes()).hexdigest())
        self.assertEqual(prov["background_removal"], "none (RGBA input)")

    def test_sampler_settings_default_to_upstream(self):
        pipe = FakePipeline()
        (mesh,) = self.generate(pipe)
        kwargs = pipe.calls[0][1]
        self.assertEqual(kwargs["dense_sampler_params"], {"num_inference_steps": 50, "guidance_scale": 7.0})
        self.assertEqual(kwargs["sparse_512_sampler_params"], {"num_inference_steps": 30, "guidance_scale": 7.0})
        self.assertEqual(kwargs["sparse_1024_sampler_params"], {"num_inference_steps": 15, "guidance_scale": 7.0})
        self.assertEqual((kwargs["mc_threshold"], kwargs["remove_interior"]), (0.2, True))
        prov = mesh.metadata["direct3d_s2"]
        self.assertEqual(prov["sampler"], {
            "dense": {"steps": 50, "guidance": 7.0},
            "sparse_512": {"steps": 30, "guidance": 7.0},
            "sparse_1024": {"steps": 15, "guidance": 7.0},
            "mc_threshold": 0.2,
            "remove_interior": True,
        })
        self.assertFalse(prov["deterministic"])
        self.assertEqual(prov["sparse_backend"], "torchsparse")

    def test_sampler_settings_pass_through(self):
        pipe = FakePipeline()
        (mesh,) = self.generate(pipe, dense_steps=20, dense_guidance=5.0, sparse_512_steps=10,
                                sparse_512_guidance=4.0, sparse_1024_steps=8, sparse_1024_guidance=3.0,
                                mc_threshold=0.1, remove_interior=False)
        kwargs = pipe.calls[0][1]
        self.assertEqual(kwargs["dense_sampler_params"], {"num_inference_steps": 20, "guidance_scale": 5.0})
        self.assertEqual(kwargs["sparse_512_sampler_params"], {"num_inference_steps": 10, "guidance_scale": 4.0})
        self.assertEqual(kwargs["sparse_1024_sampler_params"], {"num_inference_steps": 8, "guidance_scale": 3.0})
        self.assertEqual((kwargs["mc_threshold"], kwargs["remove_interior"]), (0.1, False))
        self.assertEqual(mesh.metadata["direct3d_s2"]["sampler"]["sparse_1024"], {"steps": 8, "guidance": 3.0})

    def test_input_types_expose_sampler_settings_with_upstream_defaults(self):
        optional = nodes.Direct3DS2ImageToMesh.INPUT_TYPES()["optional"]
        defaults = {name: spec[1]["default"] for name, spec in optional.items() if len(spec) > 1}
        self.assertEqual(defaults, {
            "dense_steps": 50, "dense_guidance": 7.0, "sparse_512_steps": 30, "sparse_512_guidance": 7.0,
            "sparse_1024_steps": 15, "sparse_1024_guidance": 7.0, "mc_threshold": 0.2,
            "remove_interior": True, "deterministic": False, "unload_after": True,
        })

    def test_deterministic_toggle_is_scoped_to_the_run(self):
        before = (torch.are_deterministic_algorithms_enabled(),
                  torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark)
        pipe = FakePipeline()
        (mesh,) = self.generate(pipe, deterministic=True)
        self.assertEqual(pipe.seen_determinism, (True, True, False))
        self.assertTrue(mesh.metadata["direct3d_s2"]["deterministic"])
        after = (torch.are_deterministic_algorithms_enabled(),
                 torch.backends.cudnn.deterministic, torch.backends.cudnn.benchmark)
        self.assertEqual(after, before)

    def test_moves_to_device_then_unloads_by_default(self):
        pipe = FakePipeline()
        self.generate(pipe)
        self.assertEqual(pipe.moves, ["cpu", "cpu"])  # to the torch device (cpu here), then offloaded
        self.assertIn("unload_all_models", self.mm.calls)
        self.assertEqual(self.mm.calls[-1], "soft_empty_cache")

    def test_unload_after_false_keeps_pipeline_on_device(self):
        pipe = FakePipeline()
        self.generate(pipe, unload_after=False)
        self.assertEqual(pipe.moves, ["cpu"])  # moved to the torch device once, never offloaded
        self.assertNotIn("soft_empty_cache", self.mm.calls)

    def test_birefnet_follows_the_pipeline_on_and_off_the_gpu(self):
        pipe = FakePipeline()
        rembg = FakeRembg()
        pipe.birefnet_model = rembg
        (mesh,) = self.generate(pipe, mask=None)
        self.assertEqual(rembg.birefnet_model.moves, ["cpu", "cpu"])
        self.assertEqual(rembg.device, "cpu")
        self.assertEqual(mesh.metadata["direct3d_s2"]["background_removal"],
                         f"{nodes.BIREFNET_REPO}@{nodes.BIREFNET_REF}")

    def test_unloads_when_the_move_to_the_gpu_fails(self):
        class OomOnFirstMove(FakePipeline):
            def to(self, device):
                super().to(device)
                if len(self.moves) == 1:
                    raise RuntimeError("CUDA out of memory")

        pipe = OomOnFirstMove()
        with self.assertRaisesRegex(RuntimeError, "out of memory"):
            self.generate(pipe)
        self.assertEqual(pipe.moves, ["cpu", "cpu"])
        self.assertEqual(self.mm.calls[-1], "soft_empty_cache")

    def test_unloads_even_when_the_pipeline_fails(self):
        class Boom(FakePipeline):
            def __call__(self, image, **kwargs):
                raise RuntimeError("CUDA out of memory")

        pipe = Boom()
        with self.assertRaisesRegex(RuntimeError, "out of memory"):
            self.generate(pipe)
        self.assertEqual(pipe.moves, ["cpu", "cpu"])
        self.assertEqual(self.mm.calls[-1], "soft_empty_cache")


class LoaderTests(unittest.TestCase):
    def test_loads_pinned_snapshot_and_hashes_its_files(self):
        calls = {}
        with tempfile.TemporaryDirectory() as snap, tempfile.TemporaryDirectory() as hub:
            os.makedirs(os.path.join(snap, "direct3d-s2-v-1-1"))
            for name in nodes.WEIGHT_FILES:
                with open(os.path.join(snap, "direct3d-s2-v-1-1", name), "wb") as f:
                    f.write(name.encode())

            def snapshot_download(repo_id, **kwargs):
                calls["snapshot"] = (repo_id, kwargs)
                return snap

            class FakeD3D:
                @classmethod
                def from_pretrained(cls, path):
                    calls["from_pretrained"] = path
                    return FakePipeline()

                def to(self, device):
                    pass

            fakes = {
                "direct3d_s2.pipeline": types.SimpleNamespace(Direct3DS2Pipeline=FakeD3D),
                "comfy.model_management": types.SimpleNamespace(get_torch_device=lambda: "cpu"),
                "huggingface_hub": types.SimpleNamespace(snapshot_download=snapshot_download),
            }
            saved = {k: sys.modules.get(k) for k in fakes}
            sys.modules.update(fakes)
            real_hub_dir = torch.hub.get_dir()
            torch.hub.set_dir(hub)
            try:
                (pipe,) = nodes.Direct3DS2ModelLoader().load("direct3d-s2-v-1-1")
            finally:
                torch.hub.set_dir(real_hub_dir)
                for k, v in saved.items():
                    if v is None:
                        sys.modules.pop(k, None)
                    else:
                        sys.modules[k] = v

        self.assertEqual(calls["snapshot"], (nodes.WEIGHTS_REPO, {
            "revision": nodes.WEIGHTS_REF, "allow_patterns": ["direct3d-s2-v-1-1/*"]}))
        self.assertEqual(calls["from_pretrained"], os.path.join(snap, "direct3d-s2-v-1-1"))
        prov = pipe.provenance
        self.assertEqual(prov["weights_revision"], nodes.WEIGHTS_REF)
        self.assertEqual(prov["weights"]["config.yaml"], hashlib.sha256(b"config.yaml").hexdigest())
        self.assertEqual(set(prov["weights"]), set(nodes.WEIGHT_FILES))
        self.assertEqual(pipe.moves, ["cpu"])  # VRAM is only taken while a mesh is generated


class FakeModule:
    def __init__(self, name, log):
        self.name, self.log, self.device = name, log, "cpu"

    def to(self, device):
        self.device = str(device)
        return self


class FakeStagedPipeline:
    """Mimics upstream's __call__: one inference() call per stage, each naming its own modules."""

    def __init__(self):
        self.log = []
        for name in nodes.PIPELINE_MODULES:
            setattr(self, name, FakeModule(name, self.log))

    def on(self, device):
        return sorted(name for name in nodes.PIPELINE_MODULES if getattr(self, name).device == device)

    def inference(self, image, vae, dit, conditioner, scheduler, mode="dense", **kwargs):
        self.log.append((mode, self.on("gpu")))
        if mode == "fail":
            raise RuntimeError("CUDA out of memory")
        return [mode]

    def __call__(self, image, sdf_resolution=1024):
        self.inference(image, self.dense_vae, self.dense_dit, self.dense_image_encoder, None, mode="dense")
        self.inference(image, self.sparse_vae_512, self.sparse_dit_512, self.sparse_image_encoder, None,
                       mode="sparse512", remove_interior=True)
        if sdf_resolution == 1024:
            self.inference(image, self.sparse_vae_1024, self.sparse_dit_1024, self.sparse_image_encoder, None,
                           mode="sparse1024", remove_interior=True)


class StageOffloadTests(unittest.TestCase):
    def test_only_the_running_stage_is_on_the_gpu(self):
        pipe = FakeStagedPipeline()
        with nodes.staged(pipe, "gpu"):
            pipe("img")
        self.assertEqual(pipe.log, [
            ("dense", ["dense_dit", "dense_image_encoder", "dense_vae"]),
            ("sparse512", ["refiner", "sparse_dit_512", "sparse_image_encoder", "sparse_vae_512"]),
            ("sparse1024", ["refiner_1024", "sparse_dit_1024", "sparse_image_encoder", "sparse_vae_1024"]),
        ])

    def test_restores_upstream_inference_even_on_failure(self):
        pipe = FakeStagedPipeline()
        with self.assertRaises(RuntimeError):
            with nodes.staged(pipe, "gpu"):
                pipe.inference("img", pipe.dense_vae, pipe.dense_dit, pipe.dense_image_encoder, None, mode="fail")
        self.assertNotIn("inference", vars(pipe))  # the class method is back in charge

    def test_generate_runs_the_pipeline_staged(self):
        seen = {}

        class Recording(FakePipeline):
            def __call__(self, image, **kwargs):
                seen["staged"] = "inference" in vars(self)
                return super().__call__(image, **kwargs)

        mm = FakeModelManagement()
        saved = sys.modules.get("comfy.model_management")
        sys.modules["comfy.model_management"] = mm
        try:
            nodes.Direct3DS2ImageToMesh().generate(Recording(), torch.ones(1, 4, 6, 3), "512", 1, mask=cutout_mask())
        finally:
            if saved is None:
                sys.modules.pop("comfy.model_management", None)
            else:
                sys.modules["comfy.model_management"] = saved
        self.assertTrue(seen["staged"])


class ExampleWorkflowTests(unittest.TestCase):
    def test_example_api_workflow_wires_rgba_loadimage_to_glb(self):
        with open(EXAMPLE_WORKFLOW) as f:
            prompt = json.load(f)
        by_class = {node["class_type"]: (node_id, node["inputs"]) for node_id, node in prompt.items()}
        self.assertEqual(set(by_class), {"LoadImage", "Direct3DS2ModelLoader", "Direct3DS2ImageToMesh",
                                         "Direct3DS2SaveMesh"})
        load_id, _ = by_class["LoadImage"]
        loader_id, loader = by_class["Direct3DS2ModelLoader"]
        mesh_id, mesh = by_class["Direct3DS2ImageToMesh"]
        _, save = by_class["Direct3DS2SaveMesh"]
        self.assertEqual(loader["version"], "direct3d-s2-v-1-1")
        self.assertEqual(mesh["image"], [load_id, 0])
        self.assertEqual(mesh["mask"], [load_id, 1])  # the RGBA alpha: BiRefNet is skipped
        self.assertEqual(mesh["pipeline"], [loader_id, 0])
        self.assertEqual(mesh["sdf_resolution"], "1024")
        self.assertEqual(save["mesh"], [mesh_id, 0])
        self.assertEqual(save["format"], "glb")
        for class_type, (_, inputs) in by_class.items():
            if class_type not in pack.NODE_CLASS_MAPPINGS:
                continue
            types_ = pack.NODE_CLASS_MAPPINGS[class_type].INPUT_TYPES()
            known = set(types_["required"]) | set(types_.get("optional", {}))
            with self.subTest(node=class_type):
                self.assertLessEqual(set(inputs), known)
                self.assertLessEqual(set(types_["required"]), set(inputs))


class PinTests(unittest.TestCase):
    def test_dinov2_hub_load_is_pinned_only_inside_context(self):
        seen = []
        real = torch.hub.load
        torch.hub.load = lambda repo, *a, **k: seen.append(repo)
        try:
            with nodes.pinned_dinov2():
                torch.hub.load("facebookresearch/dinov2", "dinov2_vitl14_reg")
                torch.hub.load("someone/else", "x")
            torch.hub.load("facebookresearch/dinov2", "dinov2_vitl14_reg")
        finally:
            torch.hub.load = real
        self.assertEqual(seen, [
            f"facebookresearch/dinov2:{nodes.DINOV2_REF}",
            "someone/else",
            "facebookresearch/dinov2",
        ])

    def test_sha256_file(self):
        with tempfile.NamedTemporaryFile("wb", delete=False) as f:
            f.write(b"hello")
        try:
            self.assertEqual(nodes.sha256_file(f.name), hashlib.sha256(b"hello").hexdigest())
        finally:
            os.unlink(f.name)


class SaveMeshTests(unittest.TestCase):
    def test_writes_into_output_dir(self):
        with tempfile.TemporaryDirectory() as out:
            folder_paths.set_output_directory(out)
            result = nodes.Direct3DS2SaveMesh().save(FakeMesh(), "3d/d3d", "glb")
            saved = result["ui"]["meshes"][0]
            path = os.path.join(out, saved["subfolder"], saved["filename"])
            self.assertTrue(os.path.isfile(path))
            self.assertTrue(saved["filename"].startswith("d3d_") and saved["filename"].endswith(".glb"))
            self.assertEqual((saved["subfolder"], saved["type"]), ("3d", "output"))

    def test_writes_provenance_sidecar(self):
        with tempfile.TemporaryDirectory() as out:
            folder_paths.set_output_directory(out)
            mesh = FakeMesh()
            mesh.metadata["direct3d_s2"] = {"seed": 42}
            saved = nodes.Direct3DS2SaveMesh().save(mesh, "d3d", "glb")["ui"]["meshes"][0]
            path = os.path.join(out, saved["filename"])
            with open(path + ".json") as f:
                sidecar = json.load(f)
            self.assertEqual(sidecar["seed"], 42)
            self.assertEqual(sidecar["output"], {"filename": saved["filename"], "sha256": nodes.sha256_file(path)})


if __name__ == "__main__":
    unittest.main(verbosity=2)
