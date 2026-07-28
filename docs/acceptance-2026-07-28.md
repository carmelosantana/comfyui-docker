# Acceptance evidence — 2026-07-28

Task 13: prove that against the running container, ComfyUI boots on `:8188`,
ComfyUI-Manager reports v4+, and the two v3.x failures are gone:

- node-pack install → HTTP `405`
- arbitrary-URL model download → HTTP `500` "Arbitrary-URL model installs REQUIRE Manager v4+"

Host has **no NVIDIA container runtime**; container run CPU-only (`--cpu` forwarded via `"$@"`).

## Verdict — SUPERSEDED: now PASSING as-built (fix applied)

**PASS (as-built image).** Both previously-failing calls return **HTTP 200** against the shipped
`comfyui-test` image on `:8188`, CPU-only, with no code-level diagnostic workaround.

> The earlier BLOCKED state (recorded below for history) was caused by the image never activating
> Manager v4. It was fixed by three coordinated changes: (1) `pip install /opt/comfyui-manager` in
> the Dockerfile so `import comfyui_manager` resolves; (2) adding `--enable-manager` to both
> `main.py` exec branches in `source/entrypoint.sh`; (3) replacing the harmful v3 `link_manager`
> symlink with `remove_stale_manager` (purges any stale v3 ComfyUI-Manager from the custom_nodes
> mount, creates no symlink). A follow-on permission fix recursively chowns the Manager v4 state
> dir `user/__manager` to the runtime user so it can create its `snapshots/`/`cache/` subdirs.

### As-built passing evidence (2026-07-28, post-fix)

- Build final line: `#19 naming to docker.io/library/comfyui-test:latest done`
- `pip show comfyui_manager` in-container: `Name: comfyui-manager` / `Version: 4.0.5`
- Launch flag confirmed via `main.py --help`: **`--enable-manager`** ("Enable the ComfyUI-Manager feature.")
- Boot process cmdline: `... python main.py --port 8188 --listen 0.0.0.0 --disable-auto-launch --enable-manager --cpu`
- Manager liveness: `GET /v2/manager/queue/status` → **HTTP 200** (routes registered; no `IMPORT FAILED`).
- Log: `[START] ComfyUI-Manager`, `config path: /opt/comfyui/user/__manager/config.ini`, `network_mode: public`.

```
node-install    POST /v2/manager/queue/task           -> HTTP 200   (405 gating GONE)
model-download  POST /v2/manager/queue/install_model  -> HTTP 200   (500 "REQUIRES Manager v4+" GONE)
```

Worker log showed `[START] Security scan` / `[DONE] Security scan` and **no** "REQUIRE Manager v4+"
or arbitrary-URL rejection. `user/__manager/config.ini` confirmed `security_level = weak` /
`network_mode = public` in effect.

Unit suites: `test_entrypoint.sh` **24/0**, `test_bootstrap_nodes.sh` **4/0**,
`test_cleanup_legacy.sh` **10/0**.

---

## Historical (blocked) evidence

_The section below is the original BLOCKED run, kept for provenance. It has been superseded by the
passing result above._

### Verdict (original)

**BLOCKED (as-built image) — with a diagnostic proof that the Manager v4 code itself is correct.**

The shipped image (`comfyui-test`, built from this branch) does **not** load ComfyUI-Manager v4
at runtime, so the Manager API routes do not exist and both previously-failing calls return
**HTTP 405** — not because the v3 gating is back, but because **the Manager never loads at all**.
Two image defects cause this (see Root cause). When the Manager is loaded the correct v4 way
(pip-installed package + `--enable-manager`), **both calls return HTTP 200** — the v3.x gating is
genuinely gone. The image must be fixed before this acceptance test can pass as-built.

---

## Step 1 — Build

`docker build -t comfyui-test .` succeeded. Final line:

```
#18 naming to docker.io/library/comfyui-test:latest done
```

## Step 2 — Shell unit suites (all 0 failed)

```
tests/test_entrypoint.sh        ---- 24 checks, 0 failed ----
tests/test_bootstrap_nodes.sh   ---- 4 checks, 0 failed ----
tests/test_cleanup_legacy.sh    ---- 10 checks, 0 failed ----
```

## Step 3 — Boot CPU-only

```
docker run -d --name comfyui-accept -p 8188:8188 -e USER_ID=1000 -e GROUP_ID=1000 comfyui-test --cpu
```

ComfyUI answered on `:8188` after ~25s. `curl -sS http://localhost:8188/ | head`:

```
<!doctype html><html lang="en"><head>...<title>ComfyUI</title>...
```

Boot process command line (note: **no `--enable-manager`**):

```
python main.py --port 8188 --listen 0.0.0.0 --disable-auto-launch --cpu
```

`docker logs` at boot showed the Manager failing to import:

```
Cannot import /opt/comfyui/custom_nodes/ComfyUI-Manager module for custom nodes:
[Errno 2] No such file or directory: '/opt/comfyui/custom_nodes/ComfyUI-Manager/__init__.py'
   0.0 seconds (IMPORT FAILED): /opt/comfyui/custom_nodes/ComfyUI-Manager
```

## Step 4 — Manager version

```
docker exec comfyui-accept git -C /opt/comfyui-manager describe --tags --always
=> 4.0.5
```

(Requires `git config --global --add safe.directory /opt/comfyui-manager` first, because the
repo is owned by `comfyui-user` while `docker exec` runs as root — cosmetic, not a defect.)

## Step 5 — Seeded config (real v4 path `user/__manager/config.ini`)

```
docker exec comfyui-accept cat /opt/comfyui/user/__manager/config.ini
[default]
security_level = weak
network_mode = public
```

## Step 6 — Discovered Manager v4 API routes (active `glob` server)

```
/v2/manager/queue/task           (POST)  # unified queue; node-pack install = kind:"install"
/v2/manager/queue/install_model  (POST)  # arbitrary-URL model download
/v2/manager/queue/status         (GET)   # liveness probe for the manager API
```

Payload shapes (from `comfyui_manager/data_models/generated_models.py`):

- `queue/task`: `{ui_id, client_id, kind, params}` where `kind="install"` and
  `params = InstallPackParams{id, version, selected_version, mode, channel}`.
- `install_model`: `ModelMetadata{client_id, ui_id, name, type, url, filename, save_path}`.

## Step 7 — The two previously-failing calls

### As-built image (Manager NOT loaded) — routes absent

Sanity probe: `GET /v2/manager/queue/status` → **HTTP 404** (route not registered → Manager off).

```
node-install    POST /v2/manager/queue/task           -> HTTP 405   (body: "405: Method Not Allowed")
model-download  POST /v2/manager/queue/install_model  -> HTTP 405   (body: "405: Method Not Allowed")
```

These 405s are **not** the v3.x gating — they are aiohttp responding for paths that have no
registered handler because ComfyUI-Manager v4 failed to load (see Root cause).

### Diagnostic (Manager loaded the correct v4 way) — gating proven gone

Inside the same container: `pip install -e /opt/comfyui-manager` (installs the `comfyui_manager`
package so `import comfyui_manager` resolves), then launched a second instance
`python main.py --port 8189 --cpu --enable-manager`. Log showed `[START] ComfyUI-Manager`, and
`GET /v2/manager/queue/status` → **HTTP 200** (routes now live). Re-running the two calls:

```
node-install    POST :8189/v2/manager/queue/task           -> HTTP 200   (task queued)
model-download  POST :8189/v2/manager/queue/install_model  -> HTTP 200   (task queued)
```

Worker log contained `[START] Security scan` / `[DONE] Security scan` and **no**
"REQUIRE Manager v4+" / arbitrary-URL rejection. Interpretation:

- Node-pack install: **405 → 200**. The v3.x 405 gating is GONE.
- Arbitrary-URL model download: **500 → 200**. The v3.x 500 "REQUIRES Manager v4+" is GONE.

The Manager v4 code + `security_level=weak` config accept both operations. The gating removal
that this project set out to prove is real — it is only the image's activation of the Manager
that is broken.

---

## Root cause (image defects blocking Manager v4 activation)

ComfyUI v0.8.2 loads Manager v4 through a **native hook**, not as a legacy `custom_nodes` entry
(`main.py`: `if args.enable_manager: if importlib.util.find_spec("comfyui_manager"): import comfyui_manager`;
running from a `custom_nodes` source tree is explicitly rejected and sets `args.enable_manager = False`).
Manager v4's repo root has **no `__init__.py`** — its importable package is `comfyui_manager/`.

The image does neither of the two things v4 requires:

1. **Dockerfile (lines 33–35)** runs `pip install --requirement /opt/comfyui-manager/requirements.txt`
   — it installs the Manager's *dependencies* but never the `comfyui_manager` *package* itself, so
   `import comfyui_manager` fails (`ModuleNotFoundError`). Fix: `pip install /opt/comfyui-manager`.

2. **entrypoint.sh (lines 162–163 / 173–175)** launches `main.py` without `--enable-manager`, so the
   native hook is off even if the package were importable. Fix: add `--enable-manager`.

3. The v3-era symlink `custom_nodes/ComfyUI-Manager -> /opt/comfyui-manager` (entrypoint `link_manager`)
   is now obsolete/counterproductive: ComfyUI tries to import it as a legacy node, finds no root
   `__init__.py`, and logs `IMPORT FAILED`. With `--enable-manager`, Manager's own `should_be_disabled()`
   is designed to skip any `custom_nodes` dir named `*comfyui-manager*` anyway, so the symlink should be
   removed as part of the v4 wiring.

## Teardown

```
docker rm -f comfyui-accept   # done
```
