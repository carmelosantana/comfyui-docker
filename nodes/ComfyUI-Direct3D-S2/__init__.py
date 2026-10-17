from .nodes import Direct3DS2ImageToMesh, Direct3DS2ModelLoader, Direct3DS2SaveMesh

NODE_CLASS_MAPPINGS = {
    "Direct3DS2ModelLoader": Direct3DS2ModelLoader,
    "Direct3DS2ImageToMesh": Direct3DS2ImageToMesh,
    "Direct3DS2SaveMesh": Direct3DS2SaveMesh,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "Direct3DS2ModelLoader": "Direct3D-S2 Model Loader",
    "Direct3DS2ImageToMesh": "Direct3D-S2 Image to Mesh",
    "Direct3DS2SaveMesh": "Direct3D-S2 Save Mesh",
}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
