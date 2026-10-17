#!/usr/bin/env python3
"""Read-only smoke check (-3d image): the baked Direct3D-S2 pack must register its nodes."""

import json
import sys
from urllib.request import urlopen


REQUIRED = {
    "Direct3DS2ModelLoader",
    "Direct3DS2ImageToMesh",
    "Direct3DS2SaveMesh",
}

base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
with urlopen(f"{base_url.rstrip('/')}/object_info", timeout=30) as response:
    registered = json.load(response)
missing = REQUIRED - registered.keys()
if missing:
    sys.exit(f"Missing Direct3D-S2 nodes: {', '.join(sorted(missing))}")
print(f"All {len(REQUIRED)} Direct3D-S2 node classes registered")
