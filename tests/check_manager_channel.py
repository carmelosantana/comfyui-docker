#!/usr/bin/env python3
"""Read-only smoke check: Manager's channel_url must be the 'default' channel.

Otherwise Manager's boot cache refresh is keyed on a different URL than install lookups read,
and installs only see the node list bundled in the Manager wheel.
"""

import json
import sys
from urllib.request import urlopen

base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
with urlopen(f"{base_url.rstrip('/')}/v2/manager/channel_url_list", timeout=30) as response:
    selected = json.load(response).get("selected")
if selected != "default":
    sys.exit(f"Manager channel_url is '{selected}', expected 'default'")
print("Manager channel_url is the 'default' channel")
