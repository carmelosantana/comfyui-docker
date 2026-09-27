#!/usr/bin/env python3
"""Read-only smoke check: core SAM 3D Body nodes must register without weights."""

import json
import sys
from urllib.request import urlopen


REQUIRED = {
    "SAM3DBody_Loader",
    "SAM3DBody_Predict",
    "SAM3DBody_FaceExpression",
    "SAM3DBody_Smooth",
    "SAM3DBody_Render",
    "BuildPoseFile",
}

base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
with urlopen(f"{base_url.rstrip('/')}/object_info", timeout=30) as response:
    registered = json.load(response)
missing = REQUIRED - registered.keys()
if missing:
    sys.exit(f"Missing core SAM 3D Body nodes: {', '.join(sorted(missing))}")
print(f"All {len(REQUIRED)} core SAM 3D Body / BVH node classes registered")
