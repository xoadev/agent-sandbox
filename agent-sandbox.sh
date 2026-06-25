#!/usr/bin/env bash

# CLI agent-sandbox: Secure execution and isolation for AI agents
set -euo pipefail

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

GLOBAL_DIR="${GLOBAL_DIR:-${HOME:-$(cd ~ && pwd)}/.agent-sandbox}"
SANDBOX_MOUNT="/workspace"

# Show CLI Help Menu
show_help() {
    echo -e "${BLUE}Usage:${NC} agent-sandbox [command|environment]"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  init              Initialize an environment configuration in the current directory (.agent-sandbox/dev.json)"
    echo "  [environment]     Spin up the specified sandbox environment (e.g. 'dev') and drop into an interactive shell"
    echo "  help              Show this help screen"
    echo ""
    echo -e "${BLUE}Example:${NC}"
    echo "  agent-sandbox init"
    echo "  agent-sandbox dev"
}

# Print an error and exit non-zero
die() {
    echo -e "${RED}❌ Error: $*${NC}" >&2
    exit 1
}

# Initialization Command
cmd_init() {
    local LOCAL_DIR="./.agent-sandbox"
    if [ -d "$LOCAL_DIR" ]; then
        die "the folder '$LOCAL_DIR' already exists in this project."
    fi

    mkdir -p "$LOCAL_DIR"
    cat <<'EOF' >"$LOCAL_DIR/dev.json"
{
  "image": "xoadev/opencode-sandbox-image:latest",
  "vault": [
    {
      "match": { "host": "api.github.com" },
      "inject": { "headers": { "Authorization": "Bearer {{secrets.github}}" } }
    },
    {
      "match": { "host": "api.anthropic.com" },
      "inject": { "headers": { "x-api-key": "{{secrets.anthropic}}" } }
    }
  ]
}
EOF
    echo -e "${GREEN}✔ Environment initialized successfully at '$LOCAL_DIR/dev.json'.${NC}"
    echo -e "Adjust your workspace rules, then run 'agent-sandbox dev' to start."
}

# Resolve the 'image' field from a JSON config file.
# Accepts either a registry image name, or a local path to a Dockerfile
# (prefixed with './' or '/', or ending in 'Dockerfile'). When a Dockerfile is
# detected the image is built and tagged as 'agent-sandbox-<env>:latest'.
#
# Globals read:
#   ENV_NAME       target environment name (used for the produced tag)
# Globals set:
#   RESOLVED_IMAGE the image reference to use in docker-compose
# Globals used for output only:
#   BUILT_IMAGE    non-empty when an image was freshly built
#
# Args:
#   $1  raw 'image' value from dev.json
resolve_image() {
    local image_value="$1"
    RESOLVED_IMAGE=""
    BUILT_IMAGE=""

    # Dockerfile path detection: starts with './' or '/', or ends in 'Dockerfile'
    if [[ $image_value == ./* ]] || [[ $image_value == /* ]] || [[ $image_value == *Dockerfile ]]; then
        local dockerfile_path="${image_value}"
        local context_dir

        if [[ -d $dockerfile_path ]]; then
            # Directory: context is the directory, Dockerfile is implicit
            context_dir="$dockerfile_path"
            dockerfile_path="${dockerfile_path%/}/Dockerfile"
        else
            # File path: context is its parent directory
            context_dir="$(dirname "$dockerfile_path")"
        fi

        if [ ! -f "$dockerfile_path" ]; then
            die "image points to a Dockerfile but no file found at: $dockerfile_path"
        fi

        BUILT_IMAGE="agent-sandbox-${ENV_NAME}:latest"
        echo -e "🔨 Building image from ${BLUE}${dockerfile_path}${NC}..."
        docker build -f "$dockerfile_path" -t "$BUILT_IMAGE" "$context_dir"
        RESOLVED_IMAGE="$BUILT_IMAGE"
    else
        RESOLVED_IMAGE="$image_value"
    fi
}

# Compile Agent Vault configuration by reading dev.json, parsing secrets.env
# and substituting every "{{secrets.<key>}}" placeholder with the matching
# secret value. The result is written to $1 as a JSON agent-vault config file.
#
# secrets.env is expected to contain simple `key=value` assignments, one per
# line. Lines starting with '#' or empty lines are ignored. Values may contain
# any characters except a trailing newline (no quote handling is performed).
#
# Args:
#   $1  output path for vault-config.json
#   $2  path to dev.json (local environment config)
#   $3  path to secrets.env (global secrets)
compile_vault_config() {
    local out_path="$1"
    local dev_json="$2"
    local secrets_env="$3"
    local content vault_block line secret_key secret_val

    [ -f "$dev_json" ] || die "environment config not found at: $dev_json"
    [ -f "$secrets_env" ] || die "global secrets file not found at: $secrets_env"

    content="$(cat "$dev_json")"

    # Parse secrets.env line by line and substitute placeholders
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines and comments
        case "$line" in '' | \#*) continue ;; esac
        secret_key="${line%%=*}"
        secret_val="${line#*=}"
        [ -n "$secret_key" ] || continue
        content="${content//\{\{secrets.${secret_key}\}\}/${secret_val}}"
    done <"$secrets_env"

    vault_block="$(extract_vault_array "$content")"

    cat >"$out_path" <<EOF
{
  "vaults": {
    "local-sandbox-vault": {
      "credentials": {},
      "rules": [${vault_block}]
    }
  }
}
EOF
}

# Extract the inner contents of the top-level "vault" array from a JSON string.
# Locates `"vault"` followed by the first '[' and walks the bracket depth to
# capture the array body (without the enclosing brackets).
#
# Args:
#   $1  JSON content as a string
# Prints: the contents of the vault array (without enclosing brackets),
#         or an empty string when the "vault" key is absent.
extract_vault_array() {
    local json="$1"
    local len=${#json}
    local head rest bracket_in_rest vault_idx start depth i ch out=""

    # Locate the position of "vault"
    head="${json%%\"vault\"*}"
    [ "$head" = "$json" ] && {
        printf '%s' "$out"
        return
    }
    vault_idx=${#head}
    rest="${json:vault_idx}"
    # First '[' after the "vault" key
    bracket_in_rest="${rest%%\[*}"
    [ "$bracket_in_rest" = "$rest" ] && {
        printf '%s' "$out"
        return
    }
    start=$((vault_idx + ${#bracket_in_rest} + 1))
    depth=1

    for ((i = start; i < len; i++)); do
        ch="${json:i:1}"
        case "$ch" in
            '[')
                depth=$((depth + 1))
                out+="$ch"
                ;;
            ']')
                depth=$((depth - 1))
                if [ "$depth" -eq 0 ]; then
                    break
                fi
                out+="$ch"
                ;;
            *) out+="$ch" ;;
        esac
    done

    printf '%s' "$out"
}

# Launch Sandbox Command
cmd_start_sandbox() {
    ENV_NAME="$1"
    local LOCAL_CFG="./.agent-sandbox/${ENV_NAME}.json"
    local GLOBAL_SECRETS="$GLOBAL_DIR/secrets.env"

    [ -f "$LOCAL_CFG" ] || die "environment configuration not found at: $LOCAL_CFG
Run 'agent-sandbox init' to generate a default configuration."
    [ -f "$GLOBAL_SECRETS" ] || die "global secrets file '$GLOBAL_SECRETS' is missing.
Run the installer or create it manually with your secret assignments."

    echo -e "🚀 Preparing secure sandbox for environment: ${BLUE}${ENV_NAME}${NC}..."

    # 1. Secure temporary directory for dynamic assets
    TMP_DIR="$(mktemp -d -t agent-sandbox-XXXXXXXX)"
    chmod 700 "$TMP_DIR"

    # Generate random key for Agent Vault AES-GCM database in memory
    VAULT_KEY="$(openssl rand -hex 16)"

    # 2. Compile vault configuration
    compile_vault_config "$TMP_DIR/vault-config.json" "$LOCAL_CFG" "$GLOBAL_SECRETS"

    # Extract the image field with a pure-bash regex
    local RAW_IMAGE
    RAW_IMAGE="$(grep -oE '"image"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOCAL_CFG" | sed -E 's/^.*"([^"]*)"$/\1/')"
    [ -n "$RAW_IMAGE" ] || RAW_IMAGE="xoadev/opencode-sandbox-image:latest"

    resolve_image "$RAW_IMAGE"
    local IMAGE="$RESOLVED_IMAGE"

    # Allow tests to stop after compilation without invoking Docker
    if [ "${SANDBOX_SKIP_DOCKER:-0}" = "1" ]; then
        return 0
    fi

    local CURRENT_DIR
    CURRENT_DIR="$(pwd)"

    # 3. Isolated temporary docker-compose.yml
    cat <<EOF >"$TMP_DIR/docker-compose.yml"
services:
  agent-vault:
    image: infisical/agent-vault:latest
    container_name: sandbox-vault-${ENV_NAME}
    tty: true
    stdin_open: true
    volumes:
      - ${TMP_DIR}/vault-config.json:/etc/agent-vault/config.json:ro
    environment:
      - INFISICAL_ENCRYPTION_KEY=${VAULT_KEY}
    networks:
      - secure-net
    restart: "no"

  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: sandbox-docker-proxy-${ENV_NAME}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=0
    networks:
      - secure-net
    restart: "no"

  agent-sandbox:
    image: ${IMAGE}
    container_name: sandbox-execution-${ENV_NAME}
    runtime: runsc
    depends_on:
      - agent-vault
      - docker-proxy
    environment:
      - http_proxy=http://agent-vault:14322
      - https_proxy=http://agent-vault:14322
      - HTTP_PROXY=http://agent-vault:14322
      - HTTPS_PROXY=http://agent-vault:14322
      - DOCKER_HOST=tcp://docker-proxy:2375
      - GITHUB_TOKEN=dummy_github_token
    volumes:
      - ${CURRENT_DIR}:${SANDBOX_MOUNT}
    networks:
      - secure-net
    restart: "no"

networks:
  secure-net:
    name: secure-net-${ENV_NAME}
EOF

    # 4. Cleanup trap
    cleanup() {
        echo -e "\n${BLUE}🧹 Destroying ephemeral development sandbox...${NC}"
        docker compose -f "$TMP_DIR/docker-compose.yml" down -v --remove-orphans &>/dev/null || true
        rm -rf "$TMP_DIR"
        echo -e "${GREEN}✔ Environment cleared successfully. Host system secured.${NC}"
    }
    trap cleanup EXIT INT TERM

    # 5. Bring up Docker infrastructure
    echo -e "🧱 Spin up network architecture..."
    docker compose -f "$TMP_DIR/docker-compose.yml" up -d

    echo -e "${GREEN}✔ Containers started.${NC}"
    echo -e "🔗 gVisor active. Agent-Vault proxying credentials."
    echo -e "👉 ${GREEN}Entering Sandbox shell. Type 'exit' to cleanly close and destroy the workspace.${NC}\n"

    # 6. Drop user into the isolated agent container interactively
    docker exec -it "sandbox-execution-${ENV_NAME}" /bin/bash ||
        docker exec -it "sandbox-execution-${ENV_NAME}" /bin/sh ||
        true
}

# Main Command Router (only when executed, not when sourced for tests)
if [[ ${BASH_SOURCE[0]:-$0} == "${0}" ]]; then
    case "${1:-help}" in
        "" | "help" | "-h" | "--help")
            show_help
            ;;
        "init")
            cmd_init
            ;;
        *)
            cmd_start_sandbox "$1"
            ;;
    esac
fi
