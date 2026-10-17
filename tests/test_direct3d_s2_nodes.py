"""Unit tests for the baked ComfyUI-Direct3D-S2 pack. No GPU or weights needed.

Run inside the -3d image (it has torch, PIL and ComfyUI's folder_paths):
  docker run --rm --entrypoint python -v "$PWD:/repo:ro" -w /opt/comfyui comfyui-docker:3d \
      /repo/tests/test_direct3d_s2_nodes.py
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


class FakeMesh:
    def __init__(self):
        self.metadata = {}

    def export(self, path):
        with open(path, "w") as f:
            f.write("mesh")


class FakePipeline:
    def __init__(self):
        self.calls = []
        self.provenance = {"weights": {"model_dense.ckpt": "abc"}}

    def __call__(self, image, **kwargs):
        self.calls.append((image, kwargs))
        return {"mesh": FakeMesh()}


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


class ImageToMeshTests(unittest.TestCase):
    def test_passes_settings_and_seeded_generator(self):
        pipe = FakePipeline()
        pipe.birefnet_model = object()  # skip loading the real BiRefNet
        (mesh,) = nodes.Direct3DS2ImageToMesh().generate(pipe, torch.ones(1, 4, 6, 3), "512", 7, mask=None)
        self.assertIsInstance(mesh, FakeMesh)
        image, kwargs = pipe.calls[0]
        self.assertIsInstance(image, Image.Image)
        self.assertEqual(kwargs["sdf_resolution"], 512)
        # remesh needs nvdiffrast (research-only) and GPL pymeshfix/igraph, none of which ship.
        self.assertFalse(kwargs["remesh"])
        self.assertEqual(kwargs["generator"].initial_seed(), 7)


    def test_records_provenance_on_mesh(self):
        pipe = FakePipeline()
        mask = torch.zeros(1, 4, 6)
        (mesh,) = nodes.Direct3DS2ImageToMesh().generate(pipe, torch.ones(1, 4, 6, 3), "1024", 42, mask=mask)
        prov = mesh.metadata["direct3d_s2"]
        image = pipe.calls[0][0]
        self.assertEqual((prov["seed"], prov["sdf_resolution"]), (42, 1024))
        self.assertEqual(prov["weights"], {"model_dense.ckpt": "abc"})
        self.assertEqual(prov["input"]["mode"], "RGBA")
        self.assertEqual(prov["input"]["pixel_sha256"], hashlib.sha256(image.tobytes()).hexdigest())
        self.assertEqual(prov["background_removal"], "none (RGBA input)")


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

            FakePipeline.to = lambda self, device: None
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
