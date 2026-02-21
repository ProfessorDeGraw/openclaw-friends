#!/bin/bash
# regression-suite.sh — Installer regression tests across Docker versions
# Uses Docker-in-Docker (DinD) to validate install.sh against multiple Docker releases.
#
# Usage:
#   ./tests/regression-suite.sh [--token TOKEN] [--versions "25.0 24.0"] [--keep] [--parallel N]
#
# Requirements: Docker running on the host. ~2GB disk per version tested.

set -o pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

DOCKER_VERSIONS=("25.0" "24.0" "23.0" "20.10")
TEST_TOKEN="${OPENCLAW_TEST_TOKEN:-}"
KEEP_CONTAINERS=false
PARALLEL=1
NETWORK_NAME="openclaw-regression-net"
CONTAINER_PREFIX="oc-regression"
INSTALLER_REPO="https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.sh"
TIMEOUT_DIND_READY=60
TIMEOUT_INSTALL=300
TIMEOUT_GATEWAY=120

# Script directory (for locating install.sh locally if available)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Parse Args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)      TEST_TOKEN="$2"; shift 2 ;;
        --versions)   IFS=' ' read -ra DOCKER_VERSIONS <<< "$2"; shift 2 ;;
        --keep)       KEEP_CONTAINERS=true; shift ;;
        --parallel)   PARALLEL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--token TOKEN] [--versions \"25.0 24.0\"] [--keep] [--parallel N]"
            echo ""
            echo "  --token      Copilot token (or set OPENCLAW_TEST_TOKEN)"
            echo "  --versions   Space-separated Docker versions to test (default: 25.0 24.0 23.0 20.10)"
            echo "  --keep       Don't remove DinD containers after tests"
            echo "  --parallel   Run N tests concurrently (default: 1)"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ─── Output Helpers ───────────────────────────────────────────────────────────

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[regression]${RESET} $*"; }
log_ok()  { echo -e "  ${GREEN}✅ $*${RESET}"; }
log_err() { echo -e "  ${RED}❌ $*${RESET}"; }
log_warn(){ echo -e "  ${YELLOW}⚠️  $*${RESET}"; }
log_dim() { echo -e "  ${DIM}$*${RESET}"; }

# ─── Globals ──────────────────────────────────────────────────────────────────

declare -A RESULT_STATUS     # version -> pass|fail|skip|error
declare -A RESULT_DETAIL     # version -> detail string
declare -A RESULT_TESTS      # version -> "passed/total"
declare -A RESULT_DURATION   # version -> seconds
TOTAL_START=$(date +%s)

# ─── Pre-Flight ───────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}│  🐬 OpenClaw Installer Regression Suite          │${RESET}"
echo -e "${BOLD}│     $(date '+%Y-%m-%d %H:%M:%S')                           │${RESET}"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${RESET}"
echo ""

# Check host Docker
if ! docker info &>/dev/null; then
    echo -e "${RED}Docker is not running on the host. Cannot proceed.${RESET}"
    exit 1
fi
HOST_DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
log "Host Docker: $HOST_DOCKER"
log "Testing versions: ${DOCKER_VERSIONS[*]}"
log "Parallel: $PARALLEL"
log "Token: ${TEST_TOKEN:+provided}${TEST_TOKEN:-NOT SET (dry-run mode)}"
echo ""

# Create isolated network
docker network create "$NETWORK_NAME" &>/dev/null || true

# ─── Test Runner for a Single Docker Version ──────────────────────────────────

run_version_test() {
    local DVER="$1"
    local CNAME="${CONTAINER_PREFIX}-${DVER//\./-}"
    local LOG_FILE="/tmp/oc-regression-${DVER}.log"
    local VTESTS_PASS=0
    local VTESTS_TOTAL=0
    local VSTART=$(date +%s)
    local DETAILS=""

    vpass() { VTESTS_PASS=$((VTESTS_PASS + 1)); VTESTS_TOTAL=$((VTESTS_TOTAL + 1)); DETAILS+="  ✅ $1\n"; }
    vfail() { VTESTS_TOTAL=$((VTESTS_TOTAL + 1)); DETAILS+="  ❌ $1 — $2\n"; }
    vskip() { VTESTS_TOTAL=$((VTESTS_TOTAL + 1)); DETAILS+="  ⏭️  $1 — $2\n"; }

    log "═══ Docker $DVER ═══"

    # ── T1: Pull DinD image ──
    local DIND_IMAGE="docker:${DVER}-dind"
    log_dim "Pulling $DIND_IMAGE..."
    if docker pull "$DIND_IMAGE" > "$LOG_FILE" 2>&1; then
        vpass "T1 Pull DinD image ($DIND_IMAGE)"
    else
        vfail "T1 Pull DinD image" "docker pull failed"
        log_err "Cannot pull $DIND_IMAGE — skipping this version"
        RESULT_STATUS[$DVER]="error"
        RESULT_DETAIL[$DVER]="DinD image not available"
        RESULT_TESTS[$DVER]="$VTESTS_PASS/$VTESTS_TOTAL"
        RESULT_DURATION[$DVER]=$(( $(date +%s) - VSTART ))
        return
    fi

    # ── T2: Start DinD container ──
    docker rm -f "$CNAME" &>/dev/null || true
    if docker run -d \
        --name "$CNAME" \
        --privileged \
        --network "$NETWORK_NAME" \
        -e DOCKER_TLS_CERTDIR="" \
        "$DIND_IMAGE" > /dev/null 2>&1; then
        vpass "T2 Start DinD container ($CNAME)"
    else
        vfail "T2 Start DinD container" "docker run failed"
        RESULT_STATUS[$DVER]="error"
        RESULT_DETAIL[$DVER]="DinD container failed to start"
        RESULT_TESTS[$DVER]="$VTESTS_PASS/$VTESTS_TOTAL"
        RESULT_DURATION[$DVER]=$(( $(date +%s) - VSTART ))
        return
    fi

    # ── T3: Wait for DinD daemon ready ──
    log_dim "Waiting for Docker daemon inside DinD..."
    local READY=false
    for i in $(seq 1 $((TIMEOUT_DIND_READY / 3))); do
        if docker exec "$CNAME" docker info &>/dev/null; then
            READY=true
            break
        fi
        sleep 3
    done
    if $READY; then
        local INNER_VER
        INNER_VER=$(docker exec "$CNAME" docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
        vpass "T3 DinD daemon ready (Docker $INNER_VER)"
    else
        vfail "T3 DinD daemon ready" "Not responding after ${TIMEOUT_DIND_READY}s"
        RESULT_STATUS[$DVER]="error"
        RESULT_DETAIL[$DVER]="DinD daemon never started"
        RESULT_TESTS[$DVER]="$VTESTS_PASS/$VTESTS_TOTAL"
        RESULT_DURATION[$DVER]=$(( $(date +%s) - VSTART ))
        return
    fi

    # ── T4: Docker Compose available inside DinD ──
    if docker exec "$CNAME" docker compose version &>/dev/null; then
        local COMPOSE_VER
        COMPOSE_VER=$(docker exec "$CNAME" docker compose version --short 2>/dev/null || echo "?")
        vpass "T4 Docker Compose available ($COMPOSE_VER)"
    else
        # Older DinD may not have compose v2; try installing
        log_dim "Compose not found, attempting install..."
        docker exec "$CNAME" sh -c '
            mkdir -p /usr/local/lib/docker/cli-plugins &&
            wget -qO /usr/local/lib/docker/cli-plugins/docker-compose \
                "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" &&
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        ' >> "$LOG_FILE" 2>&1

        if docker exec "$CNAME" docker compose version &>/dev/null; then
            vpass "T4 Docker Compose installed manually"
        else
            vfail "T4 Docker Compose" "Not available and manual install failed"
        fi
    fi

    # ── T5: Install prerequisites inside DinD ──
    log_dim "Installing bash + curl inside DinD..."
    if docker exec "$CNAME" sh -c 'apk add --no-cache bash curl jq nodejs npm > /dev/null 2>&1 || apt-get update && apt-get install -y bash curl jq > /dev/null 2>&1' >> "$LOG_FILE" 2>&1; then
        vpass "T5 Prerequisites installed (bash, curl)"
    else
        # DinD alpine images usually have apk
        vfail "T5 Prerequisites" "Could not install bash/curl"
    fi

    # ── T6: Download installer ──
    if docker exec "$CNAME" sh -c "curl -sf -o /tmp/install.sh '$INSTALLER_REPO'" >> "$LOG_FILE" 2>&1; then
        local INSTALLER_SIZE
        INSTALLER_SIZE=$(docker exec "$CNAME" wc -c < /tmp/install.sh 2>/dev/null | tr -d ' ')
        vpass "T6 Downloaded installer (${INSTALLER_SIZE} bytes)"
    elif [[ -f "$SCRIPT_DIR/install.sh" ]]; then
        docker cp "$SCRIPT_DIR/install.sh" "$CNAME:/tmp/install.sh" >> "$LOG_FILE" 2>&1
        vpass "T6 Copied local installer"
    else
        vfail "T6 Download installer" "Neither remote nor local installer available"
    fi

    # ── T7: Installer syntax check ──
    if docker exec "$CNAME" bash -n /tmp/install.sh &>/dev/null; then
        vpass "T7 Installer syntax valid"
    else
        vfail "T7 Installer syntax" "bash -n reports errors"
    fi

    # ── T8-T14: Run installer (requires token) ──
    if [[ -z "$TEST_TOKEN" ]]; then
        vskip "T8 Run installer" "No token provided (dry-run)"
        vskip "T9 Installer exit code" "Skipped"
        vskip "T10 Config files created" "Skipped"
        vskip "T11 docker-compose.yml created" "Skipped"
        vskip "T12 Container started" "Skipped"
        vskip "T13 Gateway responds" "Skipped"
        vskip "T14 No error output" "Skipped"
    else
        log_dim "Running installer inside DinD (timeout: ${TIMEOUT_INSTALL}s)..."

        local INSTALL_EXIT
        # Run installer inside the DinD container
        timeout "$TIMEOUT_INSTALL" docker exec -e HOME=/root "$CNAME" \
            bash /tmp/install.sh "$TEST_TOKEN" > "$LOG_FILE.install" 2>&1
        INSTALL_EXIT=$?

        # T8 — Installer ran
        if [[ $INSTALL_EXIT -eq 0 ]]; then
            vpass "T8 Installer completed (exit 0)"
        elif [[ $INSTALL_EXIT -eq 124 ]]; then
            vfail "T8 Installer completed" "Timed out after ${TIMEOUT_INSTALL}s"
        else
            vfail "T8 Installer completed" "Exit code: $INSTALL_EXIT"
        fi

        # T9 — No fatal errors in output
        local ERRORS
        ERRORS=$(grep -ci "error\|fatal\|panic\|traceback\|unhandled" "$LOG_FILE.install" 2>/dev/null || echo "0")
        if [[ "$ERRORS" -eq 0 ]]; then
            vpass "T9 No errors in installer output"
        else
            vfail "T9 Errors in output" "$ERRORS error-like lines"
            grep -i "error\|fatal\|panic" "$LOG_FILE.install" | head -3 | while read -r line; do
                log_dim "  $line"
            done
        fi

        # T10 — Config files
        local CONFIGS_OK=true
        for f in openclaw.json auth-profiles.json; do
            if ! docker exec "$CNAME" test -f "/root/openclaw-friend/config/$f" 2>/dev/null; then
                vfail "T10 Config: $f" "Not found"
                CONFIGS_OK=false
            fi
        done
        if $CONFIGS_OK; then
            vpass "T10 Config files created"
        fi

        # T11 — docker-compose.yml
        if docker exec "$CNAME" test -f /root/openclaw-friend/docker-compose.yml 2>/dev/null; then
            vpass "T11 docker-compose.yml created"
        else
            vfail "T11 docker-compose.yml" "Not found"
        fi

        # T12 — Container started inside DinD
        log_dim "Checking for running container inside DinD..."
        local INNER_CONTAINER
        INNER_CONTAINER=$(docker exec "$CNAME" docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 "openclaw" || echo "")
        if [[ -n "$INNER_CONTAINER" ]]; then
            vpass "T12 Container running inside DinD ($INNER_CONTAINER)"
        else
            # May still be starting — wait a bit
            sleep 15
            INNER_CONTAINER=$(docker exec "$CNAME" docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 "openclaw" || echo "")
            if [[ -n "$INNER_CONTAINER" ]]; then
                vpass "T12 Container running inside DinD ($INNER_CONTAINER) (delayed start)"
            else
                vfail "T12 Container inside DinD" "No openclaw container found"
                docker exec "$CNAME" docker ps -a 2>/dev/null | head -5 | while read -r line; do
                    log_dim "  $line"
                done
            fi
        fi

        # T13 — Gateway HTTP inside DinD
        if [[ -n "$INNER_CONTAINER" ]]; then
            log_dim "Waiting for gateway inside DinD (up to ${TIMEOUT_GATEWAY}s)..."
            local GW_READY=false
            for i in $(seq 1 $((TIMEOUT_GATEWAY / 5))); do
                if docker exec "$CNAME" sh -c 'curl -sf --max-time 3 http://localhost:18800/ > /dev/null 2>&1'; then
                    GW_READY=true
                    break
                fi
                sleep 5
            done
            if $GW_READY; then
                vpass "T13 Gateway responds inside DinD"
            else
                vfail "T13 Gateway responds" "No HTTP response after ${TIMEOUT_GATEWAY}s"
                log_dim "Inner container logs:"
                docker exec "$CNAME" docker logs --tail 10 "$INNER_CONTAINER" 2>&1 | head -10 | while read -r line; do
                    log_dim "  $line"
                done
            fi
        else
            vskip "T13 Gateway responds" "No container to test"
        fi

        # T14 — Idempotency (run installer again)
        log_dim "Running installer a second time (idempotency)..."
        local IDEM_EXIT
        timeout "$TIMEOUT_INSTALL" docker exec -e HOME=/root "$CNAME" \
            bash /tmp/install.sh "$TEST_TOKEN" > "$LOG_FILE.idem" 2>&1
        IDEM_EXIT=$?
        if [[ $IDEM_EXIT -eq 0 ]]; then
            vpass "T14 Idempotency: second run succeeded (exit 0)"
        else
            vfail "T14 Idempotency" "Second run exit code: $IDEM_EXIT"
        fi
    fi

    # ── T15: DinD resource usage ──
    local MEM_USAGE
    MEM_USAGE=$(docker stats --no-stream --format '{{.MemUsage}}' "$CNAME" 2>/dev/null | awk -F'/' '{print $1}' | tr -d ' ')
    vpass "T15 DinD resource usage (memory: ${MEM_USAGE:-unknown})"

    # ── Finalize ──
    local VEND=$(date +%s)
    local VDURATION=$((VEND - VSTART))
    RESULT_DURATION[$DVER]=$VDURATION
    RESULT_TESTS[$DVER]="$VTESTS_PASS/$VTESTS_TOTAL"
    RESULT_DETAIL[$DVER]="$DETAILS"

    if [[ $VTESTS_PASS -eq $VTESTS_TOTAL ]]; then
        RESULT_STATUS[$DVER]="pass"
    elif [[ $VTESTS_PASS -eq 0 ]]; then
        RESULT_STATUS[$DVER]="fail"
    else
        RESULT_STATUS[$DVER]="partial"
    fi

    log "Docker $DVER: $VTESTS_PASS/$VTESTS_TOTAL passed (${VDURATION}s)"

    # Cleanup
    if ! $KEEP_CONTAINERS; then
        docker rm -f "$CNAME" &>/dev/null
        rm -f "$LOG_FILE" "$LOG_FILE.install" "$LOG_FILE.idem"
    fi
}

# ─── Run Tests ────────────────────────────────────────────────────────────────

if [[ "$PARALLEL" -le 1 ]]; then
    for ver in "${DOCKER_VERSIONS[@]}"; do
        run_version_test "$ver"
        echo ""
    done
else
    # Parallel execution
    PIDS=()
    for ver in "${DOCKER_VERSIONS[@]}"; do
        run_version_test "$ver" &
        PIDS+=($!)
        # Throttle to $PARALLEL concurrent
        while [[ ${#PIDS[@]} -ge $PARALLEL ]]; do
            NEW_PIDS=()
            for pid in "${PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    NEW_PIDS+=("$pid")
                fi
            done
            PIDS=("${NEW_PIDS[@]}")
            sleep 2
        done
    done
    # Wait for remaining
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null
    done
fi

# ─── Cleanup Network ─────────────────────────────────────────────────────────

if ! $KEEP_CONTAINERS; then
    docker network rm "$NETWORK_NAME" &>/dev/null || true
fi

# ─── Summary Report ──────────────────────────────────────────────────────────

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

echo ""
echo -e "${BOLD}┌────────────────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}│  📋 Regression Suite Results                                       │${RESET}"
echo -e "${BOLD}├──────────────┬────────┬────────────┬──────────┬─────────────────────┤${RESET}"
printf  "${BOLD}│ %-12s │ %-6s │ %-10s │ %-8s │ %-19s │${RESET}\n" \
        "Docker Ver" "Status" "Tests" "Duration" "Notes"
echo -e "${BOLD}├──────────────┼────────┼────────────┼──────────┼─────────────────────┤${RESET}"

for ver in "${DOCKER_VERSIONS[@]}"; do
    local_status="${RESULT_STATUS[$ver]:-skip}"
    local_tests="${RESULT_TESTS[$ver]:-0/0}"
    local_dur="${RESULT_DURATION[$ver]:-0}"
    local_note=""

    case "$local_status" in
        pass)    STATUS_ICON="✅"; TOTAL_PASS=$((TOTAL_PASS + 1)) ;;
        partial) STATUS_ICON="⚠️ "; TOTAL_FAIL=$((TOTAL_FAIL + 1)); local_note="some failures" ;;
        fail)    STATUS_ICON="❌"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); local_note="${RESULT_DETAIL[$ver]:-}" ;;
        error)   STATUS_ICON="💥"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); local_note="${RESULT_DETAIL[$ver]:-}" ;;
        skip)    STATUS_ICON="⏭️ "; TOTAL_SKIP=$((TOTAL_SKIP + 1)); local_note="skipped" ;;
    esac

    printf "│ %-12s │ %-6s │ %-10s │ %6ss │ %-19s │\n" \
        "$ver" "$STATUS_ICON" "$local_tests" "$local_dur" "${local_note:0:19}"
done

echo -e "${BOLD}├──────────────┴────────┴────────────┴──────────┴─────────────────────┤${RESET}"
printf  "${BOLD}│  Total: %d versions  │  ✅ %d  ❌ %d  ⏭️  %d  │  %ds             │${RESET}\n" \
        "${#DOCKER_VERSIONS[@]}" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP" "$TOTAL_DURATION"
echo -e "${BOLD}└────────────────────────────────────────────────────────────────────┘${RESET}"

# Per-version detail (if any failures)
if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}── Failure Detail ──${RESET}"
    for ver in "${DOCKER_VERSIONS[@]}"; do
        local_status="${RESULT_STATUS[$ver]:-skip}"
        if [[ "$local_status" == "fail" || "$local_status" == "partial" || "$local_status" == "error" ]]; then
            echo ""
            echo -e "${RED}Docker $ver (${RESULT_TESTS[$ver]:-?}):${RESET}"
            echo -e "${RESULT_DETAIL[$ver]:-  No detail captured}"
        fi
    done
fi

# ─── Machine-Readable Report ─────────────────────────────────────────────────

REPORT_FILE="/tmp/openclaw-regression-$(date +%Y%m%d-%H%M%S).json"
{
    echo "{"
    echo "  \"suite\": \"installer-regression\","
    echo "  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"host_docker\": \"$HOST_DOCKER\","
    echo "  \"duration_seconds\": $TOTAL_DURATION,"
    echo "  \"token_provided\": $([ -n "$TEST_TOKEN" ] && echo true || echo false),"
    echo "  \"versions\": {"

    local_first=true
    for ver in "${DOCKER_VERSIONS[@]}"; do
        if $local_first; then local_first=false; else echo ","; fi
        printf "    \"%s\": {\"status\": \"%s\", \"tests\": \"%s\", \"duration\": %s}" \
            "$ver" "${RESULT_STATUS[$ver]:-skip}" "${RESULT_TESTS[$ver]:-0/0}" "${RESULT_DURATION[$ver]:-0}"
    done

    echo ""
    echo "  },"
    echo "  \"summary\": {\"pass\": $TOTAL_PASS, \"fail\": $TOTAL_FAIL, \"skip\": $TOTAL_SKIP},"
    echo "  \"success\": $([ $TOTAL_FAIL -eq 0 ] && echo true || echo false)"
    echo "}"
} > "$REPORT_FILE"

echo ""
echo -e "${DIM}Report saved: $REPORT_FILE${RESET}"

# ─── Final Status ─────────────────────────────────────────────────────────────

echo ""
if [[ $TOTAL_FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All versions passed! 🎉${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}$TOTAL_FAIL version(s) had failures.${RESET}"
    exit 1
fi
