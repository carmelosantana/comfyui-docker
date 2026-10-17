"""Unit tests for the baked ComfyUI-Direct3D-S2 pack. No GPU or weights needed.

Run inside the -3d image (it has torch, PIL and ComfyUI's folder_paths):
  docker run --rm --entrypoint python -v "$PWD:/repo:ro" -w /opt/comfyui comfyui-docker:3d \
      /repo/tests/test_direct3d_s2_nodes.py
"""

import importlib.util
import os
import sys
import tempfile
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


class FakePipeline:
    def __init__(self):
        self.calls = []

    def __call__(self, image, **kwargs):
        self.calls.append((image, kwargs))
        return {"mesh": "MESH"}


class FakeMesh:
    def export(self, path):
        with open(path, "w") as f:
            f.write("mesh")


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
        (mesh,) = nodes.Direct3DS2ImageToMesh().generate(
            pipe, torch.ones(1, 4, 6, 3), "512", 7, True, 0.9, mask=None
        )
        self.assertEqual(mesh, "MESH")
        image, kwargs = pipe.calls[0]
        self.assertIsInstance(image, Image.Image)
        self.assertEqual(kwargs["sdf_resolution"], 512)
        self.assertTrue(kwargs["remesh"])
        self.assertEqual(kwargs["simplify_ratio"], 0.9)
        self.assertEqual(kwargs["generator"].initial_seed(), 7)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
