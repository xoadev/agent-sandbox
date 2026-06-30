FROM agent-sandbox-opencode:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        shellcheck \
    && rm -rf /var/lib/apt/lists/*
