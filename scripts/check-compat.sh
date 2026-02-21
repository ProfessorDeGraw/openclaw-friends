#!/usr/bin/env bash
# check-compat.sh — OpenClaw Friends compatibility checker
#
# Validates that the current system meets all requirements for running
# OpenClaw Friends. Checks Docker, Compose, OS, architecture, ports,
# memory, disk, and network connectivity.
#
# Usage:
#   bash check-compat.sh              # interactive colored output
#   bash check-compat.sh --json       # machine-readable JSON
#   bash check-compat.sh --quiet      # exit code only (0=ok, 1=fail)
#   bash check-compat.sh --fix        # attempt auto-fixes where possible
#
# Exit codes:
#   0  All checks passed
#   1  One or more critical checks failed
#   2  Warnings only (non-blocking)

set -euo pipefail

# ── Config ────────────────────────────────────────────────
MIN_DOCKER_MAJOR=20
MIN_DOCKER_MINOR=10
MIN_DOCKER_PATCH=7
MIN_COMPOSE_MAJOR=2
MIN_COMPOSE_MINOR=0
MIN_RAM_MB=2048
MIN_DISK_MB=2048
GATEWAY_PORT=${GATEWAY_PORT:-18800}
WS_PORT=${WS_PORT:-18801}

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

# ── State ─────────────────────────────────────────────────
PASS=0; WARN=0; FAIL=0
RESULTS=()
JSON_MODE=false
QUIET_MODE=false
FIX_MODE=false

# Parse args
for arg in "$@"; do
    case "$arg" in
        --json)  JSON_MODE=true ;;
        --quiet) QUIET_MODE=true ;;
        --fix)   FIX_MODE=true ;;
    esac
done

$JSON_MODE && QUIET_MODE=false

# ── Helpers ───────────────────────────────────────────────
log() { $JSON_MODE || $QUIET_MODE || printf "$@\n"; }

check_pass() {
    ((PASS++)) || true
    RESULTS+=("{\"name\":\"$1\",\"status\":\"pass\",\"detail\":\"$2\"}")
    $JSON_MODE || $QUIET_MODE || printf "  ${GREEN}✅ %-30s${NC} %s\n" "$1" "$2"
}

check_warn() {
    ((WARN++)) || true
    RESULTS+=("{\"name\":\"$1\",\"status\":\"warn\",\"detail\":\"$2\"}")
    $JSON_MODE || $QUIET_MODE || printf "  ${YELLOW}⚠️  %-30s${NC} %s\n" "$1" "$2"
}

check_fail() {
    ((FAIL++)) || true
    RESULTS+=("{\"name\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}")
    $JSON_MODE || $QUIET_MODE || printf "  ${RED}❌ %-30s${NC} %s\n" "$1" "$2"
}

check_skip() {
    RESULTS+=("{\"name\":\"$1\",\"status\":\"skip\",\"detail\":\"$2\"}")
    $JSON_MODE || $QUIET_MODE || printf "  ${GRAY}⏭  %-30s${NC} %s\n" "$1" "$2"
}

version_ge() {
    # Compare version strings: version_ge "24.0.7" "20.10.7" → 0 (true)
    local IFS=.
    local i a=($1) b=($2)
    for ((i=0; i<${#b[@]}; i++)); do
        local av=${a[i]:-0}
        local bv=${b[i]:-0}
        # Strip non-numeric suffixes
        av=${av%%[!0-9]*}
        bv=${bv%%[!0-9]*}
        ((av > bv)) && return 0
        ((av < bv)) && return 1
    done
    return 0
}

# ── Header ────────────────────────────────────────────────
if ! $JSON_MODE && ! $QUIET_MODE; then
    echo ""
    printf "${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
    printf "${BOLD}║   🐺 OpenClaw Friends — Compatibility Checker   ║${NC}\n"
    printf "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
    echo ""
fi

# ══════════════════════════════════════════════════════════
# Section 1: Operating System
# ══════════════════════════════════════════════════════════
log "${BOLD}  ── Operating System ──${NC}"

OS="$(uname -s)"
ARCH="$(uname -m)"
KERNEL="$(uname -r)"

case "$OS" in
    Linux*)
        PLATFORM="linux"
        # Detect distro
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO="${NAME:-Unknown} ${VERSION_ID:-}"
        else
            DISTRO="Unknown Linux"
        fi
        check_pass "Operating System" "$DISTRO (kernel $KERNEL)"

        # Check if running in WSL
        if grep -qi microsoft /proc/version 2>/dev/null; then
            check_pass "WSL Detected" "Running in WSL2"
        fi
        ;;
    Darwin*)
        PLATFORM="mac"
        MAC_VER="$(sw_vers -productVersion 2>/dev/null || echo '?')"
        MAC_MAJOR="${MAC_VER%%.*}"
        if [ "${MAC_MAJOR:-0}" -ge 12 ] 2>/dev/null; then
            check_pass "Operating System" "macOS $MAC_VER"
        elif [ "${MAC_MAJOR:-0}" -ge 11 ] 2>/dev/null; then
            check_warn "Operating System" "macOS $MAC_VER — limited Docker Desktop support"
        else
            check_fail "Operating System" "macOS $MAC_VER — too old for Docker Desktop"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        check_warn "Operating System" "Windows (running from Git Bash/MSYS). Use PowerShell installer for best results."
        ;;
    *)
        PLATFORM="unknown"
        check_fail "Operating System" "Unsupported: $OS"
        ;;
esac

# Architecture
case "$ARCH" in
    x86_64|amd64)
        check_pass "Architecture" "$ARCH (Intel/AMD 64-bit)"
        ;;
    aarch64|arm64)
        check_pass "Architecture" "$ARCH (ARM 64-bit)"
        ;;
    armv7l|armv6l)
        check_fail "Architecture" "$ARCH — 32-bit ARM not supported. Use 64-bit OS."
        ;;
    *)
        check_warn "Architecture" "$ARCH — untested architecture"
        ;;
esac

# ══════════════════════════════════════════════════════════
# Section 2: Docker Engine
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── Docker Engine ──${NC}"

DOCKER_OK=false
DOCKER_VER=""

if command -v docker >/dev/null 2>&1; then
    check_pass "Docker Installed" "$(command -v docker)"

    # Check if daemon is running
    if docker info >/dev/null 2>&1; then
        check_pass "Docker Daemon" "Running"

        # Get version
        DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '')"
        if [ -n "$DOCKER_VER" ]; then
            MIN_VER="${MIN_DOCKER_MAJOR}.${MIN_DOCKER_MINOR}.${MIN_DOCKER_PATCH}"
            if version_ge "$DOCKER_VER" "$MIN_VER"; then
                check_pass "Docker Version" "v$DOCKER_VER (minimum: v$MIN_VER)"
                DOCKER_OK=true
            else
                check_fail "Docker Version" "v$DOCKER_VER — minimum required: v$MIN_VER"
            fi
        else
            check_warn "Docker Version" "Could not determine version"
        fi

        # Check Docker storage driver
        STORAGE="$(docker info --format '{{.Driver}}' 2>/dev/null || echo '?')"
        case "$STORAGE" in
            overlay2) check_pass "Storage Driver" "$STORAGE (recommended)" ;;
            *)        check_warn "Storage Driver" "$STORAGE (overlay2 recommended)" ;;
        esac

        # Check cgroup version
        CGROUP="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo '?')"
        if [ "$CGROUP" = "2" ]; then
            check_pass "Cgroup Version" "v2"
        else
            check_warn "Cgroup Version" "v${CGROUP} (v2 recommended for modern kernels)"
        fi

    else
        check_fail "Docker Daemon" "Not running. Start with: sudo systemctl start docker"

        if $FIX_MODE; then
            log "  ${CYAN}Attempting fix: starting Docker...${NC}"
            sudo systemctl start docker 2>/dev/null && check_pass "Docker Fix" "Daemon started" || check_fail "Docker Fix" "Could not start daemon"
        fi
    fi
else
    check_fail "Docker Installed" "Not found. Install: https://docs.docker.com/engine/install/"

    if $FIX_MODE && [ "$PLATFORM" = "linux" ]; then
        log "  ${CYAN}Attempting fix: installing Docker...${NC}"
        if curl -fsSL https://get.docker.com | sh 2>/dev/null; then
            check_pass "Docker Fix" "Installed via get.docker.com"
        else
            check_fail "Docker Fix" "Auto-install failed"
        fi
    fi
fi

# ══════════════════════════════════════════════════════════
# Section 3: Docker Compose
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── Docker Compose ──${NC}"

COMPOSE_CMD=""
COMPOSE_VER=""

# Try V2 plugin
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    COMPOSE_VER="$(docker compose version --short 2>/dev/null || echo '')"
    check_pass "Compose V2 Plugin" "v$COMPOSE_VER"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    COMPOSE_VER="$(docker-compose version --short 2>/dev/null || echo '')"

    # Check if it's actually V2 in standalone mode
    if echo "$COMPOSE_VER" | grep -q "^2\."; then
        check_pass "Compose Standalone" "v$COMPOSE_VER (V2)"
    else
        check_warn "Compose V1" "v$COMPOSE_VER — V1 is EOL. Upgrade to V2."
    fi
else
    check_fail "Docker Compose" "Not found. Install: sudo apt install docker-compose-plugin"

    if $FIX_MODE && [ "$PLATFORM" = "linux" ]; then
        log "  ${CYAN}Attempting fix: installing compose plugin...${NC}"
        if sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
            check_pass "Compose Fix" "Plugin installed"
        else
            check_fail "Compose Fix" "Auto-install failed"
        fi
    fi
fi

# Compose version check
if [ -n "$COMPOSE_VER" ]; then
    MIN_COMP="${MIN_COMPOSE_MAJOR}.${MIN_COMPOSE_MINOR}.0"
    if version_ge "$COMPOSE_VER" "$MIN_COMP"; then
        check_pass "Compose Version" "v$COMPOSE_VER ≥ v$MIN_COMP"
    else
        check_fail "Compose Version" "v$COMPOSE_VER < v$MIN_COMP"
    fi
fi

# ══════════════════════════════════════════════════════════
# Section 4: System Resources
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── System Resources ──${NC}"

# RAM
if [ -f /proc/meminfo ]; then
    TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MB=$((TOTAL_KB / 1024))
    AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    AVAIL_MB=$((AVAIL_KB / 1024))

    if [ "$TOTAL_MB" -ge "$MIN_RAM_MB" ]; then
        check_pass "Total RAM" "${TOTAL_MB}MB (minimum: ${MIN_RAM_MB}MB)"
    else
        check_fail "Total RAM" "${TOTAL_MB}MB — minimum ${MIN_RAM_MB}MB required"
    fi

    if [ "$AVAIL_MB" -ge 512 ]; then
        check_pass "Available RAM" "${AVAIL_MB}MB free"
    else
        check_warn "Available RAM" "${AVAIL_MB}MB free — low. Close other applications."
    fi
elif command -v sysctl >/dev/null 2>&1; then
    TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    TOTAL_MB=$((TOTAL_BYTES / 1024 / 1024))
    if [ "$TOTAL_MB" -ge "$MIN_RAM_MB" ]; then
        check_pass "Total RAM" "${TOTAL_MB}MB"
    else
        check_fail "Total RAM" "${TOTAL_MB}MB — minimum ${MIN_RAM_MB}MB"
    fi
fi

# Disk
DISK_AVAIL_KB=$(df -k "${HOME}" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$DISK_AVAIL_KB" ]; then
    DISK_AVAIL_MB=$((DISK_AVAIL_KB / 1024))
    if [ "$DISK_AVAIL_MB" -ge "$MIN_DISK_MB" ]; then
        check_pass "Disk Space" "${DISK_AVAIL_MB}MB free (minimum: ${MIN_DISK_MB}MB)"
    else
        check_fail "Disk Space" "${DISK_AVAIL_MB}MB free — need ${MIN_DISK_MB}MB"
    fi
fi

# CPU cores
CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?")
if [ "$CPUS" != "?" ]; then
    if [ "$CPUS" -ge 2 ] 2>/dev/null; then
        check_pass "CPU Cores" "$CPUS"
    else
        check_warn "CPU Cores" "$CPUS — 2+ recommended"
    fi
fi

# ══════════════════════════════════════════════════════════
# Section 5: Ports
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── Port Availability ──${NC}"

check_port() {
    local port=$1 name=$2
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | sed 's/.*users:(("//' | sed 's/".*//')
            check_warn "Port $port ($name)" "In use by $proc"
        else
            check_pass "Port $port ($name)" "Available"
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":$port" >/dev/null 2>&1; then
            check_warn "Port $port ($name)" "In use"
        else
            check_pass "Port $port ($name)" "Available"
        fi
    else
        check_skip "Port $port ($name)" "Cannot check (no ss or lsof)"
    fi
}

check_port "$GATEWAY_PORT" "Gateway HTTP"
check_port "$WS_PORT" "Gateway WebSocket"

# ══════════════════════════════════════════════════════════
# Section 6: Network
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── Network Connectivity ──${NC}"

check_url() {
    local url=$1 name=$2
    if curl -s -m 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE "^[23]"; then
        check_pass "$name" "Reachable"
    elif wget -q --spider --timeout=5 "$url" 2>/dev/null; then
        check_pass "$name" "Reachable (wget)"
    else
        check_warn "$name" "Unreachable — may need proxy config"
    fi
}

check_url "https://registry.npmjs.org" "npm Registry"
check_url "https://registry-1.docker.io/v2/" "Docker Hub"
check_url "https://api.github.com" "GitHub API"

# DNS
if nslookup registry.npmjs.org >/dev/null 2>&1 || host registry.npmjs.org >/dev/null 2>&1; then
    check_pass "DNS Resolution" "Working"
else
    check_fail "DNS Resolution" "Failed — check /etc/resolv.conf or Docker DNS settings"
fi

# ══════════════════════════════════════════════════════════
# Section 7: Container Image
# ══════════════════════════════════════════════════════════
log ""
log "${BOLD}  ── Container Image ──${NC}"

if $DOCKER_OK; then
    # Check if image is already pulled
    if docker image inspect "node:22.22.0-bookworm" >/dev/null 2>&1; then
        IMG_SIZE=$(docker image inspect "node:22.22.0-bookworm" --format '{{.Size}}' 2>/dev/null || echo 0)
        IMG_MB=$((IMG_SIZE / 1024 / 1024))
        check_pass "Base Image" "node:22.22.0-bookworm already pulled (${IMG_MB}MB)"
    elif docker image inspect "node:22-bookworm" >/dev/null 2>&1; then
        check_pass "Base Image" "node:22-bookworm available (close match)"
    else
        check_warn "Base Image" "node:22.22.0-bookworm not pulled yet — will download on first install (~350MB)"
    fi
else
    check_skip "Base Image" "Docker not available"
fi

# ══════════════════════════════════════════════════════════
# Section 8: Docker Desktop (if applicable)
# ══════════════════════════════════════════════════════════
if $DOCKER_OK; then
    log ""
    log "${BOLD}  ── Docker Context ──${NC}"

    CONTEXT="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo '?')"
    if echo "$CONTEXT" | grep -qi "desktop"; then
        check_pass "Docker Desktop" "Detected: $CONTEXT"
    elif echo "$CONTEXT" | grep -qi "docker engine"; then
        check_pass "Docker Engine" "Standalone: $CONTEXT"
    else
        check_pass "Docker Runtime" "$CONTEXT"
    fi

    # Rootless check
    ROOTLESS="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null || echo '')"
    if echo "$ROOTLESS" | grep -q "rootless"; then
        check_warn "Rootless Mode" "Detected — volume permissions may differ. See COMPATIBILITY.md."
    fi
fi

# ══════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════

TOTAL=$((PASS + WARN + FAIL))

if $JSON_MODE; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"platform\": \"$PLATFORM\","
    echo "  \"arch\": \"$ARCH\","
    echo "  \"docker_version\": \"$DOCKER_VER\","
    echo "  \"compose_version\": \"$COMPOSE_VER\","
    echo "  \"passed\": $PASS,"
    echo "  \"warnings\": $WARN,"
    echo "  \"failed\": $FAIL,"
    echo "  \"total\": $TOTAL,"
    echo "  \"compatible\": $([ $FAIL -eq 0 ] && echo true || echo false),"
    printf "  \"checks\": [\n"
    local_i=0
    for r in "${RESULTS[@]}"; do
        ((local_i++)) || true
        if [ $local_i -lt ${#RESULTS[@]} ]; then
            echo "    $r,"
        else
            echo "    $r"
        fi
    done
    echo "  ]"
    echo "}"
elif ! $QUIET_MODE; then
    echo ""
    printf "${BOLD}  ══════════════════════════════════════════════════${NC}\n"

    if [ $FAIL -eq 0 ] && [ $WARN -eq 0 ]; then
        printf "  ${GREEN}🎉 All checks passed! System is fully compatible.${NC}\n"
    elif [ $FAIL -eq 0 ]; then
        printf "  ${YELLOW}⚠️  Compatible with warnings. Review items above.${NC}\n"
    else
        printf "  ${RED}❌ ${FAIL} critical issue(s) found. Fix before installing.${NC}\n"
    fi

    echo ""
    printf "  Passed: ${GREEN}${PASS}${NC}  Warnings: ${YELLOW}${WARN}${NC}  Failed: ${RED}${FAIL}${NC}  Total: ${TOTAL}\n"
    printf "${BOLD}  ══════════════════════════════════════════════════${NC}\n"

    # Recommendations
    if [ $FAIL -gt 0 ]; then
        echo ""
        printf "  ${CYAN}See docs/COMPATIBILITY.md for detailed requirements and fixes.${NC}\n"
        printf "  ${CYAN}Run with --fix to attempt automatic repairs.${NC}\n"
    fi
    echo ""
fi

# Exit code
if [ $FAIL -gt 0 ]; then
    exit 1
elif [ $WARN -gt 0 ]; then
    exit 2
else
    exit 0
fi
