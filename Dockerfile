# syntax=docker/dockerfile:1

ARG PYTORCH_VERSION=2.9.1
ARG CUDA_VERSION=12.8
ARG CUDNN_VERSION=9

FROM pytorch/pytorch:${PYTORCH_VERSION}-cuda${CUDA_VERSION}-cudnn${CUDNN_VERSION}-runtime

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
