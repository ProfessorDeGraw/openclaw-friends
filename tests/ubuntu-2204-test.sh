#!/usr/bin/env bash
# ============================================================
# OpenClaw Install Test — Ubuntu 22.04 LTS Minimal (No GUI)
# ============================================================
#
# Validates the full install flow on a headless Ubuntu server.
# Can run directly on a VM or inside the provided Dockerfile.
#
# Usage:
#   chmod +x ubuntu-2204-test.sh
#   ./ubuntu-2204-test.sh <COPILOT_TOKEN>
#
# Or via Docker:
#   docker build -t openclaw-test-ubuntu -f Dockerfile.ubuntu-test .
#   docker run --rm -e COPILOT_TOKEN=<token> openclaw-test-ubuntu
#
# Exit codes: 0 = all passed, 1 = failures

set -uo pipefail

# ── Config ──────────────────────────────────────────────────

COPILOT_TOKEN="${1:-${COPILOT_TOKEN:-}}"
INSTALL_DIR="$HOME/openclaw"
REPORT_FILE="${REPORT_FILE:-/tmp/openclaw-test-report.md}"
GATEWAY_PORT=18789
TIMEOUT_GATEWAY=180  # seconds to wait for gateway ready

# ── Colors ──────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ── State ───────────────────────────────────────────────────

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
RESULTS=()
START_TIME=$(date +%s)

# ── Helpers ─────────────────────────────────────────────────

log()  { echo -e "${CYAN}$*${NC}"; }
pass() { echo -e "  ${GREEN}✅ PASS: $*${NC}"; TESTS_PASSED=$((TESTS_PASSED+1)); RESULTS+=("| ✅ | $* |"); }
fail() { echo -e "  ${RED}❌ FAIL: $*${NC}"; TESTS_FAILED=$((TESTS_FAILED+1)); RESULTS+=("| ❌ | $* |"); }
skip() { echo -e "  ${YELLOW}⏭️  SKIP: $*${NC}"; TESTS_SKIPPED=$((TESTS_SKIPPED+1)); RESULTS+=("| ⏭️ | $* |"); }
info() { echo -e "  ${GRAY}$*${NC}"; }

# Run a check: check "name" command...
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════
# Phase 1: Environment
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 1: Environment Checks${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

# OS version
log "Checking OS..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  info "OS: $PRETTY_NAME"
  if echo "$VERSION_ID" | grep -q "22.04"; then
    pass "Ubuntu 22.04 detected"
  else
    pass "OS detected: $PRETTY_NAME (not 22.04 but continuing)"
  fi
else
  fail "Cannot detect OS (/etc/os-release missing)"
fi

# Architecture
log "Checking architecture..."
ARCH=$(uname -m)
info "Arch: $ARCH"
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
  pass "Architecture: $ARCH"
else
  fail "Unsupported architecture: $ARCH"
fi

# Kernel
log "Checking kernel..."
KERNEL=$(uname -r)
info "Kernel: $KERNEL"
pass "Kernel: $KERNEL"

# Required commands
log "Checking basic tools..."
for cmd in curl wget git; do
  if command -v $cmd >/dev/null 2>&1; then
    pass "$cmd available"
  else
    fail "$cmd not found (apt install $cmd)"
  fi
done

# Disk space
log "Checking disk space..."
FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
info "Free: ${FREE_GB}GB"
if [ "$FREE_GB" -ge 5 ]; then
  pass "Disk space: ${FREE_GB}GB free (need 5GB+)"
else
  fail "Disk space: ${FREE_GB}GB free (need 5GB+)"
fi

# RAM
log "Checking RAM..."
TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
info "Total RAM: ${TOTAL_MB}MB"
if [ "$TOTAL_MB" -ge 2048 ]; then
  pass "RAM: ${TOTAL_MB}MB (2GB+ recommended)"
else
  fail "RAM: ${TOTAL_MB}MB (2GB+ recommended, may be tight)"
fi

# Internet
log "Checking internet..."
if curl -s -m 10 -o /dev/null https://registry.hub.docker.com/; then
  pass "Internet: Docker Hub reachable"
else
  fail "Internet: Cannot reach Docker Hub"
fi

if curl -s -m 10 -o /dev/null https://raw.githubusercontent.com/; then
  pass "Internet: GitHub reachable"
else
  fail "Internet: Cannot reach GitHub"
fi

# Port
log "Checking port $GATEWAY_PORT..."
if ! ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
  pass "Port $GATEWAY_PORT: available"
else
  fail "Port $GATEWAY_PORT: already in use"
fi

# Token
log "Checking token..."
if [ -z "$COPILOT_TOKEN" ]; then
  fail "Copilot token: not provided (pass as arg or COPILOT_TOKEN env)"
  echo ""
  echo -e "${RED}Cannot continue without a token. Exiting.${NC}"
  exit 1
elif [ ${#COPILOT_TOKEN} -lt 10 ]; then
  fail "Copilot token: too short (${#COPILOT_TOKEN} chars)"
  exit 1
else
  pass "Copilot token: provided (${#COPILOT_TOKEN} chars)"
fi

# ════════════════════════════════════════════════════════════
# Phase 2: Docker Installation
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 2: Docker Installation${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

# Check if Docker is already installed
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
  pass "Docker already installed: v$DOCKER_VER"
else
  log "Docker not found. Installing via official script..."

  # Install prerequisites
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1

  # Official Docker install script
  if curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
    pass "Docker installed via get.docker.com"
  else
    fail "Docker install failed"
    echo -e "${RED}Cannot continue without Docker. Exiting.${NC}"
    exit 1
  fi

  # Start Docker daemon if not running
  if ! docker version >/dev/null 2>&1; then
    log "Starting Docker daemon..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker 2>/dev/null || true
      systemctl enable docker 2>/dev/null || true
    else
      # No systemd (e.g. inside a container) — start manually
      dockerd &>/dev/null &
      DOCKERD_PID=$!
      sleep 5
    fi
  fi

  # Verify
  if docker version >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    pass "Docker daemon running: v$DOCKER_VER"
  else
    fail "Docker daemon not responding after install"
    exit 1
  fi
fi

# Docker Compose
log "Checking Docker Compose..."
if docker compose version >/dev/null 2>&1; then
  COMPOSE_VER=$(docker compose version --short 2>/dev/null)
  pass "Docker Compose: v$COMPOSE_VER"
else
  fail "Docker Compose not available"
fi

# ════════════════════════════════════════════════════════════
# Phase 3: Run Installer
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 3: Run Installer${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

# Clean previous install
if [ -d "$INSTALL_DIR" ]; then
  log "Removing previous install at $INSTALL_DIR..."
  rm -rf "$INSTALL_DIR"
  docker compose -f "$INSTALL_DIR/docker-compose.yml" down 2>/dev/null || true
  pass "Previous install cleaned"
fi

# Check for install.sh
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"

if [ ! -f "$INSTALL_SCRIPT" ]; then
  # Try to find it relative to test location
  INSTALL_SCRIPT="$(dirname "$0")/../install.sh"
fi

if [ -f "$INSTALL_SCRIPT" ]; then
  log "Running installer: $INSTALL_SCRIPT"
  info "Token length: ${#COPILOT_TOKEN}"

  INSTALL_START=$(date +%s)

  if bash "$INSTALL_SCRIPT" "$COPILOT_TOKEN" 2>&1 | tee /tmp/install-output.log; then
    INSTALL_END=$(date +%s)
    INSTALL_DURATION=$((INSTALL_END - INSTALL_START))
    pass "Installer completed (${INSTALL_DURATION}s)"
  else
    INSTALL_END=$(date +%s)
    INSTALL_DURATION=$((INSTALL_END - INSTALL_START))
    fail "Installer exited with error (${INSTALL_DURATION}s)"
    info "Last 20 lines of output:"
    tail -20 /tmp/install-output.log
  fi
else
  skip "install.sh not found at $INSTALL_SCRIPT — skipping install phase"
  info "Create install.sh or place this test alongside it"
fi

# ════════════════════════════════════════════════════════════
# Phase 4: Post-Install Validation
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 4: File Validation${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

# Directory exists
if [ -d "$INSTALL_DIR" ]; then
  pass "Install directory exists: $INSTALL_DIR"
else
  fail "Install directory missing: $INSTALL_DIR"
  echo -e "${RED}Nothing to validate — installer didn't create the directory.${NC}"
  # Still generate report
  SKIP_CONTAINER=true
fi

# Config files
for f in docker-compose.yml config/openclaw.json config/auth-profiles.json; do
  if [ -f "$INSTALL_DIR/$f" ]; then
    SIZE=$(stat -c%s "$INSTALL_DIR/$f" 2>/dev/null || echo "?")
    pass "$f exists (${SIZE} bytes)"
  else
    fail "$f missing"
  fi
done

# Validate JSON files
log "Validating JSON configs..."
for f in config/openclaw.json config/auth-profiles.json; do
  if [ -f "$INSTALL_DIR/$f" ]; then
    if python3 -c "import json; json.load(open('$INSTALL_DIR/$f'))" 2>/dev/null; then
      pass "$f is valid JSON"
    elif jq empty "$INSTALL_DIR/$f" 2>/dev/null; then
      pass "$f is valid JSON (jq)"
    else
      fail "$f is not valid JSON"
    fi
  fi
done

# Token not placeholder
if [ -f "$INSTALL_DIR/config/openclaw.json" ]; then
  if grep -q "YOUR_TOKEN\|YOUR_COPILOT_TOKEN" "$INSTALL_DIR/config/openclaw.json"; then
    fail "Config contains placeholder token"
  else
    pass "No placeholder tokens in config"
  fi
fi

# docker-compose.yml valid
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  if docker compose -f "$INSTALL_DIR/docker-compose.yml" config >/dev/null 2>&1; then
    pass "docker-compose.yml is valid"
  else
    fail "docker-compose.yml validation failed"
  fi
fi

# ════════════════════════════════════════════════════════════
# Phase 5: Container Checks
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 5: Container Checks${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

if [ "${SKIP_CONTAINER:-}" = "true" ]; then
  skip "Skipping container checks (no install directory)"
else
  # Container running
  if docker ps --format '{{.Names}}' | grep -q openclaw; then
    CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep openclaw | head -1)
    pass "Container running: $CONTAINER_NAME"

    # Not crash-looping
    RESTARTS=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
    if [ "$RESTARTS" -le 3 ]; then
      pass "Restart count: $RESTARTS (stable)"
    else
      fail "Restart count: $RESTARTS (crash-looping?)"
    fi

    # Port mapping
    if docker port "$CONTAINER_NAME" 2>/dev/null | grep -q "$GATEWAY_PORT"; then
      pass "Port $GATEWAY_PORT mapped"
    else
      fail "Port $GATEWAY_PORT not mapped"
    fi

    # Container logs — no fatal errors
    FATAL_COUNT=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -ciE "FATAL|panic|segfault|ENOSPC" || true)
    if [ "$FATAL_COUNT" -eq 0 ]; then
      pass "No fatal errors in container logs"
    else
      fail "Found $FATAL_COUNT fatal-level messages in logs"
    fi

    # Memory usage
    MEM=$(docker stats "$CONTAINER_NAME" --no-stream --format '{{.MemUsage}}' 2>/dev/null || echo "unknown")
    info "Memory: $MEM"
    pass "Container stats readable"

  else
    fail "No openclaw container running"
    info "Checking if container exists but stopped..."
    STOPPED=$(docker ps -a --format '{{.Names}} {{.Status}}' | grep openclaw || echo "none")
    info "Stopped containers: $STOPPED"
  fi

  # ── Gateway HTTP checks ────────────────────────────────────

  echo ""
  log "Checking gateway HTTP..."

  # Wait for gateway
  READY=false
  for i in $(seq 1 $((TIMEOUT_GATEWAY / 5))); do
    if curl -s -m 5 -o /dev/null "http://localhost:$GATEWAY_PORT/"; then
      READY=true
      break
    fi
    ELAPSED=$((i * 5))
    info "Waiting for gateway... (${ELAPSED}s / ${TIMEOUT_GATEWAY}s)"
    sleep 5
  done

  if [ "$READY" = "true" ]; then
    pass "Gateway responds on localhost:$GATEWAY_PORT"
  else
    fail "Gateway not responding after ${TIMEOUT_GATEWAY}s"
  fi

  # 127.0.0.1
  if curl -s -m 5 -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/"; then
    pass "Gateway responds on 127.0.0.1:$GATEWAY_PORT"
  else
    fail "Gateway not responding on 127.0.0.1"
  fi

  # Token auth
  if [ -f "$INSTALL_DIR/CONNECTION-INFO.txt" ]; then
    TOKEN=$(grep -oP 'Token:\s*\K\S+' "$INSTALL_DIR/CONNECTION-INFO.txt" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
        "http://localhost:$GATEWAY_PORT/?token=$TOKEN")
      if [ "$HTTP_CODE" = "200" ]; then
        pass "Token authentication works (HTTP 200)"
      else
        fail "Token auth returned HTTP $HTTP_CODE"
      fi
    else
      skip "Cannot extract token from CONNECTION-INFO.txt"
    fi
  else
    skip "CONNECTION-INFO.txt not found, skipping auth test"
  fi

  # API ping
  if [ -n "${TOKEN:-}" ]; then
    API_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 30 \
      "http://localhost:$GATEWAY_PORT/v1/responses" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"model":"openclaw:main","input":"ping"}')
    if [ "$API_CODE" = "200" ]; then
      pass "API endpoint responds (HTTP 200)"
    else
      fail "API endpoint returned HTTP $API_CODE"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════
# Phase 6: Workspace Checks
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Phase 6: Workspace${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

if [ "${SKIP_CONTAINER:-}" != "true" ] && docker ps --format '{{.Names}}' | grep -q openclaw; then
  CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep openclaw | head -1)

  # Check workspace exists inside container
  if docker exec "$CONTAINER_NAME" test -d /root/.openclaw/workspace 2>/dev/null; then
    pass "Workspace directory exists in container"
  else
    fail "Workspace directory missing in container"
  fi

  # Check SOUL.md
  if docker exec "$CONTAINER_NAME" test -f /root/.openclaw/workspace/SOUL.md 2>/dev/null; then
    SOUL_LINES=$(docker exec "$CONTAINER_NAME" wc -l /root/.openclaw/workspace/SOUL.md 2>/dev/null | awk '{print $1}')
    pass "SOUL.md exists in workspace ($SOUL_LINES lines)"
  else
    fail "SOUL.md missing from workspace"
  fi

  # Check openclaw binary
  if docker exec "$CONTAINER_NAME" which openclaw >/dev/null 2>&1; then
    OC_VER=$(docker exec "$CONTAINER_NAME" openclaw --version 2>/dev/null || echo "unknown")
    pass "openclaw CLI installed: $OC_VER"
  else
    fail "openclaw CLI not found in container"
  fi

  # Check git config
  if docker exec "$CONTAINER_NAME" git config user.email >/dev/null 2>&1; then
    pass "Git configured in container"
  else
    fail "Git not configured in container"
  fi
else
  skip "Skipping workspace checks (no running container)"
fi

# ════════════════════════════════════════════════════════════
# Report
# ════════════════════════════════════════════════════════════

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo -e "${GREEN}  All tests passed: $TESTS_PASSED/$TOTAL ✅${NC}"
else
  echo -e "${RED}  Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped${NC}"
fi
echo -e "${CYAN}  Duration: ${TOTAL_DURATION}s${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"

# Generate markdown report
cat > "$REPORT_FILE" << REPORT
# OpenClaw Install Test Report — Ubuntu 22.04

| Field | Value |
|-------|-------|
| **Date** | $(date -u +"%Y-%m-%d %H:%M:%S UTC") |
| **OS** | $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Unknown") |
| **Kernel** | $(uname -r) |
| **Arch** | $(uname -m) |
| **Docker** | ${DOCKER_VER:-not installed} |
| **Result** | **$TESTS_PASSED / $TOTAL passed** $([ "$TESTS_FAILED" -eq 0 ] && echo "✅" || echo "❌") |
| **Duration** | ${TOTAL_DURATION}s |

## Results

| Status | Test |
|--------|------|
$(printf '%s\n' "${RESULTS[@]}")

## Container Logs (last 30 lines)

\`\`\`
$(docker logs "$(docker ps --format '{{.Names}}' | grep openclaw | head -1)" --tail 30 2>&1 || echo "No container found")
\`\`\`

---
_Generated by ubuntu-2204-test.sh_
REPORT

echo ""
info "Report saved to: $REPORT_FILE"
echo ""

# Exit code
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
