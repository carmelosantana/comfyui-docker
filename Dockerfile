# syntax=docker/dockerfile:1

ARG PYTORCH_VERSION=2.9.1
ARG CUDA_VERSION=12.8
ARG CUDNN_VERSION=9

# ---------------------------------------------------------------------------
# base — the published default image (runtime; no compilers). Behavior-identical
# to the pre-multistage image; `--target base` builds it.
# ---------------------------------------------------------------------------
FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime AS base

# ComfyUI is pinned by a ref (tag like "v0.29.0" or a commit SHA); Manager is pinned by a tag (v4+).
ARG COMFYUI_REF=v0.33.1
ARG COMFYUI_MANAGER_VERSION=4.2.2

# Keep COMFYUI_VERSION as an alias so CI version-extraction and image labels stay stable.
ARG COMFYUI_VERSION=0.33.1

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

# Guard: the ComfyUI bump (0.29->0.33) is the API-drift risk. Fail the build if the core MiniMax
# Music 3 or ACE-Step audio node modules no longer import against the pinned ComfyUI.
RUN cd /opt/comfyui && python -c "import comfy_extras.nodes_minimax_music, comfy_extras.nodes_ace; print('core audio nodes import OK')"

# Guard: comfyui-ollama's deps (ollama client + dotenv) must be importable in the baked env.
RUN python -c "import ollama, dotenv; print('ollama', ollama.__version__)"

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
