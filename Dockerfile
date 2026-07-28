# syntax=docker/dockerfile:1

ARG PYTORCH_VERSION=2.9.1
ARG CUDA_VERSION=12.8
ARG CUDNN_VERSION=9

# ---------------------------------------------------------------------------
# base — the published default image (runtime; no compilers). Behavior-identical
# to the pre-multistage image; `--target base` builds it.
# ---------------------------------------------------------------------------
FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime AS base

# ComfyUI is pinned by a ref (tag like "v0.8.2" or a commit SHA); Manager is pinned by a tag (v4+).
ARG COMFYUI_REF=v0.8.2
ARG COMFYUI_MANAGER_VERSION=4.0.5

# Keep COMFYUI_VERSION as an alias so CI version-extraction and image labels stay stable.
ARG COMFYUI_VERSION=0.8.2

RUN apt-get update --assume-yes && \
    apt-get install --assume-yes --no-install-recommends \
        git \
        sudo \
        curl \
        libgl1-mesa-glx \
        libglib2.0-0 && \
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

# Default Manager config, seeded by the entrypoint only when the user has none.
COPY source/manager-config.ini /opt/comfyui-manager-config.ini

WORKDIR /opt/comfyui

EXPOSE 8188

# Healthcheck lets Portainer show real health and enables depends_on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
    CMD curl --fail --silent http://localhost:8188/ >/dev/null || exit 1

COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

COPY source/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
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

# Swap-and-go: the -sage tag runs with sage attention on. Set to 0 to A/B without a rebuild.
ENV USE_SAGE_ATTENTION=1
