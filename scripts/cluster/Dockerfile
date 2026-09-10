# Base image
FROM nvcr.io/nvidia/pytorch:25.05-py3


# Maintainer
LABEL maintainer="Arash Sal Moslehian"

# Pre-configure tzdata package + install packages
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        dnsutils \
        dvipng \
        ffmpeg \
        fish \
        g++ \
        gcc \
        git \
        git-lfs \
        graphviz \
        htop \
        iproute2 \
        keychain \
        libcupti-dev \
        libcurl3-dev \
        libegl1 \
        libffi-dev \
        libfreetype6-dev \
        libgl1 \
        libgl1-mesa-dev \
        libgles2-mesa-dev \
        libglew-dev \
        libglfw3-dev \
        libjpeg-dev \
        libosmesa6-dev \
        libpng-dev \
        libsm6 \
        libssl-dev \
        libxcursor-dev \
        libxext-dev \
        libxi-dev \
        libxinerama-dev \
        libxrandr-dev \
        libxrender1 \
        libzmq3-dev \
        lmodern \
        locales \
        make \
        mesa-common-dev \
        mesa-vulkan-drivers \
        net-tools \
        openssh-client \
        openssh-server \
        patchelf \
        pigz \
        pkg-config \
        proot \
        rsync \
        screen \
        software-properties-common \
        sudo \
        swig \
        tmux \
        tzdata \
        unzip \
        vim \
        vulkan-tools \
        wget \
        zip \
        zlib1g-dev \
        zsh \
     && rm -rf /var/lib/apt/lists/*

# Set locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Image-wide environment variables. The runtime HOME is supplied by Run:ai.
ENV SHELL=/bin/bash
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV XLA_PYTHON_CLIENT_PREALLOCATE=false
ENV MUJOCO_GL=egl

# Install uv
COPY --from=ghcr.io/astral-sh/uv:0.11.0 /uv /uvx /bin/

# Copy entrypoint script
RUN mkdir -p /docker
COPY entrypoint.sh /docker/entrypoint.sh
RUN chmod +x /docker/entrypoint.sh

ENTRYPOINT ["/docker/entrypoint.sh"]

# Expose ports for SSH, notebook, and tensorboard workloads.
EXPOSE 2222 8888 6666
