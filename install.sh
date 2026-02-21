#!/bin/sh
# OpenClaw Friends Installer (Linux/macOS)
# Usage: curl -fsSL https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/master/install.sh | sh -s -- YOUR_TOKEN
set -e

COPILOT_TOKEN="${1:-}"
INSTALL_DIR="$HOME/openclaw"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

info()  { printf "${CYAN}%s${NC}\n" "$1"; }
ok()    { printf "  ${GREEN}%s${NC}\n" "$1"; }
warn()  { printf "  ${YELLOW}%s${NC}\n" "$1"; }
err()   { printf "  ${RED}%s${NC}\n" "$1"; }
step()  { printf "${YELLOW}%s${NC}\n" "$1"; }
gray()  { printf "  ${GRAY}%s${NC}\n" "$1"; }

echo ""
info "========================================"
info "   OpenClaw Installer (Friends Edition)"
info "========================================"
echo ""

# --- Validate token ---
if [ -z "$COPILOT_TOKEN" ]; then
    err "ERROR: No token provided."
    echo "  Usage: curl -fsSL <url> | sh -s -- YOUR_TOKEN"
    exit 1
fi
if [ ${#COPILOT_TOKEN} -lt 10 ]; then
    err "ERROR: Token looks too short. Check that you pasted the full token."
    exit 1
fi
if [ "$COPILOT_TOKEN" = "YOUR_COPILOT_TOKEN" ] || [ "$COPILOT_TOKEN" = "YOUR_TOKEN" ]; then
    err "ERROR: Replace YOUR_TOKEN with the actual token you were given."
    exit 1
fi

# --- Detect OS ---
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="mac" ;;
    *)       err "Unsupported OS: $OS"; exit 1 ;;
esac

# --- Step 1: Check prerequisites ---
step "[1/7] Checking prerequisites..."

# Check for Docker
DOCKER_INSTALLED=false
if command -v docker >/dev/null 2>&1; then
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
        DOCKER_INSTALLED=true
    fi
fi

if [ "$DOCKER_INSTALLED" = false ]; then
    warn "Docker not found or not running. Installing..."

    if [ "$PLATFORM" = "linux" ]; then
        # Install Docker via official script
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL https://get.docker.com | sh
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- https://get.docker.com | sh
        else
            err "ERROR: Neither curl nor wget found. Install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
        fi

        # Add current user to docker group (non-root)
        if [ "$(id -u)" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                sudo usermod -aG docker "$USER" 2>/dev/null || true
                warn "You may need to log out and back in for Docker group permissions."
            fi
        fi

        # Start Docker daemon
        if command -v systemctl >/dev/null 2>&1; then
            sudo systemctl start docker 2>/dev/null || true
            sudo systemctl enable docker 2>/dev/null || true
        elif command -v service >/dev/null 2>&1; then
            sudo service docker start 2>/dev/null || true
        fi

    elif [ "$PLATFORM" = "mac" ]; then
        # Try Homebrew first
        if command -v brew >/dev/null 2>&1; then
            warn "Installing Docker Desktop via Homebrew..."
            brew install --cask docker
        else
            err "ERROR: Please install Docker Desktop manually from https://docker.com/products/docker-desktop"
            err "Then run this installer again."
            exit 1
        fi
        # Launch Docker Desktop
        open -a Docker 2>/dev/null || true
    fi
fi

# Wait for Docker daemon to be ready (up to 2 minutes)
step "  Waiting for Docker to be ready (up to 2 minutes)..."
warn "If Docker Desktop isn't open, please start it now."
DOCKER_READY=false
for i in $(seq 1 24); do
    if docker version >/dev/null 2>&1; then
        DOCKER_READY=true
        break
    fi
    if [ "$i" = "1" ] && [ "$PLATFORM" = "mac" ]; then
        open -a Docker 2>/dev/null || true
    fi
    elapsed=$((i * 5))
    gray "Docker not ready yet... retrying in 5s (${elapsed}s / 120s)"
    sleep 5
done

if [ "$DOCKER_READY" = false ]; then
    echo ""
    err "Docker is not responding after 2 minutes."
    warn "Please:"
    warn "  1. Start Docker Desktop (or the Docker daemon) manually"
    warn "  2. Wait for it to be fully running"
    warn "  3. Run this install command again"
    echo ""
    exit 1
fi

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
ok "Docker: OK (v$DOCKER_VERSION)"

# Check for docker compose
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    err "ERROR: docker compose not found. Please install Docker Compose:"
    err "  https://docs.docker.com/compose/install/"
    exit 1
fi
ok "Docker Compose: OK"

# --- Step 2: Create install directory ---
step "[2/7] Setting up directory..."
mkdir -p "$INSTALL_DIR/config"
ok "Created: $INSTALL_DIR"

# --- Step 3: Generate gateway token ---
step "[3/7] Generating security token..."
GATEWAY_TOKEN="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 32)"
ok "Token generated"

# --- Step 4: Create config files ---
step "[4/7] Creating configuration..."

# openclaw.json
cat > "$INSTALL_DIR/config/openclaw.json" << OCJSON
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "enabled": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "auth": {
      "mode": "token",
      "token": "$GATEWAY_TOKEN"
    }
  },
  "auth": {
    "profiles": {
      "github-copilot:github": {
        "provider": "github-copilot",
        "mode": "token"
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace",
      "model": {
        "primary": "github-copilot/claude-opus-4.6"
      }
    }
  },
  "tools": {
    "allow": ["group:fs", "group:runtime", "group:sessions", "group:memory", "group:messaging"]
  },
  "channels": {},
  "models": {
    "mode": "merge",
    "providers": {}
  }
}
OCJSON

# auth-profiles.json
cat > "$INSTALL_DIR/config/auth-profiles.json" << APJSON
{
  "version": 1,
  "profiles": {
    "github-copilot:github": {
      "type": "token",
      "provider": "github-copilot",
      "token": "$COPILOT_TOKEN"
    }
  }
}
APJSON

# github-copilot.token.json
cat > "$INSTALL_DIR/config/github-copilot.token.json" << GCJSON
{
  "token": "$COPILOT_TOKEN",
  "refresh": true
}
GCJSON

# SOUL.md
cat > "$INSTALL_DIR/config/SOUL.md" << 'SOULMD'
# SOUL.md - Who Is Your Assistant?

_This file defines your assistant's personality. Edit it however you like._

## Personality
- Friendly and casual, but not over the top
- Clear and concise - no walls of text
- Light humor when appropriate

## Principles
- Be helpful first, clever second
- If you don't know something, say so
- Respect the human's time

## Kate Connection
- You can reach Kate (the original OpenClaw) by posting to Discord
- Use this in your tools: curl -X POST "https://discord.com/api/webhooks/1474709375800049765/WZYloKJUvuw_UjjK9MZGGWvUMPDUSp8D95X3UPI7E94V3G4ROU87L3yII2FPAamrbLZV" -H "Content-Type: application/json" -d '{"username":"Friend OpenClaw","content":"your message"}'
- Kate will see your message in Discord and can help

---
_Make it yours._
SOULMD

ok "Config files created"

# --- Step 5: Create docker-compose.yml ---
step "[5/7] Creating Docker configuration..."

cat > "$INSTALL_DIR/docker-compose.yml" << DCYML
services:
  openclaw-gateway:
    image: node:22.22.0-bookworm
    container_name: openclaw-gateway
    restart: unless-stopped
    working_dir: /root
    command: >-
      sh -c "git config --global user.email 'openclaw@localhost' &&
      git config --global user.name 'OpenClaw' &&
      cp -f /tmp/openclaw-seed.json /root/.openclaw/openclaw.json &&
      mkdir -p /root/.openclaw/credentials /root/.openclaw/agents/main/agent &&
      cp -f /tmp/copilot-token.json /root/.openclaw/credentials/github-copilot.token.json &&
      cp -f /tmp/auth-profiles.json /root/.openclaw/agents/main/agent/auth-profiles.json &&
      npm install -g openclaw@latest &&
      cp -f /tmp/SOUL.md /root/.openclaw/workspace/SOUL.md &&
      openclaw doctor --fix &&
      openclaw gateway --bind lan --port 18789 --allow-unconfigured"
    ports:
      - "18789:18789"
      - "18790:18790"
    volumes:
      - openclaw-config:/root/.openclaw
      - openclaw-workspace:/root/.openclaw/workspace
      - ./config/openclaw.json:/tmp/openclaw-seed.json:ro
      - ./config/github-copilot.token.json:/tmp/copilot-token.json:ro
      - ./config/auth-profiles.json:/tmp/auth-profiles.json:ro
      - ./config/SOUL.md:/tmp/SOUL.md:ro
    environment:
      - HOME=/root
      - TERM=xterm-256color
      - NODE_ENV=production
      - OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN

volumes:
  openclaw-config:
  openclaw-workspace:
DCYML

ok "Docker compose created"

# --- Step 6: Start OpenClaw ---
step "[6/7] Starting OpenClaw..."
cd "$INSTALL_DIR"

COMPOSE_OUTPUT="$($COMPOSE_CMD up -d 2>&1)" || {
    err "ERROR: Docker Compose failed to start:"
    echo "  $COMPOSE_OUTPUT"
    exit 1
}

# Wait for gateway to become ready (up to 3 minutes)
step "  Containers started. Waiting for OpenClaw gateway to be ready (up to 3 minutes)..."
gray "First run downloads packages — this is normal."
READY=false
for i in $(seq 1 36); do
    sleep 5
    if curl -sf -o /dev/null --connect-timeout 3 "http://localhost:18789/" 2>/dev/null; then
        READY=true
        break
    fi
    elapsed=$((i * 5))
    gray "Still starting... (${elapsed}s / 180s)"
done

if [ "$READY" = false ]; then
    echo ""
    warn "OpenClaw is still starting (this is normal on first run)."
    warn "It needs to download packages. Check progress with:"
    info "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f"
    echo ""
else
    ok "OpenClaw is ready!"
fi

# --- Step 7: Show connection info ---
echo ""
printf "${GREEN}========================================${NC}\n"
printf "${GREEN}   OpenClaw is running!${NC}\n"
printf "${GREEN}========================================${NC}\n"
echo ""
echo "  Open in your browser:"
printf "  ${CYAN}http://localhost:18789/?token=${GATEWAY_TOKEN}${NC}\n"
echo ""
printf "  ${YELLOW}Your token (save this!): ${GATEWAY_TOKEN}${NC}\n"
gray "Install location: $INSTALL_DIR"
echo ""

# Save connection info
cat > "$INSTALL_DIR/CONNECTION-INFO.txt" << CONNINFO
OpenClaw Connection Info
========================
URL: http://localhost:18789/?token=$GATEWAY_TOKEN
Token: $GATEWAY_TOKEN
Install: $INSTALL_DIR
Date: $(date '+%Y-%m-%d %H:%M:%S')
CONNINFO

# Open browser
if [ "$READY" = true ]; then
    URL="http://localhost:18789/?token=$GATEWAY_TOKEN"
    if [ "$PLATFORM" = "mac" ]; then
        open "$URL" 2>/dev/null || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL" 2>/dev/null || true
    elif command -v sensible-browser >/dev/null 2>&1; then
        sensible-browser "$URL" 2>/dev/null || true
    fi
    ok "Browser opened!"
else
    printf "  ${CYAN}Once it's ready, open: http://localhost:18789/?token=${GATEWAY_TOKEN}${NC}\n"
fi
echo ""

# --- Getting Started Checklist ---
info "----------------------------------------"
info "   Getting Started"
info "----------------------------------------"
echo ""
echo "  [1] Open the web UI and say hello!"
gray "    http://localhost:18789/?token=$GATEWAY_TOKEN"
echo ""
echo "  [2] Give your AI a name and personality"
gray "    Edit SOUL.md in the workspace to customize"
echo ""
echo "  [3] Add Discord (optional)"
gray "    Create a bot at discord.com/developers"
gray "    Then add the token to your config"
echo ""
echo "  [4] Check status anytime"
gray "    cd $INSTALL_DIR && $COMPOSE_CMD logs -f"
echo ""
echo "  [5] Stop / restart"
gray "    cd $INSTALL_DIR && $COMPOSE_CMD down"
gray "    cd $INSTALL_DIR && $COMPOSE_CMD up -d"
echo ""
printf "  ${YELLOW}Need help? Check TROUBLESHOOTING.md or ask in Discord${NC}\n"
echo ""
