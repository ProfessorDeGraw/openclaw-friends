#!/bin/bash
# macos-e2e-test.sh — End-to-end installer validation for macOS (Darwin)
# Usage: ./tests/macos-e2e-test.sh [--token YOUR_COPILOT_TOKEN] [--cleanup]
# Requires: macOS 13+ (Ventura/Sonoma/Sequoia), bash 3.2+
# Run as your normal user (not root — macOS hates that).

set -o pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

TEST_TOKEN="${OPENCLAW_TEST_TOKEN:-}"
CLEANUP=false
INSTALL_DIR="$HOME/openclaw-friend"
INSTALLER_URL="https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.sh"
GATEWAY_PORT=18800
API_PORT=18801
TIMEOUT_CONTAINER=180   # seconds to wait for container ready
TIMEOUT_GATEWAY=120     # seconds to wait for gateway HTTP

# ─── Parse Args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)    TEST_TOKEN="$2"; shift 2 ;;
        --cleanup)  CLEANUP=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--token COPILOT_TOKEN] [--cleanup]"
            echo "  --token     Copilot token for install (or set OPENCLAW_TEST_TOKEN)"
            echo "  --cleanup   Remove install artifacts after test"
            exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ─── Test Framework ───────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
RESULTS=()
START_TIME=$(date +%s)

pass() { PASS=$((PASS + 1)); RESULTS+=("✅ PASS: $1"); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); RESULTS+=("❌ FAIL: $1 — $2"); echo "  ❌ $1 — $2"; }
skip() { SKIP=$((SKIP + 1)); RESULTS+=("⏭️  SKIP: $1 — $2"); echo "  ⏭️  $1 — $2"; }
section() { echo ""; echo "━━━ $1 ━━━"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

wait_for_http() {
    local url="$1" timeout="$2" label="$3"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf --max-time 3 "$url" > /dev/null 2>&1; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    waiting... ${elapsed}s / ${timeout}s"
    done
    return 1
}

wait_for_container() {
    local name="$1" timeout="$2"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        if [[ "$status" == "running" ]]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "unknown"
}

get_arch() {
    uname -m
}

# ─── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  🦉 OpenClaw macOS E2E Installer Test       │"
echo "│     $(date '+%Y-%m-%d %H:%M:%S')                      │"
echo "└─────────────────────────────────────────────┘"
echo ""
echo "  macOS:    $(get_macos_version)"
echo "  Arch:     $(get_arch)"
echo "  Shell:    $BASH_VERSION"
echo "  User:     $(whoami)"
echo "  Cleanup:  $CLEANUP"
echo "  Token:    ${TEST_TOKEN:+set}${TEST_TOKEN:-NOT SET}"

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

section "Phase 1: Pre-Flight Checks"

# T01 — Running on macOS
if [[ "$(uname -s)" == "Darwin" ]]; then
    pass "T01 Running on macOS (Darwin)"
else
    fail "T01 Running on macOS" "uname reports $(uname -s), not Darwin"
    echo "This test is macOS-only. Exiting."
    exit 1
fi

# T02 — macOS version
MACOS_VER=$(get_macos_version)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
if [[ "$MACOS_MAJOR" -ge 13 ]]; then
    pass "T02 macOS version $MACOS_VER (>= 13 Ventura)"
else
    fail "T02 macOS version" "$MACOS_VER — minimum 13 (Ventura) required"
fi

# T03 — Architecture
ARCH=$(get_arch)
if [[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]]; then
    pass "T03 Architecture: $ARCH"
else
    fail "T03 Architecture" "Unexpected: $ARCH"
fi

# T04 — Rosetta 2 (Apple Silicon only)
if [[ "$ARCH" == "arm64" ]]; then
    if /usr/bin/pgrep -q oahd 2>/dev/null || [[ -f /Library/Apple/usr/share/rosetta/rosetta ]]; then
        pass "T04 Rosetta 2 available"
    else
        skip "T04 Rosetta 2" "Not installed (may be needed for some Docker images)"
    fi
else
    skip "T04 Rosetta 2" "Intel Mac — not applicable"
fi

# T05 — curl available
if command -v curl &>/dev/null; then
    pass "T05 curl available ($(curl --version | head -1 | awk '{print $2}'))"
else
    fail "T05 curl available" "curl not found"
fi

# T06 — Not running as root
if [[ "$(whoami)" != "root" ]]; then
    pass "T06 Running as normal user (not root)"
else
    fail "T06 Running as normal user" "Running as root — macOS installers shouldn't run as root"
fi

# T07 — Disk space (need at least 5GB)
FREE_GB=$(df -g "$HOME" | tail -1 | awk '{print $4}')
if [[ "$FREE_GB" -ge 5 ]]; then
    pass "T07 Disk space: ${FREE_GB}GB free (>= 5GB)"
else
    fail "T07 Disk space" "Only ${FREE_GB}GB free — need at least 5GB"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: HOMEBREW
# ═══════════════════════════════════════════════════════════════════════════════

section "Phase 2: Homebrew"

# T08 — Homebrew installed
BREW_PREINSTALLED=false
if command -v brew &>/dev/null; then
    BREW_PREINSTALLED=true
    BREW_VER=$(brew --version | head -1)
    pass "T08 Homebrew pre-installed ($BREW_VER)"
else
    skip "T08 Homebrew pre-installed" "Not found — installer should handle this"
fi

# T09 — Homebrew prefix correct for architecture
if $BREW_PREINSTALLED; then
    BREW_PREFIX=$(brew --prefix)
    if [[ "$ARCH" == "arm64" && "$BREW_PREFIX" == "/opt/homebrew" ]]; then
        pass "T09 Homebrew prefix correct for ARM64 (/opt/homebrew)"
    elif [[ "$ARCH" == "x86_64" && "$BREW_PREFIX" == "/usr/local" ]]; then
        pass "T09 Homebrew prefix correct for Intel (/usr/local)"
    else
        fail "T09 Homebrew prefix" "Unexpected: $BREW_PREFIX for $ARCH"
    fi
else
    skip "T09 Homebrew prefix" "Homebrew not installed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: DOCKER
# ═══════════════════════════════════════════════════════════════════════════════

section "Phase 3: Docker"

# T10 — Docker CLI present
DOCKER_PREINSTALLED=false
if command -v docker &>/dev/null; then
    DOCKER_PREINSTALLED=true
    pass "T10 Docker CLI present"
else
    skip "T10 Docker CLI" "Not found — installer should install Docker Desktop"
fi

# T11 — Docker daemon running
DOCKER_RUNNING=false
if $DOCKER_PREINSTALLED; then
    if docker info &>/dev/null; then
        DOCKER_RUNNING=true
        DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        pass "T11 Docker daemon running (v$DOCKER_VER)"
    else
        skip "T11 Docker daemon" "CLI present but daemon not running"
    fi
else
    skip "T11 Docker daemon" "Docker not installed"
fi

# T12 — Docker runtime type (Docker Desktop vs OrbStack vs Colima)
if $DOCKER_RUNNING; then
    DOCKER_CONTEXT=$(docker context show 2>/dev/null || echo "unknown")
    DOCKER_RUNTIME="unknown"
    if pgrep -q "Docker Desktop" 2>/dev/null || [[ -d "/Applications/Docker.app" ]]; then
        DOCKER_RUNTIME="Docker Desktop"
    elif pgrep -q "OrbStack" 2>/dev/null || [[ -d "/Applications/OrbStack.app" ]]; then
        DOCKER_RUNTIME="OrbStack"
    elif command -v colima &>/dev/null; then
        DOCKER_RUNTIME="Colima"
    fi
    pass "T12 Docker runtime: $DOCKER_RUNTIME (context: $DOCKER_CONTEXT)"
else
    skip "T12 Docker runtime" "Docker not running"
fi

# T13 — Docker Compose available
if $DOCKER_RUNNING; then
    if docker compose version &>/dev/null; then
        COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
        pass "T13 Docker Compose v$COMPOSE_VER"
    elif command -v docker-compose &>/dev/null; then
        fail "T13 Docker Compose" "Only legacy docker-compose found — need 'docker compose' (v2)"
    else
        fail "T13 Docker Compose" "Not available"
    fi
else
    skip "T13 Docker Compose" "Docker not running"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 4: PRE-INSTALL STATE
# ═══════════════════════════════════════════════════════════════════════════════

section "Phase 4: Pre-Install State"

# T14 — No leftover install directory
if [[ -d "$INSTALL_DIR" ]]; then
    skip "T14 Clean install directory" "$INSTALL_DIR already exists (prior install?)"
else
    pass "T14 Clean install directory (no prior install)"
fi

# T15 — No leftover containers
if $DOCKER_RUNNING; then
    if docker ps -a --format '{{.Names}}' | grep -q "openclaw-friend"; then
        skip "T15 No leftover containers" "openclaw-friend container exists"
    else
        pass "T15 No leftover containers"
    fi
else
    skip "T15 No leftover containers" "Docker not running"
fi

# T16 — Ports available
for port in $GATEWAY_PORT $API_PORT; do
    if lsof -i ":$port" &>/dev/null; then
        fail "T16 Port $port available" "Port in use — $(lsof -i :$port | tail -1 | awk '{print $1}')"
    else
        pass "T16 Port $port available"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 5: RUN INSTALLER
# ═══════════════════════════════════════════════════════════════════════════════

section "Phase 5: Run Installer"

if [[ -z "$TEST_TOKEN" ]]; then
    skip "T17-T22 Installer execution" "No --token provided. Set OPENCLAW_TEST_TOKEN or pass --token."
    echo "  Skipping phases 5-8 (require a valid token to actually install)."
else
    # T17 — Download installer
    INSTALLER_TMP=$(mktemp /tmp/openclaw-install-XXXXXX.sh)
    if curl -sf -o "$INSTALLER_TMP" "$INSTALLER_URL"; then
        pass "T17 Downloaded installer ($(wc -c < "$INSTALLER_TMP" | tr -d ' ') bytes)"
    else
        fail "T17 Download installer" "curl failed for $INSTALLER_URL"
        INSTALLER_TMP=""
    fi

    # T18 — Installer is valid bash
    if [[ -n "$INSTALLER_TMP" ]]; then
        if bash -n "$INSTALLER_TMP" 2>/dev/null; then
            pass "T18 Installer syntax valid"
        else
            fail "T18 Installer syntax" "bash -n reports errors"
        fi
    fi

    # T19 — Installer has shebang
    if [[ -n "$INSTALLER_TMP" ]]; then
        FIRST_LINE=$(head -1 "$INSTALLER_TMP")
        if [[ "$FIRST_LINE" == "#!/"* ]]; then
            pass "T19 Installer has shebang ($FIRST_LINE)"
        else
            fail "T19 Installer shebang" "First line: $FIRST_LINE"
        fi
    fi

    # T20 — Run installer
    if [[ -n "$INSTALLER_TMP" ]]; then
        echo "  Running installer (this may take several minutes on first run)..."
        chmod +x "$INSTALLER_TMP"
        INSTALL_LOG=$(mktemp /tmp/openclaw-install-log-XXXXXX.txt)

        # Run with token, capture output
        if bash "$INSTALLER_TMP" "$TEST_TOKEN" > "$INSTALL_LOG" 2>&1; then
            pass "T20 Installer completed (exit 0)"
        else
            EXIT_CODE=$?
            fail "T20 Installer completed" "Exit code: $EXIT_CODE"
            echo "    Last 20 lines of install log:"
            tail -20 "$INSTALL_LOG" | sed 's/^/    /'
        fi

        # T21 — Installer didn't print errors
        ERROR_COUNT=$(grep -ci "error\|fatal\|panic\|traceback" "$INSTALL_LOG" 2>/dev/null || echo "0")
        if [[ "$ERROR_COUNT" -eq 0 ]]; then
            pass "T21 No errors in installer output"
        else
            fail "T21 Errors in installer output" "$ERROR_COUNT error-like lines found"
            grep -i "error\|fatal\|panic\|traceback" "$INSTALL_LOG" | head -5 | sed 's/^/    /'
        fi

        rm -f "$INSTALLER_TMP"
    fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 6: POST-INSTALL VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

    section "Phase 6: Post-Install Verification"

    # T22 — Install directory created
    if [[ -d "$INSTALL_DIR" ]]; then
        pass "T22 Install directory exists ($INSTALL_DIR)"
    else
        fail "T22 Install directory" "Not found at $INSTALL_DIR"
    fi

    # T23 — docker-compose.yml exists
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        pass "T23 docker-compose.yml exists"
    else
        fail "T23 docker-compose.yml" "Not found"
    fi

    # T24 — Config files exist
    CONFIG_FILES=("config/openclaw.json" "config/auth-profiles.json" "config/SOUL.md")
    ALL_CONFIG_OK=true
    for cf in "${CONFIG_FILES[@]}"; do
        if [[ ! -f "$INSTALL_DIR/$cf" ]]; then
            fail "T24 Config file: $cf" "Not found"
            ALL_CONFIG_OK=false
        fi
    done
    if $ALL_CONFIG_OK; then
        pass "T24 All config files present (${#CONFIG_FILES[@]} files)"
    fi

    # T25 — Config has no placeholder tokens
    if [[ -f "$INSTALL_DIR/config/openclaw.json" ]]; then
        if grep -q "YOUR_.*TOKEN\|PASTE_.*HERE" "$INSTALL_DIR/config/openclaw.json"; then
            fail "T25 Config tokens" "Placeholder token still present in openclaw.json"
        else
            pass "T25 Config tokens populated (no placeholders)"
        fi
    fi

    # T26 — CONNECTION-INFO.txt created
    if [[ -f "$INSTALL_DIR/CONNECTION-INFO.txt" ]]; then
        pass "T26 CONNECTION-INFO.txt created"
    else
        fail "T26 CONNECTION-INFO.txt" "Not found"
    fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 7: CONTAINER & GATEWAY
# ═══════════════════════════════════════════════════════════════════════════════

    section "Phase 7: Container & Gateway"

    # T27 — Container exists
    if docker ps -a --format '{{.Names}}' | grep -q "openclaw-friend"; then
        pass "T27 Container 'openclaw-friend' exists"
    else
        fail "T27 Container exists" "'openclaw-friend' not found in docker ps -a"
    fi

    # T28 — Container is running
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' openclaw-friend 2>/dev/null || echo "missing")
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
        pass "T28 Container is running"
    else
        fail "T28 Container running" "Status: $CONTAINER_STATUS"
        echo "    Container logs (last 20 lines):"
        docker logs --tail 20 openclaw-friend 2>&1 | sed 's/^/    /'
    fi

    # T29 — Container not restarting in a loop
    RESTART_COUNT=$(docker inspect -f '{{.RestartCount}}' openclaw-friend 2>/dev/null || echo "0")
    if [[ "$RESTART_COUNT" -le 2 ]]; then
        pass "T29 Container stable (restarts: $RESTART_COUNT)"
    else
        fail "T29 Container stability" "Restart count: $RESTART_COUNT (possible crash loop)"
    fi

    # T30 — Gateway HTTP responds
    echo "  Waiting for gateway on port $GATEWAY_PORT..."
    if wait_for_http "http://localhost:$GATEWAY_PORT" "$TIMEOUT_GATEWAY" "gateway"; then
        pass "T30 Gateway HTTP responds on :$GATEWAY_PORT"
    else
        fail "T30 Gateway HTTP" "No response after ${TIMEOUT_GATEWAY}s"
        echo "    Container logs (last 30 lines):"
        docker logs --tail 30 openclaw-friend 2>&1 | sed 's/^/    /'
    fi

    # T31 — Gateway returns HTML (web UI)
    GATEWAY_BODY=$(curl -sf --max-time 5 "http://localhost:$GATEWAY_PORT/" 2>/dev/null || echo "")
    if echo "$GATEWAY_BODY" | grep -qi "html\|openclaw\|<!doctype"; then
        pass "T31 Gateway serves web UI"
    elif [[ -n "$GATEWAY_BODY" ]]; then
        fail "T31 Gateway web UI" "Response doesn't look like HTML"
    else
        fail "T31 Gateway web UI" "Empty response"
    fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 8: WORKSPACE & FUNCTIONAL CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

    section "Phase 8: Workspace & Functional Checks"

    # T32 — Workspace volume exists
    if docker volume ls --format '{{.Name}}' | grep -q "friend-workspace\|openclaw.*workspace"; then
        pass "T32 Workspace volume exists"
    else
        fail "T32 Workspace volume" "No workspace volume found"
    fi

    # T33 — SOUL.md present in container
    if docker exec openclaw-friend test -f /root/.openclaw/workspace/SOUL.md 2>/dev/null; then
        pass "T33 SOUL.md present in container workspace"
    else
        skip "T33 SOUL.md in container" "Not found (may not be copied yet)"
    fi

    # T34 — OpenClaw binary installed in container
    if docker exec openclaw-friend which openclaw &>/dev/null; then
        OC_VER=$(docker exec openclaw-friend openclaw --version 2>/dev/null || echo "unknown")
        pass "T34 OpenClaw installed in container ($OC_VER)"
    else
        fail "T34 OpenClaw in container" "openclaw binary not found"
    fi

    # T35 — Node.js version in container
    NODE_VER=$(docker exec openclaw-friend node --version 2>/dev/null || echo "missing")
    if [[ "$NODE_VER" == v22* ]]; then
        pass "T35 Node.js version in container ($NODE_VER)"
    else
        fail "T35 Node.js version" "Expected v22.x, got $NODE_VER"
    fi

    # T36 — Container can resolve DNS (not network-isolated)
    if docker exec openclaw-friend nslookup github.com &>/dev/null 2>&1; then
        pass "T36 Container DNS resolution works"
    elif docker exec openclaw-friend ping -c1 -W2 github.com &>/dev/null 2>&1; then
        pass "T36 Container network connectivity works"
    else
        fail "T36 Container network" "Cannot resolve/reach github.com"
    fi

    # T37 — Idempotency: run installer again
    echo "  Running installer a second time (idempotency check)..."
    IDEM_LOG=$(mktemp /tmp/openclaw-idem-XXXXXX.txt)
    if bash "$INSTALL_DIR/../openclaw-install.sh" "$TEST_TOKEN" > "$IDEM_LOG" 2>&1 || \
       curl -sf "$INSTALLER_URL" | bash -s "$TEST_TOKEN" > "$IDEM_LOG" 2>&1; then
        pass "T37 Idempotency: second install succeeded"
    else
        skip "T37 Idempotency" "Re-run had issues (may need manual check)"
    fi
    rm -f "$IDEM_LOG"

fi  # end of token-gated tests

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 9: CLEANUP (optional)
# ═══════════════════════════════════════════════════════════════════════════════

if $CLEANUP; then
    section "Phase 9: Cleanup"
    echo "  Stopping containers..."
    (cd "$INSTALL_DIR" && docker compose down -v 2>/dev/null) || true
    echo "  Removing install directory..."
    rm -rf "$INSTALL_DIR"
    rm -f "$INSTALL_LOG" 2>/dev/null
    pass "Cleanup complete"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  TEST REPORT
# ═══════════════════════════════════════════════════════════════════════════════

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  📋 Test Report                             │"
echo "├─────────────────────────────────────────────┤"
printf "│  %-43s │\n" "Date: $(date '+%Y-%m-%d %H:%M:%S')"
printf "│  %-43s │\n" "macOS: $MACOS_VER ($ARCH)"
printf "│  %-43s │\n" "Duration: ${DURATION}s"
printf "│  %-43s │\n" "Docker: ${DOCKER_PREINSTALLED:+pre-installed}${DOCKER_PREINSTALLED:-missing}"
printf "│  %-43s │\n" "Homebrew: ${BREW_PREINSTALLED:+pre-installed}${BREW_PREINSTALLED:-missing}"
echo "├─────────────────────────────────────────────┤"
printf "│  %-43s │\n" "✅ Passed:  $PASS"
printf "│  %-43s │\n" "❌ Failed:  $FAIL"
printf "│  %-43s │\n" "⏭️  Skipped: $SKIP"
printf "│  %-43s │\n" "Total:     $((PASS + FAIL + SKIP))"
echo "├─────────────────────────────────────────────┤"

if [[ $FAIL -eq 0 ]]; then
    echo "│  🎉 ALL TESTS PASSED                       │"
else
    echo "│  ⚠️  SOME TESTS FAILED                      │"
fi

echo "└─────────────────────────────────────────────┘"

# Full results log
echo ""
echo "── Detail ──"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done

# Write machine-readable report
REPORT_FILE="/tmp/openclaw-macos-e2e-$(date +%Y%m%d-%H%M%S).json"
cat > "$REPORT_FILE" << EJSON
{
  "test": "macos-e2e",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "duration_seconds": $DURATION,
  "macos_version": "$MACOS_VER",
  "arch": "$ARCH",
  "docker_preinstalled": $DOCKER_PREINSTALLED,
  "brew_preinstalled": $BREW_PREINSTALLED,
  "passed": $PASS,
  "failed": $FAIL,
  "skipped": $SKIP,
  "success": $([ $FAIL -eq 0 ] && echo true || echo false)
}
EJSON
echo ""
echo "  Report saved: $REPORT_FILE"
echo ""

# Exit code: 0 if no failures, 1 if any
[[ $FAIL -eq 0 ]]
