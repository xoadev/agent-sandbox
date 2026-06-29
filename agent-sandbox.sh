#!/usr/bin/env bash

# CLI agent-sandbox: Secure execution and isolation for AI agents
set -euo pipefail

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

readonly SANDBOX_MOUNT="/workspace"

# Show CLI Help Menu
show_help() {
    echo -e "${BLUE}Usage:${NC} agent-sandbox <command>"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  init <env>        Initialize an environment configuration in the current directory (.agent-sandbox/[env].env and .agent-sandbox/[env].secret.env)"
    echo "  run <env>         Spin up the specified sandbox environment (e.g. 'opencode') and drop into an interactive shell"
    echo "  ps                List running sandbox sessions"
    echo "  help              Show this help screen"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  agent-sandbox init opencode"
    echo "  agent-sandbox run opencode"
}

# Print an error and exit non-zero
die() {
    echo -e "${RED}❌ Error: $*${NC}" >&2
    exit 1
}

urlencode() {
    local s="$1" i c
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) printf '%s' "$c" ;;
            *) printf '%%%02x' "'$c" ;;
        esac
    done
}

# Initialization Command
cmd_init() {
    local LOCAL_DIR="./.agent-sandbox"
    local ENVIRONMENT="$1"
    [ -n "$ENVIRONMENT" ] || die "Missing environment name.\nUsage: agent-sandbox init <environment>\nExample: agent-sandbox init opencode"

    mkdir -p "$LOCAL_DIR"

    echo -e "${BLUE}Configuring environment '${ENVIRONMENT}'.${NC}"
    echo ""

    local VAULT_ADDR VAULT_TOKEN VAULT_VAULT

    read -rp "Vault address [localhost:14321]: " VAULT_ADDR
    VAULT_ADDR="${VAULT_ADDR:-localhost:14321}"

    read -rsp "Vault token: " VAULT_TOKEN
    echo
    [ -n "$VAULT_TOKEN" ] || die "Vault token cannot be empty"

    read -rp "Vault name [default]: " VAULT_VAULT
    VAULT_VAULT="${VAULT_VAULT:-default}"

    cat >"$LOCAL_DIR/$ENVIRONMENT.env" <<EOF
AGENT_SANDBOX_IMAGE="agent-sandbox-opencode:latest"
AGENT_VAULT_ADDR="${VAULT_ADDR}"
AGENT_VAULT_VAULT="${VAULT_VAULT}"
EOF

    cat >"$LOCAL_DIR/$ENVIRONMENT.secret.env" <<EOF
AGENT_VAULT_TOKEN="${VAULT_TOKEN}"
EOF

    echo -e "${GREEN}✔ Environment '$ENVIRONMENT' initialized at '$LOCAL_DIR/$ENVIRONMENT.env'.${NC}"
    echo -e "Run 'agent-sandbox $ENVIRONMENT' to start."
}

# Resolve the 'image' field from an environment config file.
# Registry name → use as-is. Path starting with ./ or /, or ending in Dockerfile → build.
resolve_image() {
    local image_value="$1" env_name="$2"

    if [[ $image_value == ./* ]] || [[ $image_value == /* ]] || [[ $image_value == *Dockerfile ]]; then
        local dockerfile_path="${image_value}"
        local context_dir

        if [[ -d $dockerfile_path ]]; then
            context_dir="$dockerfile_path"
            dockerfile_path="${dockerfile_path%/}/Dockerfile"
        else
            context_dir="$(dirname "$dockerfile_path")"
        fi

        if [ ! -f "$dockerfile_path" ]; then
            die "image points to a Dockerfile but no file found at: $dockerfile_path"
        fi

        local built_image="agent-sandbox-${env_name}:latest"
        echo -e "🔨 Building image from ${BLUE}${dockerfile_path}${NC}..."
        docker build -f "$dockerfile_path" -t "$built_image" "$context_dir"
        printf '%s' "$built_image"
    else
        printf '%s' "$image_value"
    fi
}

# Launch Sandbox Command
cmd_start_sandbox() {
    TMP_DIR=""
    trap - EXIT
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid environment name '$1'. Use only letters, numbers, hyphens, and underscores."
    ENV_NAME="$1"
    local LOCAL_CFG="./.agent-sandbox/${ENV_NAME}.env"
    local SECRETS="./.agent-sandbox/${ENV_NAME}.secret.env"

    if [ ! -f "$LOCAL_CFG" ]; then
        echo -e "${BLUE}⚠️  Configuration not found at '$LOCAL_CFG'.${NC}"
        echo -n "Run 'agent-sandbox init ${ENV_NAME}' now? [Y/n] "
        read -r reply
        if [[ $reply =~ ^[Nn] ]]; then
            die "Run 'agent-sandbox init $ENV_NAME' first."
        fi
        cmd_init "$ENV_NAME"
    fi
    [ -f "$SECRETS" ] || die "secrets file '$SECRETS' is missing. Re-run 'agent-sandbox init $ENV_NAME' to regenerate it."

    echo -e "🚀 Preparing secure sandbox for environment: ${BLUE}${ENV_NAME}${NC}..."

    # Secure temporary directory for dynamic assets (global so trap outlives the function)
    TMP_DIR="$(mktemp -d -t agent-sandbox-XXXXXXXX)"
    chmod 700 "$TMP_DIR"

    local SESSION_ID="$(date +%s)-$$"

    source "$LOCAL_CFG"
    local RAW_IMAGE="${AGENT_SANDBOX_IMAGE:-}"

    [ -z "$RAW_IMAGE" ] && die "Image to load not found in environment config"

    local IMAGE; IMAGE="$(resolve_image "$RAW_IMAGE" "$ENV_NAME")" || die "Failed to resolve Docker image"

    # Allow tests to stop after compilation without invoking Docker
    if [ "${SANDBOX_SKIP_DOCKER:-0}" = "1" ]; then
        return 0
    fi

    local CURRENT_DIR
    CURRENT_DIR="$(pwd)"

    # Load secrets (sourced inside the function, so vars stay local)
    source "$SECRETS"

    [ -n "${AGENT_VAULT_TOKEN:-}" ] || die "AGENT_VAULT_TOKEN is missing from $SECRETS"
    [ -n "${AGENT_VAULT_ADDR:-}" ] || die "AGENT_VAULT_ADDR is missing from $LOCAL_CFG"
    [ -n "${AGENT_VAULT_VAULT:-}" ] || die "AGENT_VAULT_VAULT is missing from $LOCAL_CFG"

    # Strip protocol prefix and port from vault address
    local VAULT_ADDR_RAW="${AGENT_VAULT_ADDR#*://}"
    local VAULT_HOST="${VAULT_ADDR_RAW%%:*}"
    local PROXY_URL="http://$(urlencode "$AGENT_VAULT_TOKEN"):$(urlencode "$AGENT_VAULT_VAULT")@${VAULT_HOST}:14322"

    # Fetch MITM CA from vault API so tools inside the container trust the proxy's TLS
    local CA_FILE="${TMP_DIR}/mitm-ca.pem"
    local SSL_MOUNT="" SSL_ENV=""
    if curl -fsSL "http://${AGENT_VAULT_ADDR}/v1/mitm/ca.pem" -o "$CA_FILE" 2>/dev/null && [ -s "$CA_FILE" ]; then
        SSL_MOUNT="      - ${CA_FILE}:/root/.agent-vault/mitm-ca.pem"
        SSL_ENV=$'\n      SSL_CERT_FILE: "/root/.agent-vault/mitm-ca.pem"\n      NODE_EXTRA_CA_CERTS: "/root/.agent-vault/mitm-ca.pem"\n      CURL_CA_BUNDLE: "/root/.agent-vault/mitm-ca.pem"\n      REQUESTS_CA_BUNDLE: "/root/.agent-vault/mitm-ca.pem"\n      GIT_SSL_CAINFO: "/root/.agent-vault/mitm-ca.pem"\n      DENO_CERT: "/root/.agent-vault/mitm-ca.pem"'
    else
        echo -e "${BLUE}⚠ Could not fetch MITM CA from vault API. HTTPS via proxy will fail.${NC}"
    fi

    # Isolated temporary docker-compose.yml
    cat <<EOF >"$TMP_DIR/docker-compose.yml"
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: sandbox-docker-proxy-${ENV_NAME}-${SESSION_ID}
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
    container_name: sandbox-execution-${ENV_NAME}-${SESSION_ID}
    runtime: runsc
    stdin_open: true
    tty: true
    depends_on:
      - docker-proxy
    env_file:
      - ${CURRENT_DIR}/.agent-sandbox/${ENV_NAME}.env
    environment:
      HTTP_PROXY: "${PROXY_URL}"
      HTTPS_PROXY: "${PROXY_URL}"
      http_proxy: "${PROXY_URL}"
      https_proxy: "${PROXY_URL}"
      NO_PROXY: "localhost,127.0.0.1,${VAULT_HOST}"${SSL_ENV}
    labels:
      agent-sandbox-session: "${SESSION_ID}"
      agent-sandbox-env: "${ENV_NAME}"
    volumes:
      - ${CURRENT_DIR}:${SANDBOX_MOUNT}
${SSL_MOUNT}
    networks:
      - secure-net
    restart: "no"

networks:
  secure-net:
    name: secure-net-${ENV_NAME}-${SESSION_ID}
EOF

    # Cleanup trap (always runs on exit, even if compose fails or user Ctrl+C)
    cleanup() {
        [ -n "${TMP_DIR:-}" ] || return 0
        echo -e "\n${BLUE}🧹 Destroying ephemeral development sandbox...${NC}"
        docker compose -f "$TMP_DIR/docker-compose.yml" down -v --remove-orphans &>/dev/null || true
        rm -rf "$TMP_DIR"
        echo -e "${GREEN}✔ Environment cleared successfully. Host system secured.${NC}"
    }
    trap cleanup EXIT

    # Bring up Docker infrastructure (detached)
    echo -e "🧱 Starting sandbox with runtime: ${BLUE}runsc${NC}..."
    docker compose -f "$TMP_DIR/docker-compose.yml" up -d || die "docker compose failed to start"

    echo -e "${GREEN}✔ Containers started.${NC}"
    echo -e "🔗 gVisor active. HTTP_PROXY forwarding to Agent Vault."
    echo -e "👉 ${GREEN}Attaching to sandbox. Type 'exit' to cleanly close and destroy the workspace.${NC}\n"

    # Attach to the container's main process (CMD), not a shell
    docker attach "sandbox-execution-${ENV_NAME}-${SESSION_ID}" || true
}

# List running sandbox sessions
cmd_ps() {
    printf "%-12s %-12s %-20s %s\n" "SESSION" "ENV" "STATUS" "IMAGE"
    while IFS=$'\t' read -r session env status image; do
        printf "%-12s %-12s %-20s %s\n" "$session" "$env" "$status" "$image"
    done < <(docker ps --filter "label=agent-sandbox-session" \
        --format '{{.Label "agent-sandbox-session"}}\t{{.Label "agent-sandbox-env"}}\t{{.Status}}\t{{.Image}}')
}

# Main Command Router (only when executed, not when sourced for tests)
if [[ ${BASH_SOURCE[0]:-$0} == "${0}" ]]; then
    case "${1:-help}" in
        "" | "help" | "-h" | "--help")
            show_help
            ;;
        "init")
            cmd_init "${2:-}"
            ;;
        "ps")
            cmd_ps
            ;;
        "run")
            cmd_start_sandbox "${2:-}"
            ;;
        -*)
            die "Unknown option: $1.\nUsage: agent-sandbox [init <env>|run <env>|ps|help]"
            ;;
        *)
            die "Unknown command '$1'.\nUsage: agent-sandbox [init <env>|run <env>|ps|help]"
            ;;
    esac
fi
