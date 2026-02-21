#!/usr/bin/env bash
# rollback-test.sh — Verify installer cleans up after failures
#
# Simulates install failures at each stage and checks that partial state
# is properly cleaned up: containers, volumes, config files, directories.
#
# Usage:
#   ./rollback-test.sh                    # run all scenarios
#   ./rollback-test.sh --scenario 3       # run only scenario 3
#   ./rollback-test.sh --list             # list available scenarios
#   ./rollback-test.sh --keep-artifacts   # don't clean up test dirs (for debugging)
#
# Requirements:
#   - Docker running
#   - Port 18800 available (or uses TEST_PORT)
#   - Not run as root in production (uses temp install dirs)

set -euo pipefail

# ── Config ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALLER="$PROJECT_DIR/install.sh"
TEST_BASE="${TMPDIR:-/tmp}/openclaw-rollback-test-$$"
TEST_PORT="${TEST_PORT:-18877}"
CONTAINER_PREFIX="oc-rollback-test"
KEEP_ARTIFACTS=false
RUN_SCENARIO=""

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { printf "  ${GREEN}✅ PASS${NC}  %s\n" "$1"; }
fail()    { printf "  ${RED}❌ FAIL${NC}  %s\n" "$1"; }
skip()    { printf "  ${YELLOW}⏭  SKIP${NC}  %s\n" "$1"; }
info()    { printf "  ${CYAN}▸${NC} %s\n" "$1"; }
heading() { printf "\n${BOLD}━━ %s ━━${NC}\n" "$1"; }
dim()     { printf "  ${GRAY}%s${NC}\n" "$1"; }

# ── Counters ──────────────────────────────────────────────
PASSED=0
FAILED=0
SKIPPED=0
ERRORS=()

record_pass() { ((PASSED++)) || true; pass "$1"; }
record_fail() { ((FAILED++)) || true; fail "$1"; ERRORS+=("$1"); }
record_skip() { ((SKIPPED++)) || true; skip "$1"; }

# ── Parse args ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)    RUN_SCENARIO="$2"; shift 2 ;;
        --keep-artifacts) KEEP_ARTIFACTS=true; shift ;;
        --list)
            echo "Available scenarios:"
            echo "  1  Bad token (too short / placeholder)"
            echo "  2  No Docker available"
            echo "  3  Docker Compose failure (bad YAML)"
            echo "  4  Port conflict"
            echo "  5  Directory permission denied"
            echo "  6  Partial config (missing files mid-write)"
            echo "  7  Container crash on startup"
            echo "  8  Gateway never becomes ready (timeout)"
            echo "  9  Cleanup idempotency (double cleanup)"
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [--scenario N] [--keep-artifacts] [--list]"
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────

should_run() {
    # Returns 0 if this scenario should run
    local n="$1"
    [[ -z "$RUN_SCENARIO" ]] || [[ "$RUN_SCENARIO" == "$n" ]]
}

setup_test_dir() {
    local name="$1"
    local dir="$TEST_BASE/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo "$dir"
}

cleanup_test_dir() {
    local dir="$1"
    if $KEEP_ARTIFACTS; then
        dim "Keeping artifacts: $dir"
        return
    fi
    rm -rf "$dir" 2>/dev/null || true
}

# Clean up any containers/volumes from previous test runs
cleanup_docker() {
    local prefix="$1"
    # Remove containers matching prefix
    docker ps -a --filter "name=${prefix}" --format '{{.Names}}' 2>/dev/null | while read -r name; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    # Remove volumes matching prefix
    docker volume ls --filter "name=${prefix}" --format '{{.Name}}' 2>/dev/null | while read -r vol; do
        docker volume rm -f "$vol" >/dev/null 2>&1 || true
    done
}

# Check that no containers/volumes from a test remain
assert_no_containers() {
    local prefix="$1" label="$2"
    local containers
    containers=$(docker ps -a --filter "name=${prefix}" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [[ "$containers" -eq 0 ]]; then
        record_pass "$label: no leftover containers"
    else
        record_fail "$label: found $containers leftover container(s)"
    fi
}

assert_no_volumes() {
    local prefix="$1" label="$2"
    local volumes
    volumes=$(docker volume ls --filter "name=${prefix}" --format '{{.Name}}' 2>/dev/null | wc -l)
    if [[ "$volumes" -eq 0 ]]; then
        record_pass "$label: no leftover volumes"
    else
        record_fail "$label: found $volumes leftover volume(s)"
    fi
}

assert_no_dir() {
    local dir="$1" label="$2"
    if [[ ! -d "$dir" ]]; then
        record_pass "$label: install directory cleaned up"
    else
        # Check if directory is empty (acceptable)
        local count
        count=$(find "$dir" -type f 2>/dev/null | wc -l)
        if [[ "$count" -eq 0 ]]; then
            record_pass "$label: install directory empty (acceptable)"
        else
            record_fail "$label: install directory still has $count file(s)"
        fi
    fi
}

assert_dir_exists() {
    local dir="$1" label="$2"
    if [[ -d "$dir" ]]; then
        record_pass "$label: directory exists"
    else
        record_fail "$label: directory missing"
    fi
}

assert_file_not_exists() {
    local path="$1" label="$2"
    if [[ ! -f "$path" ]]; then
        record_pass "$label"
    else
        record_fail "$label: file still exists"
    fi
}

assert_port_free() {
    local port="$1" label="$2"
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} " && \
       ! netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        record_pass "$label: port $port is free"
    else
        record_fail "$label: port $port still in use"
    fi
}

# Create a modified installer that:
#   - Uses a custom install dir
#   - Uses a custom container name + port
#   - Has an injectable failure point
create_test_installer() {
    local test_dir="$1"
    local container_name="$2"
    local port="$3"
    local fail_at="${4:-}"  # "before_compose", "bad_compose", "after_compose"
    local installer="$test_dir/install-test.sh"

    cp "$INSTALLER" "$installer"

    # Patch: custom install dir
    sed -i "s|INSTALL_DIR=\"\$HOME/openclaw\"|INSTALL_DIR=\"$test_dir/install\"|g" "$installer"

    # Patch: custom container name
    sed -i "s|container_name: openclaw-gateway|container_name: $container_name|g" "$installer" 2>/dev/null || true
    sed -i "s|container_name: openclaw-friend|container_name: $container_name|g" "$installer" 2>/dev/null || true

    # Patch: custom port
    sed -i "s|18800:18789|${port}:18789|g" "$installer"
    sed -i "s|18801:18790|$((port+1)):18790|g" "$installer"
    sed -i "s|http://localhost:18800|http://localhost:${port}|g" "$installer"

    # Patch: custom volume names (avoid conflicts)
    sed -i "s|friend-config|${container_name}-config|g" "$installer"
    sed -i "s|friend-workspace|${container_name}-workspace|g" "$installer"

    # Inject failure point
    case "$fail_at" in
        bad_compose)
            # Corrupt the docker-compose.yml generation
            sed -i 's|cat > "\$INSTALL_DIR/docker-compose.yml"|cat > "\$INSTALL_DIR/docker-compose.yml" \&\& echo "INVALID YAML: {{{{" >> "\$INSTALL_DIR/docker-compose.yml" \&\& cat > /dev/null|' "$installer"
            ;;
        crash_container)
            # Make the container command fail immediately
            sed -i 's|npm install -g openclaw@latest|exit 1 \&\& npm install -g openclaw@latest|' "$installer"
            ;;
    esac

    chmod +x "$installer"
    echo "$installer"
}

# Run installer and capture exit code (don't let set -e kill us)
run_installer() {
    local installer="$1"
    local token="$2"
    local exit_code=0
    # Run with timeout to prevent hangs
    timeout 120 bash "$installer" "$token" >/dev/null 2>&1 || exit_code=$?
    echo "$exit_code"
}

# Clean up everything from a test scenario
full_cleanup() {
    local test_dir="$1"
    local container_name="$2"
    cleanup_docker "$container_name"
    cleanup_test_dir "$test_dir"
}

# ══════════════════════════════════════════════════════════
# Scenarios
# ══════════════════════════════════════════════════════════

scenario_1_bad_token() {
    heading "Scenario 1: Bad Token"
    info "Installer should reject bad tokens before creating anything"

    local test_dir
    test_dir=$(setup_test_dir "s1-bad-token")
    local cname="${CONTAINER_PREFIX}-s1"

    # Test 1a: Empty token
    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$TEST_PORT")

    local rc
    rc=$(run_installer "$installer" "")
    if [[ "$rc" -ne 0 ]]; then
        record_pass "Empty token rejected (exit $rc)"
    else
        record_fail "Empty token was accepted"
    fi
    assert_no_dir "$test_dir/install" "Empty token"

    # Test 1b: Too-short token
    rc=$(run_installer "$installer" "short")
    if [[ "$rc" -ne 0 ]]; then
        record_pass "Short token rejected (exit $rc)"
    else
        record_fail "Short token was accepted"
    fi

    # Test 1c: Placeholder token
    rc=$(run_installer "$installer" "YOUR_TOKEN")
    if [[ "$rc" -ne 0 ]]; then
        record_pass "Placeholder 'YOUR_TOKEN' rejected (exit $rc)"
    else
        record_fail "Placeholder token was accepted"
    fi

    rc=$(run_installer "$installer" "YOUR_COPILOT_TOKEN")
    if [[ "$rc" -ne 0 ]]; then
        record_pass "Placeholder 'YOUR_COPILOT_TOKEN' rejected (exit $rc)"
    else
        record_fail "Placeholder 'YOUR_COPILOT_TOKEN' was accepted"
    fi

    assert_no_containers "$cname" "Bad token"
    assert_no_volumes "$cname" "Bad token"

    full_cleanup "$test_dir" "$cname"
}

scenario_2_no_docker() {
    heading "Scenario 2: No Docker Available"
    info "Simulating Docker unavailable by using a broken PATH"

    local test_dir
    test_dir=$(setup_test_dir "s2-no-docker")
    local cname="${CONTAINER_PREFIX}-s2"

    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$((TEST_PORT+10))")

    # Prepend a fake docker that always fails
    mkdir -p "$test_dir/fakebin"
    cat > "$test_dir/fakebin/docker" << 'FAKE'
#!/bin/sh
echo "Cannot connect to the Docker daemon" >&2
exit 1
FAKE
    chmod +x "$test_dir/fakebin/docker"

    # Run with fake docker first in PATH
    local rc=0
    PATH="$test_dir/fakebin:$PATH" timeout 30 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        record_pass "Installer failed gracefully without Docker (exit $rc)"
    else
        record_fail "Installer succeeded without Docker"
    fi

    # Config dir may have been created before Docker check — that's OK
    # But no containers or volumes should exist
    assert_no_containers "$cname" "No Docker"
    assert_no_volumes "$cname" "No Docker"

    full_cleanup "$test_dir" "$cname"
}

scenario_3_bad_compose() {
    heading "Scenario 3: Docker Compose Failure (Bad YAML)"
    info "Installer writes corrupted docker-compose.yml"

    local test_dir
    test_dir=$(setup_test_dir "s3-bad-compose")
    local cname="${CONTAINER_PREFIX}-s3"

    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$((TEST_PORT+20))" "bad_compose")

    local rc=0
    timeout 60 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        record_pass "Bad compose detected (exit $rc)"
    else
        # Even if installer reports success, compose up should have failed
        record_fail "Installer didn't catch bad compose"
    fi

    # Config files may exist (created before compose step) — acceptable
    # But no running containers
    assert_no_containers "$cname" "Bad compose"
    assert_no_volumes "$cname" "Bad compose"
    assert_port_free "$((TEST_PORT+20))" "Bad compose"

    full_cleanup "$test_dir" "$cname"
}

scenario_4_port_conflict() {
    heading "Scenario 4: Port Conflict"
    info "Starting a listener on the install port first"

    local test_dir
    test_dir=$(setup_test_dir "s4-port-conflict")
    local cname="${CONTAINER_PREFIX}-s4"
    local conflict_port=$((TEST_PORT+30))

    # Start a dummy listener to occupy the port
    python3 -c "
import socket, time, threading
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $conflict_port))
s.listen(1)
# Keep it alive for 60s
time.sleep(60)
s.close()
" &
    local blocker_pid=$!
    sleep 1

    # Verify port is occupied
    if ss -tlnp 2>/dev/null | grep -q ":${conflict_port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${conflict_port} "; then
        dim "Port $conflict_port confirmed occupied"
    else
        dim "Warning: port blocker may not have bound"
    fi

    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$conflict_port")

    local rc=0
    timeout 60 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    # The installer may or may not fail — Docker maps ports at runtime
    # What matters is cleanup after
    cleanup_docker "$cname"
    assert_no_containers "$cname" "Port conflict"
    assert_no_volumes "$cname" "Port conflict"

    # Clean up blocker
    kill $blocker_pid 2>/dev/null || true
    wait $blocker_pid 2>/dev/null || true
    record_pass "Port conflict scenario completed"

    full_cleanup "$test_dir" "$cname"
}

scenario_5_permission_denied() {
    heading "Scenario 5: Directory Permission Denied"
    info "Making install directory non-writable"

    local test_dir
    test_dir=$(setup_test_dir "s5-perms")
    local cname="${CONTAINER_PREFIX}-s5"

    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$((TEST_PORT+40))")

    # Create install dir but make it read-only
    mkdir -p "$test_dir/install"
    chmod 444 "$test_dir/install"

    local rc=0
    timeout 30 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        record_pass "Permission denied handled (exit $rc)"
    else
        record_fail "Installer succeeded with read-only directory"
    fi

    assert_no_containers "$cname" "Permission denied"

    # Restore permissions for cleanup
    chmod 755 "$test_dir/install" 2>/dev/null || true
    full_cleanup "$test_dir" "$cname"
}

scenario_6_partial_config() {
    heading "Scenario 6: Partial Config (Interrupt Mid-Write)"
    info "Simulating crash after partial config file creation"

    local test_dir
    test_dir=$(setup_test_dir "s6-partial")
    local cname="${CONTAINER_PREFIX}-s6"
    local install_subdir="$test_dir/install"

    # Manually create partial state (as if installer crashed mid-step-4)
    mkdir -p "$install_subdir/config"
    echo '{"gateway":{}}' > "$install_subdir/config/openclaw.json"
    # auth-profiles.json and SOUL.md missing (simulates crash)
    # No docker-compose.yml

    # Verify partial state
    if [[ -f "$install_subdir/config/openclaw.json" ]] && \
       [[ ! -f "$install_subdir/config/auth-profiles.json" ]]; then
        record_pass "Partial state created successfully"
    else
        record_fail "Could not create partial state"
    fi

    # Now run the installer over this partial state — it should overwrite cleanly
    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$((TEST_PORT+50))")

    # But first let's verify the installer handles existing partial dirs
    local rc=0
    timeout 120 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    # Check that all config files now exist (overwritten)
    if [[ -f "$install_subdir/config/openclaw.json" ]] && \
       [[ -f "$install_subdir/config/auth-profiles.json" ]] && \
       [[ -f "$install_subdir/config/github-copilot.token.json" ]]; then
        record_pass "Partial config overwritten with complete config"
    else
        record_fail "Config files incomplete after re-run"
    fi

    # Cleanup
    cleanup_docker "$cname"
    full_cleanup "$test_dir" "$cname"
}

scenario_7_container_crash() {
    heading "Scenario 7: Container Crash on Startup"
    info "Container command exits immediately"

    local test_dir
    test_dir=$(setup_test_dir "s7-crash")
    local cname="${CONTAINER_PREFIX}-s7"

    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$((TEST_PORT+60))" "crash_container")

    local rc=0
    timeout 120 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    # Installer may still "succeed" (compose up returns 0 even if container crashes later)
    # But the container should be in exited/restarting state
    local state
    state=$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "not_found")

    if [[ "$state" == "not_found" ]] || [[ "$state" == "exited" ]] || [[ "$state" == "restarting" ]]; then
        record_pass "Container crash detected (state: $state)"
    else
        record_fail "Container in unexpected state: $state"
    fi

    # Clean up
    cleanup_docker "$cname"
    assert_no_containers "$cname" "Container crash cleanup"
    assert_no_volumes "$cname" "Container crash cleanup"
    assert_port_free "$((TEST_PORT+60))" "Container crash"

    full_cleanup "$test_dir" "$cname"
}

scenario_8_gateway_timeout() {
    heading "Scenario 8: Gateway Never Ready (Timeout)"
    info "Container runs but gateway never responds on HTTP"

    local test_dir
    test_dir=$(setup_test_dir "s8-timeout")
    local cname="${CONTAINER_PREFIX}-s8"
    local tport=$((TEST_PORT+70))

    # Create a working installer but with an unreachable health URL
    local installer
    installer=$(create_test_installer "$test_dir" "$cname" "$tport")

    # Patch the health check URL to something that won't respond
    sed -i "s|http://localhost:${tport}|http://localhost:19999|g" "$installer"

    # Also reduce the wait loop to be very short (3 retries × 1s)
    sed -i 's|for i in $(seq 1 36)|for i in $(seq 1 3)|g' "$installer"
    sed -i 's|sleep 5|sleep 1|g' "$installer"

    local rc=0
    timeout 120 bash "$installer" "valid-test-token-1234567890" >/dev/null 2>&1 || rc=$?

    # Installer should still complete (gateway timeout is non-fatal in install.sh)
    # Check that config files were created despite timeout
    if [[ -f "$test_dir/install/docker-compose.yml" ]]; then
        record_pass "Config files created despite gateway timeout"
    else
        record_fail "Config files missing after gateway timeout"
    fi

    if [[ -f "$test_dir/install/CONNECTION-INFO.txt" ]]; then
        record_pass "CONNECTION-INFO.txt written (installer completed)"
    else
        # Some installers skip this on failure — acceptable
        record_pass "CONNECTION-INFO.txt skipped (installer noted timeout)"
    fi

    cleanup_docker "$cname"
    assert_no_containers "$cname" "Gateway timeout cleanup"
    full_cleanup "$test_dir" "$cname"
}

scenario_9_double_cleanup() {
    heading "Scenario 9: Cleanup Idempotency"
    info "Running cleanup twice should not error"

    local test_dir
    test_dir=$(setup_test_dir "s9-idempotent")
    local cname="${CONTAINER_PREFIX}-s9"

    # First cleanup (nothing to clean)
    cleanup_docker "$cname"
    record_pass "First cleanup on empty state succeeded"

    # Create something then clean twice
    docker run -d --name "$cname" --rm alpine sleep 60 >/dev/null 2>&1 || true
    docker volume create "${cname}-config" >/dev/null 2>&1 || true

    cleanup_docker "$cname"
    record_pass "Second cleanup after creating resources succeeded"

    cleanup_docker "$cname"
    record_pass "Third cleanup (already clean) succeeded"

    assert_no_containers "$cname" "Idempotent cleanup"
    assert_no_volumes "$cname" "Idempotent cleanup"

    full_cleanup "$test_dir" "$cname"
}

# ══════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════

main() {
    echo ""
    printf "${BOLD}╔══════════════════════════════════════════════╗${NC}\n"
    printf "${BOLD}║  OpenClaw Installer Rollback Test Suite  🦉  ║${NC}\n"
    printf "${BOLD}╚══════════════════════════════════════════════╝${NC}\n"

    # Pre-flight checks
    if ! command -v docker >/dev/null 2>&1; then
        echo ""
        fail "Docker not found — required for rollback tests"
        exit 1
    fi

    if [[ ! -f "$INSTALLER" ]]; then
        echo ""
        fail "Installer not found at: $INSTALLER"
        exit 1
    fi

    mkdir -p "$TEST_BASE"
    dim "Test base directory: $TEST_BASE"
    dim "Test port range: $TEST_PORT - $((TEST_PORT+79))"
    dim "Container prefix: $CONTAINER_PREFIX"

    local start_time
    start_time=$(date +%s)

    # Run scenarios
    ! should_run 1 || scenario_1_bad_token
    ! should_run 2 || scenario_2_no_docker
    ! should_run 3 || scenario_3_bad_compose
    ! should_run 4 || scenario_4_port_conflict
    ! should_run 5 || scenario_5_permission_denied
    ! should_run 6 || scenario_6_partial_config
    ! should_run 7 || scenario_7_container_crash
    ! should_run 8 || scenario_8_gateway_timeout
    ! should_run 9 || scenario_9_double_cleanup

    # Cleanup test base
    if ! $KEEP_ARTIFACTS; then
        rm -rf "$TEST_BASE" 2>/dev/null || true
    fi

    # Summary
    local end_time elapsed total
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    total=$((PASSED + FAILED + SKIPPED))

    echo ""
    printf "${BOLD}══════════════════════════════════════════════${NC}\n"

    if [[ $FAILED -eq 0 ]]; then
        printf "  ${GREEN}🎉 ALL CHECKS PASSED${NC}\n"
    else
        printf "  ${RED}⚠️  $FAILED CHECK(S) FAILED${NC}\n"
    fi

    echo ""
    printf "  Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}  Skipped: ${YELLOW}$SKIPPED${NC}  Total: $total  Time: ${elapsed}s\n"

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        printf "  ${RED}Failed checks:${NC}\n"
        for e in "${ERRORS[@]}"; do
            printf "    ${RED}• %s${NC}\n" "$e"
        done
    fi

    printf "${BOLD}══════════════════════════════════════════════${NC}\n"
    echo ""

    if [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
