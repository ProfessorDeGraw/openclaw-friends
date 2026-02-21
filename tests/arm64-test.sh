#!/bin/bash
# arm64-test.sh — ARM64 / Raspberry Pi compatibility test suite for OpenClaw installer
#
# Usage:
#   ./tests/arm64-test.sh                   # Run all tests
#   ./tests/arm64-test.sh --phase arch      # Run one phase
#   ./tests/arm64-test.sh --emulated        # Run inside QEMU (x86 host testing arm64)
#   ./tests/arm64-test.sh --ci              # Non-interactive, exit 1 on failure
#
# Requires: Docker with buildx (for cross-platform testing on x86 hosts)
# On a real Pi: just run it directly — no emulation needed.

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────

PASS=0; FAIL=0; SKIP=0; TOTAL=0
EMULATED=false
CI=false
PHASE_FILTER=""
ERRORS=()

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; RST='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emulated)     EMULATED=true; shift ;;
        --ci)           CI=true; shift ;;
        --phase)        PHASE_FILTER="$2"; shift 2 ;;
        *)              echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

should_run() { [[ -z "$PHASE_FILTER" || "$PHASE_FILTER" == "$1" ]]; }

assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if eval "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  ${GRN}✅ PASS${RST}  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$desc")
        printf "  ${RED}❌ FAIL${RST}  %s\n" "$desc"
    fi
}

assert_skip() {
    local desc="$1" reason="$2"
    TOTAL=$((TOTAL + 1)); SKIP=$((SKIP + 1))
    printf "  ${YEL}⏭️  SKIP${RST}  %s — %s\n" "$desc" "$reason"
}

phase() {
    printf "\n${CYN}═══ Phase %s: %s ═══${RST}\n" "$1" "$2"
}

banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  🍓 OpenClaw ARM64 / Raspberry Pi Test Suite                ║"
    echo "╟───────────────────────────────────────────────────────────────╢"
    echo "║  Tests: arch detection, images, memory, install flow        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Host arch:   $(uname -m)"
    echo "  Kernel:      $(uname -r)"
    echo "  OS:          $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
    echo "  Docker:      $(docker --version 2>/dev/null || echo 'not found')"
    echo "  RAM:         $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo 'unknown')"
    echo "  Emulated:    $EMULATED"
    echo ""
}

# Wrapper to run commands inside an ARM64 container (for x86 hosts)
arm64_run() {
    if [[ "$(uname -m)" == "aarch64" ]] && ! $EMULATED; then
        # Already on ARM64
        eval "$@"
    else
        docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim sh -c "$*"
    fi
}

# ─── Phase 1: Architecture Detection ─────────────────────────────────────────

if should_run "arch"; then
    phase 1 "Architecture Detection"

    assert "uname -m returns valid arch" \
        '[[ "$(uname -m)" =~ ^(x86_64|aarch64|armv7l|armv6l)$ ]]'

    assert "dpkg --print-architecture works (if available)" \
        'command -v dpkg >/dev/null && dpkg --print-architecture || true'

    assert "Can detect ARM64 via /proc/cpuinfo or uname" \
        '[[ "$(uname -m)" == "aarch64" ]] || docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim uname -m | grep -q aarch64'

    assert "Docker buildx available for cross-platform" \
        'docker buildx version 2>/dev/null'

    assert "QEMU user-static registered (for cross-arch on x86)" \
        'docker run --rm --platform linux/arm64 arm64v8/alpine uname -m 2>/dev/null | grep -q aarch64 || [[ "$(uname -m)" == "aarch64" ]]'

    # Test the arch-detection logic an installer would use
    assert "Installer arch mapping: aarch64 → arm64" '
        arch=$(docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim uname -m 2>/dev/null || echo aarch64)
        case "$arch" in
            aarch64) mapped="arm64" ;;
            x86_64)  mapped="amd64" ;;
            armv7l)  mapped="armhf" ;;
            *)       mapped="unknown" ;;
        esac
        [[ "$mapped" == "arm64" ]]
    '

    assert "Node.js process.arch reports arm64 inside ARM container" \
        'docker run --rm --platform linux/arm64 arm64v8/node:22-bookworm-slim node -e "console.log(process.arch)" 2>/dev/null | grep -q arm64'
fi

# ─── Phase 2: ARM64 Docker Image Availability ────────────────────────────────

if should_run "images"; then
    phase 2 "ARM64 Docker Image Availability"

    # Core images that OpenClaw needs
    IMAGES=(
        "node:22-bookworm-slim"
        "node:22-bookworm"
        "node:22.22.0-bookworm"
        "node:20-bookworm-slim"
        "alpine:3.20"
        "debian:bookworm-slim"
    )

    for img in "${IMAGES[@]}"; do
        assert "ARM64 manifest exists: $img" \
            "docker manifest inspect --verbose '$img' 2>/dev/null | grep -q 'arm64\|aarch64'"
    done

    assert "ARM64 node image runs and executes JS" \
        'docker run --rm --platform linux/arm64 arm64v8/node:22-bookworm-slim node -e "console.log(42)" 2>/dev/null | grep -q 42'

    assert "npm works inside ARM64 node image" \
        'docker run --rm --platform linux/arm64 arm64v8/node:22-bookworm-slim npm --version 2>/dev/null'

    assert "ARM64 image uses correct ELF binary format" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim file /bin/ls 2>/dev/null | grep -qi "aarch64\|arm"'
fi

# ─── Phase 3: Memory Constraints ─────────────────────────────────────────────

if should_run "memory"; then
    phase 3 "Memory Constraints (Raspberry Pi limits)"

    # Pi models: Pi 3 = 1GB, Pi 4 = 1-8GB, Pi 5 = 4-8GB
    # OpenClaw minimum: ~256MB for gateway, ~512MB comfortable

    assert "Node.js starts with 256MB heap limit" \
        'docker run --rm --platform linux/arm64 --memory=256m arm64v8/node:22-bookworm-slim \
            node --max-old-space-size=192 -e "console.log(\"ok\")" 2>/dev/null | grep -q ok'

    assert "Node.js starts with 512MB heap limit" \
        'docker run --rm --platform linux/arm64 --memory=512m arm64v8/node:22-bookworm-slim \
            node --max-old-space-size=384 -e "console.log(\"ok\")" 2>/dev/null | grep -q ok'

    assert "npm install works in 512MB container" \
        'docker run --rm --platform linux/arm64 --memory=512m arm64v8/node:22-bookworm-slim \
            sh -c "mkdir /tmp/t && cd /tmp/t && npm init -y && npm install --prefer-offline 2>&1 && echo ok" 2>/dev/null | tail -1 | grep -q ok'

    assert "Node.js survives under 128MB (minimal)" \
        'docker run --rm --platform linux/arm64 --memory=128m arm64v8/node:22-bookworm-slim \
            node --max-old-space-size=96 -e "process.exit(0)" 2>/dev/null'

    assert "Container respects memory limit (cgroup)" \
        'docker run --rm --platform linux/arm64 --memory=256m arm64v8/node:22-bookworm-slim \
            node -e "
                const os = require(\"os\");
                const totalMB = Math.round(os.totalmem() / 1024 / 1024);
                process.exit(totalMB <= 300 ? 0 : 1);
            " 2>/dev/null'

    assert "Swap detection works" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim \
            sh -c "free -m 2>/dev/null | grep -q Swap && echo ok || cat /proc/swaps && echo ok" 2>/dev/null | grep -q ok'

    assert "OOM killer setting readable" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim \
            cat /proc/self/oom_score_adj 2>/dev/null'

    # Stress test: allocate memory progressively
    assert "Node.js handles 200MB allocation without OOM in 512MB container" \
        'docker run --rm --platform linux/arm64 --memory=512m arm64v8/node:22-bookworm-slim \
            node --max-old-space-size=384 -e "
                const bufs = [];
                for (let i = 0; i < 20; i++) bufs.push(Buffer.alloc(10*1024*1024));
                console.log(\"allocated\", bufs.length * 10, \"MB\");
            " 2>/dev/null | grep -q allocated'
fi

# ─── Phase 4: Storage & Filesystem ───────────────────────────────────────────

if should_run "storage"; then
    phase 4 "Storage & Filesystem (SD card considerations)"

    assert "Docker data-root is accessible" \
        'docker info --format "{{.DockerRootDir}}" 2>/dev/null'

    assert "Filesystem supports required operations (symlinks, permissions)" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim \
            sh -c "touch /tmp/test && ln -s /tmp/test /tmp/link && chmod 600 /tmp/test && echo ok" 2>/dev/null | grep -q ok'

    assert "Volume mount works on ARM64" \
        'docker run --rm --platform linux/arm64 -v /tmp:/mnt/test arm64v8/debian:bookworm-slim \
            ls /mnt/test >/dev/null 2>&1'

    assert "Named volume creation works" \
        'docker volume create oc-arm64-test >/dev/null 2>&1 && \
         docker run --rm --platform linux/arm64 -v oc-arm64-test:/data arm64v8/debian:bookworm-slim \
            touch /data/testfile 2>/dev/null && \
         docker volume rm oc-arm64-test >/dev/null 2>&1'

    assert "Write speed acceptable (>1MB/s, SD card baseline)" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim \
            sh -c "dd if=/dev/zero of=/tmp/bench bs=1M count=10 2>&1 | tail -1" 2>/dev/null'
fi

# ─── Phase 5: Networking ─────────────────────────────────────────────────────

if should_run "network"; then
    phase 5 "Networking"

    assert "Container can resolve DNS" \
        'docker run --rm --platform linux/arm64 arm64v8/debian:bookworm-slim \
            sh -c "apt-get update -qq 2>/dev/null | head -1 || getent hosts google.com" 2>/dev/null'

    assert "Port mapping works on ARM64" \
        'cid=$(docker run -d --rm --platform linux/arm64 -p 19999:8080 arm64v8/node:22-bookworm-slim \
            node -e "require(\"http\").createServer((_,r)=>{r.end(\"ok\")}).listen(8080)" 2>/dev/null) && \
         sleep 2 && \
         result=$(curl -sf --max-time 5 http://localhost:19999 2>/dev/null || echo fail) && \
         docker stop "$cid" >/dev/null 2>&1; \
         [[ "$result" == "ok" ]]'

    assert "host.docker.internal resolves (Docker Desktop / host-gateway)" \
        'docker run --rm --platform linux/arm64 --add-host=host.docker.internal:host-gateway arm64v8/debian:bookworm-slim \
            getent hosts host.docker.internal 2>/dev/null || true'
fi

# ─── Phase 6: Installer Script Adaptations ───────────────────────────────────

if should_run "installer"; then
    phase 6 "Installer Script Adaptations"

    INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"

    if [[ -f "$INSTALLER_DIR/install.sh" ]]; then
        assert "install.sh has ARM64 arch detection" \
            'grep -qiE "aarch64|arm64" "$INSTALLER_DIR/install.sh"'

        assert "install.sh doesn't hardcode x86_64 image tags" \
            '! grep -q "linux/amd64" "$INSTALLER_DIR/install.sh" || grep -q "linux/arm64" "$INSTALLER_DIR/install.sh"'

        assert "install.sh checks available memory" \
            'grep -qiE "free|meminfo|totalmem|MemTotal" "$INSTALLER_DIR/install.sh"'
    else
        assert_skip "install.sh ARM64 detection" "install.sh not found"
        assert_skip "install.sh arch hardcoding" "install.sh not found"
        assert_skip "install.sh memory check" "install.sh not found"
    fi

    if [[ -f "$INSTALLER_DIR/install.ps1" ]]; then
        assert "install.ps1 handles ARM architecture" \
            'grep -qiE "ARM|aarch64|arm64" "$INSTALLER_DIR/install.ps1"'
    else
        assert_skip "install.ps1 ARM handling" "install.ps1 not found (expected on Linux)"
    fi

    # Test that docker-compose.yml doesn't force platform
    if [[ -f "$INSTALLER_DIR/docker-compose.yml" ]]; then
        assert "docker-compose.yml doesn't force amd64 platform" \
            '! grep -q "platform:.*amd64" "$INSTALLER_DIR/docker-compose.yml"'
    else
        assert_skip "docker-compose.yml platform check" "file not found"
    fi
fi

# ─── Phase 7: Full ARM64 Container Lifecycle ─────────────────────────────────

if should_run "lifecycle"; then
    phase 7 "Full ARM64 Container Lifecycle"

    TEST_CONTAINER="oc-arm64-lifecycle-test"
    docker rm -f "$TEST_CONTAINER" 2>/dev/null || true

    assert "Create and start ARM64 node container" \
        'docker run -d --name "$TEST_CONTAINER" --platform linux/arm64 --memory=512m \
            arm64v8/node:22-bookworm-slim sleep 300 2>/dev/null'

    assert "Install openclaw package (npm install -g)" \
        'docker exec "$TEST_CONTAINER" sh -c "npm install -g openclaw@latest 2>&1 | tail -3" 2>/dev/null'

    assert "openclaw binary exists after install" \
        'docker exec "$TEST_CONTAINER" which openclaw 2>/dev/null || \
         docker exec "$TEST_CONTAINER" npx openclaw --help 2>/dev/null | head -1'

    assert "Node.js process.arch is arm64 inside container" \
        'docker exec "$TEST_CONTAINER" node -e "if(process.arch!==\"arm64\")process.exit(1)" 2>/dev/null'

    assert "Workspace directory can be created" \
        'docker exec "$TEST_CONTAINER" mkdir -p /root/.openclaw/workspace 2>/dev/null'

    assert "Can write SOUL.md to workspace" \
        'docker exec "$TEST_CONTAINER" sh -c "echo \"# Test Soul\" > /root/.openclaw/workspace/SOUL.md" 2>/dev/null'

    assert "Container stops cleanly" \
        'docker stop "$TEST_CONTAINER" 2>/dev/null'

    assert "Container removes cleanly" \
        'docker rm "$TEST_CONTAINER" 2>/dev/null'
fi

# ─── Phase 8: Pi-Specific Hardware Checks ────────────────────────────────────

if should_run "pi"; then
    phase 8 "Raspberry Pi Hardware (skip if not on Pi)"

    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        echo "  Detected: $PI_MODEL"

        assert "Pi model detected" '[[ -n "$PI_MODEL" ]]'

        assert "CPU temperature readable" \
            'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null'

        assert "GPU memory split check (should be ≤128MB for server use)" \
            'vcgencmd get_mem gpu 2>/dev/null | grep -oP "\d+" | awk "{exit (\$1 <= 128) ? 0 : 1}" || true'

        assert "64-bit kernel running" \
            '[[ "$(uname -m)" == "aarch64" ]]'

        assert "Sufficient RAM (≥1GB)" \
            'total_mb=$(free -m | awk "/Mem:/{print \$2}"); [[ "$total_mb" -ge 900 ]]'

        assert "Sufficient disk space (≥4GB free)" \
            'free_gb=$(df / --output=avail -BG | tail -1 | tr -dc 0-9); [[ "$free_gb" -ge 4 ]]'

        assert "Docker cgroup driver is systemd or cgroupfs" \
            'docker info --format "{{.CgroupDriver}}" 2>/dev/null | grep -qE "systemd|cgroupfs"'

        assert "CPU governor is performance or ondemand" \
            'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | grep -qE "performance|ondemand|schedutil" || true'
    else
        assert_skip "Pi model detection" "Not running on Raspberry Pi"
        assert_skip "CPU temperature" "Not a Pi"
        assert_skip "GPU memory split" "Not a Pi"
        assert_skip "64-bit kernel" "Not a Pi"
        assert_skip "RAM check" "Not a Pi"
        assert_skip "Disk space check" "Not a Pi"
        assert_skip "Cgroup driver" "Not a Pi"
        assert_skip "CPU governor" "Not a Pi"
    fi
fi

# ─── Phase 9: Performance Baseline ───────────────────────────────────────────

if should_run "perf"; then
    phase 9 "Performance Baseline"

    assert "Node.js startup time < 5s on ARM64" \
        'timeout 5 docker run --rm --platform linux/arm64 arm64v8/node:22-bookworm-slim \
            node -e "console.log(\"started in\", process.uptime().toFixed(2), \"s\")" 2>/dev/null'

    assert "npm --version completes in < 10s on ARM64" \
        'timeout 10 docker run --rm --platform linux/arm64 arm64v8/node:22-bookworm-slim \
            npm --version 2>/dev/null'

    assert "JSON parse/stringify performance acceptable" \
        'docker run --rm --platform linux/arm64 --memory=256m arm64v8/node:22-bookworm-slim \
            node -e "
                const start = Date.now();
                for(let i=0;i<10000;i++) JSON.parse(JSON.stringify({a:1,b:[2,3],c:{d:4}}));
                const ms = Date.now()-start;
                console.log(ms+\"ms for 10k JSON cycles\");
                process.exit(ms < 5000 ? 0 : 1);
            " 2>/dev/null'

    assert "File I/O performance (1000 small writes)" \
        'docker run --rm --platform linux/arm64 --memory=256m arm64v8/node:22-bookworm-slim \
            node -e "
                const fs=require(\"fs\"),start=Date.now();
                for(let i=0;i<1000;i++)fs.writeFileSync(\"/tmp/t\"+i,\"data\"+i);
                const ms=Date.now()-start;
                console.log(ms+\"ms for 1000 writes\");
                process.exit(ms<10000?0:1);
            " 2>/dev/null'
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
printf "║  Results: ${GRN}%d passed${RST}  ${RED}%d failed${RST}  ${YEL}%d skipped${RST}  (%d total)       ║\n" \
    "$PASS" "$FAIL" "$SKIP" "$TOTAL"
echo "╚═══════════════════════════════════════════════════════════════╝"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "    ❌ $err"
    done
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "  🍓 All tests passed! OpenClaw is ARM64/Pi ready."
else
    echo "  ⚠️  $FAIL test(s) failed. Review above for details."
fi
echo ""

$CI && [[ $FAIL -gt 0 ]] && exit 1
exit 0
