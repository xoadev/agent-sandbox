ARG DEBIAN_TAG=trixie-slim
ARG OPENCODE_VERSION=1.17.11
ARG DOCKER_VERSION=29.6.0
ARG DOCKER_ARCH=x86_64
ARG COMPOSE_VERSION=5.2.0
ARG COMPOSE_ARCH=linux-x86_64
ARG GH_VERSION=2.95.0
ARG GH_ARCH=linux_amd64
ARG PNPM_VERSION=11.9.0

FROM debian:${DEBIAN_TAG}

ARG OPENCODE_VERSION
ARG DOCKER_VERSION
ARG DOCKER_ARCH
ARG COMPOSE_VERSION
ARG COMPOSE_ARCH
ARG GH_VERSION
ARG GH_ARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        bash \
        tar \
        make \
        jq \
        unzip \
        libatomic1 \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (static build)
RUN curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_VERSION}.tgz" \
        -o /tmp/docker.tgz \
    && tar -xzf /tmp/docker.tgz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker /tmp/docker.tgz

# Docker Compose plugin (v2)
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-${COMPOSE_ARCH}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ENV DOCKER_CLI_PLUGINS=/usr/local/lib/docker/cli-plugins

# GitHub CLI (gh)
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_${GH_ARCH}.tar.gz" \
        -o /tmp/gh.tgz \
    && tar -xzf /tmp/gh.tgz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_${GH_ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VERSION}_${GH_ARCH}" /tmp/gh.tgz

# Install pnpm
ENV PNPM_HOME=/root/.local/share/pnpm
RUN curl -fsSLs https://get.pnpm.io/install.sh | env PNPM_VERSION="${PNPM_VERSION}" SHELL="bash" PNPM_HOME="${PNPM_HOME}" bash
ENV PATH=$PNPM_HOME/bin:$PATH

# pnpm alias (the v11 shim at $PNPM_HOME/bin/pnpm works via PATH)
RUN ln -s "$PNPM_HOME/bin/pnpm" /usr/local/bin/pnpm

# npm alias → wrapper that calls the pnpm shim (avoids v11 relative-path bug with symlinks)
RUN printf '#!/bin/bash\nexec "${PNPM_HOME}/bin/pnpm" "$@"\n' > /usr/local/bin/npm \
    && chmod +x /usr/local/bin/npm

# opencode CLI
RUN curl -fsSL https://opencode.ai/install \
    | bash -s -- --version ${OPENCODE_VERSION} --no-modify-path

# Install Ponytail
RUN git clone --depth 1 https://github.com/DietrichGebert/ponytail /opt/ponytail
RUN mkdir -p /root/.config/opencode
COPY opencode.json /root/.config/opencode/opencode.json

# Agent skills: list available tools as discoverable SKILL.md files
COPY skills/ /root/.config/opencode/skills/

WORKDIR /workspace
CMD ["/root/.opencode/bin/opencode"]
