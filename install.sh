#!/usr/bin/env bash

# Automatic installer script for agent-sandbox
set -euo pipefail

VERSION="${AGENT_SANDBOX_VERSION:-main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Starting agent-sandbox Installation ===${NC}"

# 1. Dependency Checks
echo -e "🔍 Verifying system dependencies..."
for cmd in docker openssl runsc; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}❌ Error: '$cmd' is not installed. Please install it before proceeding.${NC}"
        exit 1
    fi
done

# Verify the Docker Compose plugin is available
if ! docker compose version &>/dev/null; then
    echo -e "${RED}❌ Error: the 'docker compose' plugin is not available.${NC}"
    echo -e "Install Docker Compose v2 (bundled with Docker Desktop or as a plugin) before proceeding."
    exit 1
fi

# 4. Install agent-sandbox CLI
INSTALL_PATH="/usr/local/bin/agent-sandbox"
LOCAL_BIN_PATH="$HOME/.local/bin/agent-sandbox"

echo -e "⚙️ Installing CLI executable..."

if [ -w "/usr/local/bin" ]; then
    DEST_PATH="$INSTALL_PATH"
else
    mkdir -p "$HOME/.local/bin"
    DEST_PATH="$LOCAL_BIN_PATH"
fi

# The CLI script ships as agent-sandbox.sh in the repository
if [ -f "./agent-sandbox.sh" ]; then
    cp "./agent-sandbox.sh" "$DEST_PATH"
else
    if command -v curl &>/dev/null; then
        echo -e "${BLUE}📡 Downloading agent-sandbox CLI from GitHub...${NC}"
        curl -fsSL "https://raw.githubusercontent.com/xoadev/agent-sandbox/${VERSION}/agent-sandbox.sh" -o "$DEST_PATH"
    else
        echo -e "${RED}❌ Error: 'curl' is required to download the CLI.${NC}"
        echo -e "Install curl or run this installer from a local checkout of the repository."
        exit 1
    fi
fi

chmod +x "$DEST_PATH"
echo -e "${GREEN}✔ Executable successfully installed to: $DEST_PATH${NC}"

if [ "$DEST_PATH" == "$LOCAL_BIN_PATH" ]; then
    echo -e "${BLUE}💡 Make sure '$HOME/.local/bin' is included in your system \$PATH variable.${NC}"
fi

# 5. Protect secrets from accidental commits
if [ -f ".gitignore" ]; then
    if ! grep -qs "^\*\.secret\.env$" ".gitignore"; then
        echo -e "🔒 Adding '*.secret.env' to .gitignore..."
        printf '\n# agent-sandbox secret files\n*.secret.env\n' >> ".gitignore"
    fi
fi

echo -e "\n${GREEN}🎉 Installation completed successfully!${NC}"
echo -e "Run 'agent-sandbox init [ENVIRONMENT]' in your project folder to get started."

