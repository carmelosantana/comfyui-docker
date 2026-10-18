# syntax=docker/dockerfile:1

ARG PYTORCH_VERSION=2.9.1
ARG CUDA_VERSION=13.0
ARG CUDNN_VERSION=9

# ---------------------------------------------------------------------------
# base — the published default image (runtime; no compilers). Behavior-identical
# to the pre-multistage image; `--target base` builds it.
# ---------------------------------------------------------------------------
FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime AS base

# ComfyUI is pinned by a ref (tag like "v0.29.0" or a commit SHA); Manager is pinned by a tag (v4+).
ARG COMFYUI_REF=v0.39.0
ARG COMFYUI_MANAGER_VERSION=4.2.2

# Keep COMFYUI_VERSION as an alias so CI version-extraction and image labels stay stable.
ARG COMFYUI_VERSION=0.39.0

# The base image's pip rejects pixeloe's platform_release marker on suffixed Linux
# kernels (e.g. GitHub's 6.17.0-1022-azure). Newer vendored packaging handles it.
ARG PIP_VERSION=26.2.1

RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends \
        git \
        sudo \
        curl \
        aria2 \
        espeak-ng \
        libgl1 \
        libgl1-mesa-glx \
        libglib2.0-0 \
        ffmpeg \
        build-essential \
        cmake \
        pkg-config \
        portaudio19-dev && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*

RUN git clone https://github.com/Comfy-Org/ComfyUI.git /opt/comfyui && \
    cd /opt/comfyui && \
    git checkout "${COMFYUI_REF}"

RUN git clone https://github.com/Comfy-Org/ComfyUI-Manager.git /opt/comfyui-manager && \
    cd /opt/comfyui-manager && \
    git checkout "${COMFYUI_MANAGER_VERSION}"

COPY tests/check_pip_markers.py /tmp/check_pip_markers.py
RUN python -m pip install --no-cache-dir "pip==${PIP_VERSION}" && \
    python /tmp/check_pip_markers.py && rm /tmp/check_pip_markers.py

RUN pip install \
    --requirement /opt/comfyui/requirements.txt \
    --requirement /opt/comfyui-manager/requirements.txt

# Install the ComfyUI-Manager v4 package itself so `import comfyui_manager` resolves and
# `main.py --enable-manager` can activate it via its native hook. The clone above stays as the
# version pin and MANAGER_SRC referenced by the entrypoint.
RUN pip install /opt/comfyui-manager

# Common heavy deps used by many video/vision node packs, baked so they survive a container
# recreate (the conda env is not a mount). Per-pack extras still install on boot via the
# entrypoint. opencv-python-headless (no GUI libs) provides cv2 for a headless server.
RUN pip install --no-cache-dir \
    accelerate \
    opencv-python-headless \
    transformers \
    deepdiff \
    ollama

# Additional common deps for the baked creator toolset (video/vision/audio packs + HF CLI).
RUN pip install --no-cache-dir \
    imageio-ffmpeg \
    onnxruntime \
    "huggingface_hub[cli]"

# --- Baked creator node packs -------------------------------------------------------------------
# Staged OUTSIDE custom_nodes (a runtime bind mount that would shadow them). The entrypoint seeds
# them into the live mount on boot. Pins resolved 2026-07-29 via `git ls-remote <repo> HEAD`.
ARG KJNODES_REF=827fe6ee0ed7348d8daa988ed852bedf1272380c
ARG FRAME_INTERP_REF=26545cc2dd95bc3d27f056016300673bdeee78f5
ARG ESSENTIALS_REF=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
ARG TTS_SUITE_REF=871c97fd9962fc7ffc2e0f6d9868bb5d5e6c5d46
ARG WANVIDEO_REF=088128b224242e110d3906c6750e9a3a348a659b
ARG VHS_REF=4ee72c065db22c9d96c2427954dc69e7b908444b
ARG HF_DOWNLOADER_REF=2bba5db6a52479e8ad465dbade19dd0da0784bd3
ARG OLLAMA_NODES_REF=6db7560576e5a59488708e6be13e07b5aba2432a

RUN mkdir -p /opt/comfyui-baked-nodes && cd /opt/comfyui-baked-nodes && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git ComfyUI-KJNodes && \
    git -C ComfyUI-KJNodes checkout "${KJNODES_REF}" && \
    git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git ComfyUI-Frame-Interpolation && \
    git -C ComfyUI-Frame-Interpolation checkout "${FRAME_INTERP_REF}" && \
    git clone https://github.com/cubiq/ComfyUI_essentials.git ComfyUI_essentials && \
    git -C ComfyUI_essentials checkout "${ESSENTIALS_REF}" && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git ComfyUI-WanVideoWrapper && \
    git -C ComfyUI-WanVideoWrapper checkout "${WANVIDEO_REF}" && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git ComfyUI-VideoHelperSuite && \
    git -C ComfyUI-VideoHelperSuite checkout "${VHS_REF}" && \
    git clone https://github.com/jnxmx/ComfyUI_HuggingFace_Downloader.git ComfyUI_HuggingFace_Downloader && \
    git -C ComfyUI_HuggingFace_Downloader checkout "${HF_DOWNLOADER_REF}" && \
    git clone https://github.com/diodiogod/TTS-Audio-Suite.git TTS-Audio-Suite && \
    git -C TTS-Audio-Suite checkout "${TTS_SUITE_REF}" && \
    git clone https://github.com/stavsap/comfyui-ollama.git comfyui-ollama && \
    git -C comfyui-ollama checkout "${OLLAMA_NODES_REF}"

# The video/helper/downloader packs install cleanly with plain pip (mostly wheels; several deps are
# already present from the heavy-deps layer above). Frame-Interpolation uses the no-cupy requirements
# (RIFE works without cupy; cupy-wheel pulls a heavy CUDA runtime).
RUN pip install --no-cache-dir \
        -r /opt/comfyui-baked-nodes/ComfyUI-KJNodes/requirements.txt \
        -r /opt/comfyui-baked-nodes/ComfyUI_essentials/requirements.txt \
        -r /opt/comfyui-baked-nodes/ComfyUI-Frame-Interpolation/requirements-no-cupy.txt \
        -r /opt/comfyui-baked-nodes/ComfyUI-WanVideoWrapper/requirements.txt \
        -r /opt/comfyui-baked-nodes/ComfyUI-VideoHelperSuite/requirements.txt \
        -r /opt/comfyui-baked-nodes/ComfyUI_HuggingFace_Downloader/requirements.txt \
        -r /opt/comfyui-baked-nodes/comfyui-ollama/requirements.txt

# TTS-Audio-Suite's requirements.txt explicitly defers to install.py for conflict resolution
# (--no-deps installs, numpy/opencv pinning, engine bundling). Install the safe requirements first,
# then run install.py to bake the full engine dep set (ChatterBox/F5/Higgs/IndexTTS-2/CosyVoice3/RVC).
RUN pip install --no-cache-dir -r /opt/comfyui-baked-nodes/TTS-Audio-Suite/requirements.txt
RUN cd /opt/comfyui-baked-nodes/TTS-Audio-Suite && python install.py

# Guard: TTS install.py reshapes shared deps (numpy/opencv/etc). Fail the build if it broke torch.
RUN python -c "import torch, torchaudio; print('torch', torch.__version__, 'torchaudio', torchaudio.__version__)"

# Pin onnx to stop a protobuf gencode<->runtime skew. onnx and protobuf are both unpinned
# transitives (onnx arrives via s3tokenizer, pulled by TTS ChatterBox's install.py), so each
# rebuild resolves them independently. One unlucky pairing shipped onnx 1.18 (protobuf gencode
# 6.31.1) against a protobuf runtime held back to 5.29.6, so `import onnx` raised VersionError.
# TTS's UnifiedTTSTextNode swallows that and returns a SILENT track (job "succeeds" with no
# speech); WanVideoWrapper FantasyPortrait and comfyui-rmbg hit the same error at boot. Pin onnx
# to a current release whose generated code carries no runtime-version guard, so it imports
# against whatever protobuf resolves to and the skew cannot recur. The import guard below IS the
# acceptance test, enforced at build time (fails the build on any regression).
RUN pip install --no-cache-dir "onnx==1.22.0" && \
    python -c "import onnx, onnx.onnx_ml_pb2, s3tokenizer; print('onnx', onnx.__version__)"

# Guard: comfyui-ollama's deps (ollama client + dotenv) must be importable in the baked env.
RUN python -c "import ollama, dotenv; print('comfyui-ollama deps import OK')"

# Texture tiling packs (seamless/tileable textures). No Python deps (AdvancedTiling's optional `ray`
# import is guarded), so their own layer leaves the heavy dep layers above cached. Staged under the
# dir names Manager installs to (cnr id / repo name) so an existing Manager install is recognised.
# Pins vetted 2026-10-05 (no subprocess/network/eval/pickle); re-vet if either changes.
ARG ADVANCED_TILING_REF=3c35bc90400ae53f7e15a15295ffdf1fbeae17cf
ARG SEAMLESS_TILES_REF=c10836d91f4141d9f69cdd6ed53e40fddd71a869
RUN cd /opt/comfyui-baked-nodes && \
    git clone https://github.com/JosefKuchar/ComfyUI-AdvancedTiling.git comfyui-advanced-tiling && \
    git -C comfyui-advanced-tiling checkout "${ADVANCED_TILING_REF}" && \
    git clone https://github.com/OliverCrosby/ComfyUI-Universal-Seamless-Tiles.git ComfyUI-Universal-Seamless-Tiles && \
    git -C ComfyUI-Universal-Seamless-Tiles checkout "${SEAMLESS_TILES_REF}"

# NOTE: the core MiniMax-Music3 / ACE-Step node modules ship *inside* ComfyUI at this pinned
# commit (release-locked to the core they run against), so they need no separate build-time import
# guard. Importing them here would also FAIL a driverless build (CI included): comfy_extras
# imports comfy.model_management, which eagerly calls torch.cuda.current_device() at import and
# raises "Found no NVIDIA driver". They are verified at boot instead (main.py --cpu registers them;
# the smoke test queries /object_info for MiniMaxMusic3TextEncode / EmptyMiniMaxMusic3LatentAudio).

# Pre-seed on-boot node-dep markers for the baked packs so the entrypoint's install loop treats
# them as already-satisfied (deps are in the image) and does not reinstall on every boot/recreate.
COPY source/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    BAKED_NODES_DIR=/opt/comfyui-baked-nodes \
    NODE_DEPS_STATE_DIR=/opt/comfyui/.node-deps-state \
    bash -c 'source /entrypoint.sh && write_baked_node_markers' && \
    ls -1 /opt/comfyui/.node-deps-state

# Default Manager config, seeded by the entrypoint only when the user has none.
COPY source/manager-config.ini /opt/comfyui-manager-config.ini

# Lazy-download caches point into the models bind mount so first-use weights survive recreate
# (§4 decision: lean image, no baked weights). The entrypoint creates + chowns these on boot.
# huggingface_hub derives HF_HUB_CACHE from HF_HOME automatically, so it is left unset here --
# setting it explicitly would diverge from HF_HOME whenever a user overrides HF_HOME.
ENV HF_HOME=/opt/comfyui/models/.cache/huggingface \
    TORCH_HOME=/opt/comfyui/models/.cache/torch

WORKDIR /opt/comfyui

EXPOSE 8188

# Healthcheck lets Portainer show real health and enables depends_on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
    CMD curl --fail --silent http://localhost:8188/ >/dev/null || exit 1

COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

# ---------------------------------------------------------------------------
# sage-build — compile the SageAttention wheel in the matching devel twin.
# Same torch/python/CUDA ABI as base, plus nvcc + headers. No GPU needed:
# TORCH_CUDA_ARCH_LIST cross-compiles for sm_86.
# ---------------------------------------------------------------------------
FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-devel AS sage-build

# Pin: never `main`. Resolved via `git ls-remote thu-ml/SageAttention` at build-plan time.
# eb615cf = tag v2.2.0 (newest 2.x tag).
ARG SAGEATTENTION_REF=eb615cf6cf4d221338033340ee2de1c37fbdba4a
ARG TRITON_VERSION=3.5.1
ARG SAGE_CUDA_ARCH=8.6

RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends \
        git \
        build-essential \
        ninja-build && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "triton==${TRITON_VERSION}" build

RUN git clone https://github.com/thu-ml/SageAttention.git /src/SageAttention && \
    cd /src/SageAttention && \
    git checkout "${SAGEATTENTION_REF}"

WORKDIR /src/SageAttention
ENV TORCH_CUDA_ARCH_LIST=${SAGE_CUDA_ARCH} \
    MAX_JOBS=4 \
    EXT_PARALLEL=4 \
    NVCC_APPEND_FLAGS="--threads 8"
# SageAttention v2.2.0 pins its build backend in pyproject (setuptools<75, wheel<0.44,
# packaging<24). The -devel conda env ships newer ones, and `build --no-isolation` enforces
# those pins (it fails with "Missing dependencies" before compiling). Install matching versions
# so the check passes — we must keep --no-isolation because the build imports the image's torch
# to detect CUDA, which an isolated build env would not have.
RUN pip install --no-cache-dir "setuptools>=62,<75" "wheel>=0.38,<0.44" "packaging>=21,<24"
RUN python -m build --wheel --no-isolation --outdir /wheels

# ---------------------------------------------------------------------------
# sage — base + the compiled wheel; sage on by default (overridable to 0).
# ---------------------------------------------------------------------------
FROM base AS sage

ARG TRITON_VERSION=3.5.1

COPY --from=sage-build /wheels/*.whl /tmp/wheels/
RUN pip install --no-cache-dir "triton==${TRITON_VERSION}" /tmp/wheels/*.whl && \
    rm -rf /tmp/wheels

# Guard: confirm the baked-toolset dep changes did not break sageattention import in the sage image.
RUN python -c "import torch, sageattention; print('sage ok on torch', torch.__version__)"

# Swap-and-go: the -sage tag runs with sage attention on. Set to 0 to A/B without a rebuild.
ENV USE_SAGE_ATTENTION=1

# ---------------------------------------------------------------------------
# d3d-build — compile Direct3D-S2's CUDA pieces in the devel twin, against the image's own torch
# (no flash-attn wheel exists for torch 2.9). No GPU needed: everything cross-compiles for the
# 3090. flash-attn's sm_80 kernels run on sm_86, so only sm_80 is built. torchsparse builds for sm_86.
# ---------------------------------------------------------------------------
FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-devel AS d3d-build

# Pins resolved 2026-10-17. flash-attn 2.8.3.post2 is skipped: published 2026-10-14 (too new).
ARG FLASH_ATTN_VERSION=2.8.3.post1
ARG DIRECT3D_S2_REF=a1cf235b2881cff04a91900060a9546b40e7ee5d
ARG D3D_CUDA_ARCH=8.6
# flash-attn needs several GB of RAM per compile job; raise on a bigger build host.
ARG D3D_MAX_JOBS=2

RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends git build-essential ninja-build && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ninja packaging psutil einops wheel

ENV TORCH_CUDA_ARCH_LIST=${D3D_CUDA_ARCH} \
    FLASH_ATTN_CUDA_ARCHS=80 \
    FLASH_ATTENTION_FORCE_BUILD=TRUE \
    MAX_JOBS=${D3D_MAX_JOBS} \
    NVCC_THREADS=2

RUN pip wheel --no-cache-dir --no-build-isolation --no-deps "flash-attn==${FLASH_ATTN_VERSION}" -w /wheels

RUN git clone https://github.com/DreamTechAI/Direct3D-S2.git /src/Direct3D-S2 && \
    git -C /src/Direct3D-S2 checkout "${DIRECT3D_S2_REF}" && \
    pip wheel --no-cache-dir --no-build-isolation --no-deps /src/Direct3D-S2/third_party/voxelize -w /wheels

# torchsparse (MIT), the sparse conv backend the published checkpoints were saved with (their keys
# are "conv.kernel"; spconv's are "conv.weight"). No release wheel exists for torch 2.9 / CUDA 13, so
# build the pinned commit (2025-02-24). There is no GPU during `docker build`: without FORCE_CUDA=1
# setup.py silently builds a CPU-only backend and inference fails later. Its unused `import rootpath`
# and the rootpath/backports.cached_property requirements are dropped (neither is used on Python 3.11),
# so they and the test tooling rootpath pulls in never ship; the wheel installs with --no-deps in mesh3d. libsparsehash-dev (BSD, headers only) stays in this stage.
ARG TORCHSPARSE_REF=385f5ce8718fcae93540511b7f5832f4e71fd835
RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends libsparsehash-dev && \
    rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/mit-han-lab/torchsparse.git /src/torchsparse && \
    git -C /src/torchsparse checkout "${TORCHSPARSE_REF}" && \
    sed -i '/^import rootpath$/d' /src/torchsparse/torchsparse/nn/functional/conv/utils/collections.py \
        /src/torchsparse/torchsparse/nn/functional/conv/utils/compat.py && \
    sed -i '/"backports.cached_property",/d; /"rootpath",/d' /src/torchsparse/setup.py && \
    ! grep -rn rootpath /src/torchsparse/torchsparse /src/torchsparse/setup.py && \
    FORCE_CUDA=1 pip wheel --no-cache-dir --no-build-isolation --no-deps /src/torchsparse -w /wheels

# ---------------------------------------------------------------------------
# mesh3d — base + Direct3D-S2 (published as the -3d tags). Built from base, not sage, and runs
# with sage attention off. Every package already in base is held at its version (constraints),
# so the 3D deps cannot move torch, numpy or anything the other baked packs rely on.
# Licences: only permissive code ships (MIT/BSD/Apache). Upstream's optional remesh step needs
# nvdiffrast (research-only) and pymeshfix/igraph (GPL), so it is cut out and they are not installed.
# ---------------------------------------------------------------------------
FROM base AS mesh3d

ARG DIRECT3D_S2_REF=a1cf235b2881cff04a91900060a9546b40e7ee5d

# diffusers, einops, omegaconf and scikit-image already come with base (its versions win); the
# import guard below fails the build if base ever stops providing them.
COPY --from=d3d-build /wheels/*.whl /tmp/wheels/
RUN pip list --format=freeze > /tmp/constraints.txt && \
    pip install --no-cache-dir --no-deps /tmp/wheels/torchsparse-*.whl && \
    rm /tmp/wheels/torchsparse-*.whl && \
    pip install --no-cache-dir --constraint /tmp/constraints.txt \
        /tmp/wheels/*.whl \
        "trimesh==5.1.1" && \
    rm -rf /tmp/wheels /tmp/constraints.txt

# torchsparse reads the GPU's compute capability at import (backends.init), so it cannot be imported
# without a GPU: not in this build, in CI, or on a --cpu boot. With no CUDA device, fall back to sm_86
# (the build target); with one, the real capability is used as before.
# Guard: the torchsparse backend must carry its CUDA kernels (a CPU-only build imports fine and only
# fails at inference). pybind stores each bound name as a string in the .so. find_spec on the top-level
# package locates it without running its __init__.
RUN ts="$(python -c 'import importlib.util as u, os; print(os.path.dirname(u.find_spec("torchsparse").origin))')" && \
    sed -i 's/^    device_capability = torch.cuda.get_device_capability()$/    device_capability = torch.cuda.get_device_capability() if torch.cuda.is_available() else (8, 6)  # comfyui-docker: importable without a GPU/' \
        "$ts/backends.py" && \
    grep -q "comfyui-docker: importable without a GPU" "$ts/backends.py" && \
    grep -q build_kernel_map_subm_hashmap "$ts"/backend*.so && echo "torchsparse CUDA backend OK:" "$ts"/backend*.so

# Upstream has no installable package (no direct3d_s2/__init__.py), so put the pinned checkout on
# sys.path with a .pth file. Drop the eager remesh import (fill_hole -> utils3d/nvdiffrast,
# pymeshfix, igraph); the pipeline only reaches it when remesh=True, which the nodes never pass.
RUN git clone https://github.com/DreamTechAI/Direct3D-S2.git /opt/direct3d-s2 && \
    git -C /opt/direct3d-s2 checkout "${DIRECT3D_S2_REF}" && \
    sed -i '/^from \.fill_hole import postprocess_mesh$/d' /opt/direct3d-s2/direct3d_s2/utils/__init__.py && \
    ! grep -q fill_hole /opt/direct3d-s2/direct3d_s2/utils/__init__.py && \
    echo /opt/direct3d-s2 > "$(python -c 'import site; print(site.getsitepackages()[0])')/direct3d-s2.pth"

COPY nodes/ComfyUI-Direct3D-S2 /opt/comfyui-baked-nodes/ComfyUI-Direct3D-S2

# Guards: the Direct3D-S2 import chain resolves without a GPU on the torchsparse backend; no blocked
# package is installed; every upstream torch.load stays weights_only=True (the .ckpt files are pickles).
RUN SPARSE_BACKEND=torchsparse python -c "import flash_attn, udf_ext, torchsparse, \
    direct3d_s2.pipeline, torch; print('direct3d-s2 OK on torch', torch.__version__, \
    'flash-attn', flash_attn.__version__, 'torchsparse', torchsparse.__version__)" && \
    ! pip list --format=freeze | grep -iE '^(nvdiffrast|pymeshfix|igraph|python-igraph|utils3d)==' && \
    ! grep -rn "torch.load(" /opt/direct3d-s2/direct3d_s2 | grep -v "weights_only=True"

ENV USE_SAGE_ATTENTION=0
