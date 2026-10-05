#!/usr/bin/env python3
"""Read-only smoke check: the baked texture tiling packs must register their nodes."""

import json
import sys
from urllib.request import urlopen


REQUIRED = {
    # comfyui-advanced-tiling (JosefKuchar/ComfyUI-AdvancedTiling)
    "AdvancedTilingSettings",
    "AdvancedTiling",
    "AdvancedTilingVAEDecode",
    # ComfyUI-Universal-Seamless-Tiles (OliverCrosby)
    "SeamlessTileModelDiT",
    "MakeCircularVAEDiT",
}

base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
with urlopen(f"{base_url.rstrip('/')}/object_info", timeout=30) as response:
    registered = json.load(response)
missing = REQUIRED - registered.keys()
if missing:
    sys.exit(f"Missing texture tiling nodes: {', '.join(sorted(missing))}")
print(f"All {len(REQUIRED)} texture tiling node classes registered")
