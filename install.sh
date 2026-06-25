#!/usr/bin/env bash

# Automatic installer script for agent-sandbox
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Starting agent-sandbox Installation ===${NC}"

# 1. Dependency Checks
echo -e "🔍 Verifying system dependencies..."
for cmd in docker openssl; do
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

# Check if gVisor is registered with Docker
if ! docker info 2>/dev/null | grep -iq "runsc"; then
    echo -e "${RED}⚠️ Warning: The 'runsc' (gVisor) runtime does not appear to be active in your Docker daemon.${NC}"
    echo -e "Make sure you configure gVisor as instructed in the documentation before running a sandbox."
fi

# 2. Create Global Configuration Directory
GLOBAL_DIR="${GLOBAL_DIR:-$HOME/.agent-sandbox}"
echo -e "📁 Creating global configuration directory at: $GLOBAL_DIR"
mkdir -p "$GLOBAL_DIR"

# 3. Create Sample Secrets File if Not Exists
SECRETS_FILE="$GLOBAL_DIR/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "🔑 Creating secure secrets template..."
    cat <<'EOF' >"$SECRETS_FILE"
# agent-sandbox secrets: simple key=value assignments, one per line.
# Lines starting with '#' are ignored. Replace the placeholders below.
github=ghp_DUMMY_DEVELOPMENT_TOKEN_CHANGE_ME
anthropic=sk-ant-api03-DUMMY_DEVELOPMENT_KEY_CHANGE_ME
openai=sk-proj-DUMMY_DEVELOPMENT_KEY_CHANGE_ME
EOF
    chmod 600 "$SECRETS_FILE"
    echo -e "   - Created '$SECRETS_FILE' with exclusive user-only read permissions (0600)."
else
    echo -e "ℹ️ Secrets file already exists. Skipping secrets initialization."
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
elif [ -f "./agent-sandbox" ]; then
    cp "./agent-sandbox" "$DEST_PATH"
else
    echo -e "${RED}❌ Error: could not find the agent-sandbox.sh script in the current directory.${NC}"
    echo -e "Run this installer from the root of the agent-sandbox repository."
    exit 1
fi

chmod +x "$DEST_PATH"
echo -e "${GREEN}✔ Executable successfully installed to: $DEST_PATH${NC}"

if [ "$DEST_PATH" == "$LOCAL_BIN_PATH" ]; then
    echo -e "${BLUE}💡 Make sure '$HOME/.local/bin' is included in your system \$PATH variable.${NC}"
fi

echo -e "\n${GREEN}🎉 Installation completed successfully!${NC}"
echo -e "Run 'agent-sandbox init' in your project folder to get started."
