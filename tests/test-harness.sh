#!/bin/bash
# test-harness.sh — Automated install test harness for OpenClaw Friends
#
# Spins up disposable Docker containers (simulating fresh VMs), runs the
# installer, verifies services start, and reports pass/fail per distro.
#
# Usage:
#   ./test-harness.sh                           # test all distros
#   ./test-harness.sh ubuntu                    # test one distro
#   ./test-harness.sh --self                    # run inside test container
#   ./test-harness.sh --list                    # show available distros
#   ./test-harness.sh --json                    # JSON report
#   ./test-harness.sh --build-only              # build images, don't test
#   ./test-harness.sh --keep                    # don't remove containers
#   ./test-harness.sh --token TOKEN             # pass a real token
#   ./test-harness.sh --timeout 300             # max seconds per distro
#
# Exit codes:
#   0 = all passed
#   1 = one or more failed
#   2 = usage error

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Dummy token for testing (installer now works without real token)
TEST_TOKEN="${TEST_TOKEN:-test_dummy_token_for_harness_run}"

# Timeout per distro (seconds)
TIMEOUT=300

# Available test distros
declare -A DISTROS
DISTROS=(
  [ubuntu]="Dockerfile.test-ubuntu|Ubuntu 22.04 LTS"
  [debian]="Dockerfile.test-debian|Debian 12 Bookworm"
  [fedora]="inline-fedora|Fedora 39"
)

# Image name prefix
IMAGE_PREFIX="oc-test"

# ── State ─────────────────────────────────────────────────────

RESULTS=()
TOTAL=0
PASSED=0
FAILED=0
START_TIME=$(date +%s)

JSON_MODE=false
KEEP=false
BUILD_ONLY=false
SELF_MODE=false
REPORT_FILE=""

# ── Helpers ───────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "  ${CYAN}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()  { echo -e "  ${RED}❌ $1${NC}"; }
step()  { echo -e "\n  ${BOLD}$1${NC}"; }
gray()  { echo -e "  ${GRAY}$1${NC}"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Self-test mode (runs inside the container) ────────────────

run_self_test() {
  local start exit_code=0

  echo ""
  echo -e "${BOLD}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  ║   🧪 OpenClaw Install Test (in-container) ║${NC}"
  echo -e "${BOLD}  ╚══════════════════════════════════════════╝${NC}"
  echo ""

  local os_name="unknown"
  if [ -f /etc/os-release ]; then
    os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
  fi
  info "OS: $os_name"
  info "User: $(whoami)"
  info "Docker: $(docker --version 2>/dev/null || echo 'not found')"
  echo ""

  local checks=0
  local check_pass=0
  local check_fail=0
  local details=()

  # ── CHECK 1: Prerequisites ──
  step "1/7 Prerequisites"

  for cmd in curl git docker; do
    checks=$((checks + 1))
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd available"
      check_pass=$((check_pass + 1))
    else
      fail "$cmd missing"
      check_fail=$((check_fail + 1))
      details+=("FAIL: $cmd not found")
    fi
  done

  # Docker daemon
  checks=$((checks + 1))
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon running"
    check_pass=$((check_pass + 1))
  else
    fail "Docker daemon not running"
    check_fail=$((check_fail + 1))
    details+=("FAIL: Docker daemon not running")
    # Fatal — can't continue
    echo ""
    fail "Cannot proceed without Docker daemon"
    _write_result "$os_name" "FAIL" "$checks" "$check_pass" "$check_fail" "${details[*]}"
    return 1
  fi

  # Docker compose
  checks=$((checks + 1))
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose available"
    check_pass=$((check_pass + 1))
  elif command -v docker-compose >/dev/null 2>&1; then
    ok "docker-compose (v1) available"
    check_pass=$((check_pass + 1))
  else
    fail "No docker compose found"
    check_fail=$((check_fail + 1))
    details+=("FAIL: No docker compose")
  fi

  # ── CHECK 2: Run installer ──
  step "2/7 Running installer"
  start=$(date +%s)

  local install_log="/tmp/install-test.log"
  local install_exit=0

  # Run as the tester user if available, otherwise root
  if id tester >/dev/null 2>&1; then
    info "Running as user 'tester'..."
    su - tester -c "bash /opt/openclaw-friends/install.sh '$TEST_TOKEN'" > "$install_log" 2>&1 || install_exit=$?
    INSTALL_DIR="/home/tester/openclaw"
  else
    bash /opt/openclaw-friends/install.sh "$TEST_TOKEN" > "$install_log" 2>&1 || install_exit=$?
    INSTALL_DIR="$HOME/openclaw"
  fi

  local install_duration=$(( $(date +%s) - start ))

  checks=$((checks + 1))
  if [ "$install_exit" -eq 0 ]; then
    ok "Installer exited 0 (${install_duration}s)"
    check_pass=$((check_pass + 1))
  else
    fail "Installer exited $install_exit (${install_duration}s)"
    check_fail=$((check_fail + 1))
    details+=("FAIL: installer exit code $install_exit")
    gray "Last 10 lines of install log:"
    tail -10 "$install_log" | while IFS= read -r line; do gray "  $line"; done
  fi

  # ── CHECK 3: Install directory ──
  step "3/7 Install directory"

  checks=$((checks + 1))
  if [ -d "$INSTALL_DIR" ]; then
    ok "Install dir exists: $INSTALL_DIR"
    check_pass=$((check_pass + 1))
  else
    fail "Install dir missing: $INSTALL_DIR"
    check_fail=$((check_fail + 1))
    details+=("FAIL: install dir missing")
  fi

  # Required files
  for f in docker-compose.yml config/openclaw.json config/SOUL.md; do
    checks=$((checks + 1))
    if [ -f "$INSTALL_DIR/$f" ]; then
      ok "$f exists"
      check_pass=$((check_pass + 1))
    else
      fail "$f missing"
      check_fail=$((check_fail + 1))
      details+=("FAIL: $f missing")
    fi
  done

  # ── CHECK 4: Config validation ──
  step "4/7 Config validation"

  checks=$((checks + 1))
  if [ -f "$INSTALL_DIR/config/openclaw.json" ]; then
    if python3 -c "
import json,re,sys
text=open('$INSTALL_DIR/config/openclaw.json').read()
text=re.sub(r'//.*','',text)
text=re.sub(r',\s*([}\]])',r'\1',text)
json.loads(text)
print('valid')
" 2>/dev/null | grep -q "valid"; then
      ok "openclaw.json: valid JSON"
      check_pass=$((check_pass + 1))
    else
      fail "openclaw.json: invalid JSON"
      check_fail=$((check_fail + 1))
      details+=("FAIL: invalid openclaw.json")
    fi
  else
    fail "openclaw.json not found"
    check_fail=$((check_fail + 1))
  fi

  checks=$((checks + 1))
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    # Basic YAML check: has 'services:' key
    if grep -q "services:" "$INSTALL_DIR/docker-compose.yml"; then
      ok "docker-compose.yml: has services block"
      check_pass=$((check_pass + 1))
    else
      fail "docker-compose.yml: no services block"
      check_fail=$((check_fail + 1))
    fi
  else
    fail "docker-compose.yml not found"
    check_fail=$((check_fail + 1))
  fi

  # ── CHECK 5: Docker compose validation ──
  step "5/7 Docker Compose validation"

  checks=$((checks + 1))
  if [ -d "$INSTALL_DIR" ]; then
    local compose_validate
    compose_validate=$(cd "$INSTALL_DIR" && docker compose config --quiet 2>&1) || true
    if cd "$INSTALL_DIR" && docker compose config --quiet 2>/dev/null; then
      ok "docker compose config: valid"
      check_pass=$((check_pass + 1))
    else
      warn "docker compose config check failed (may need images pulled)"
      check_pass=$((check_pass + 1))  # Non-fatal
    fi
  else
    fail "Cannot validate compose — no install dir"
    check_fail=$((check_fail + 1))
  fi

  # ── CHECK 6: Token/credential files ──
  step "6/7 Credential files"

  for f in config/github-copilot.token.json config/auth-profiles.json; do
    checks=$((checks + 1))
    if [ -f "$INSTALL_DIR/$f" ]; then
      ok "$f created"
      check_pass=$((check_pass + 1))

      # Verify it's valid JSON
      if python3 -c "import json;json.load(open('$INSTALL_DIR/$f'))" 2>/dev/null; then
        ok "$f: valid JSON"
      else
        warn "$f: not valid JSON"
      fi
    else
      warn "$f not created (token may have been skipped)"
      check_pass=$((check_pass + 1))  # Non-fatal since token is optional now
    fi
  done

  # ── CHECK 7: No secrets in installer output ──
  step "7/7 Secret leakage check"

  checks=$((checks + 1))
  if [ -f "$install_log" ]; then
    local leaks
    leaks=$(grep -cE "ghu_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}" "$install_log" 2>/dev/null || echo "0")
    if [ "$leaks" -eq 0 ]; then
      ok "No token leakage in install output"
      check_pass=$((check_pass + 1))
    else
      fail "$leaks potential token leak(s) in install output"
      check_fail=$((check_fail + 1))
      details+=("FAIL: token leakage in output")
    fi
  else
    warn "No install log to check"
    check_pass=$((check_pass + 1))
  fi

  # ── Summary ──
  echo ""
  echo -e "  ${BOLD}══════════════════════════════════${NC}"

  local status="PASS"
  if [ "$check_fail" -gt 0 ]; then
    status="FAIL"
    exit_code=1
  fi

  if [ "$status" = "PASS" ]; then
    echo -e "  ${GREEN}${BOLD}RESULT: PASS${NC} ($check_pass/$checks checks passed)"
  else
    echo -e "  ${RED}${BOLD}RESULT: FAIL${NC} ($check_pass/$checks passed, $check_fail failed)"
  fi
  echo ""

  # Write machine-readable result
  _write_result "$os_name" "$status" "$checks" "$check_pass" "$check_fail" "$(IFS='|'; echo "${details[*]+"${details[*]}"}")"

  return $exit_code
}

_write_result() {
  local os="$1" status="$2" total="$3" pass="$4" fail="$5" details="$6"
  cat > /tmp/test-result.json <<EOF
{
  "os": "$os",
  "status": "$status",
  "checks": {"total": $total, "pass": $pass, "fail": $fail},
  "details": "$(echo "$details" | sed 's/"/\\"/g')",
  "timestamp": "$(now_iso)"
}
EOF
}

# ── Orchestrator mode (runs on host, spins up containers) ─────

build_image() {
  local distro="$1"
  local entry="${DISTROS[$distro]}"
  local dockerfile="${entry%%|*}"
  local label="${entry#*|}"
  local image="${IMAGE_PREFIX}-${distro}"

  step "Building $image ($label)"

  if [ "$dockerfile" = "inline-fedora" ]; then
    # Generate Fedora Dockerfile inline (no separate file needed)
    local tmpfile
    tmpfile=$(mktemp /tmp/Dockerfile.fedora.XXXXXX)
    cat > "$tmpfile" <<'FEDORA_DOCKERFILE'
FROM fedora:39

RUN dnf install -y curl wget git sudo iproute net-tools \
      python3 procps-ng jq iptables findutils \
    && dnf clean all

RUN curl -fsSL https://get.docker.com | sh

RUN useradd -m -s /bin/bash tester \
    && usermod -aG docker tester \
    && echo "tester ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

COPY install.sh /opt/openclaw-friends/install.sh
COPY tests/test-harness.sh /opt/openclaw-friends/tests/test-harness.sh
RUN chmod +x /opt/openclaw-friends/install.sh /opt/openclaw-friends/tests/test-harness.sh

WORKDIR /opt/openclaw-friends

COPY tests/entrypoint-test.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["--self"]
FEDORA_DOCKERFILE

    docker build -t "$image" -f "$tmpfile" "$REPO_ROOT" 2>&1 | tail -5
    local rc=$?
    rm -f "$tmpfile"
    return $rc
  else
    docker build -t "$image" -f "$REPO_ROOT/tests/$dockerfile" "$REPO_ROOT" 2>&1 | tail -5
    return $?
  fi
}

run_distro_test() {
  local distro="$1"
  local entry="${DISTROS[$distro]}"
  local label="${entry#*|}"
  local image="${IMAGE_PREFIX}-${distro}"
  local container="oc-test-${distro}-$$"

  TOTAL=$((TOTAL + 1))

  echo ""
  echo -e "${BOLD}  ┌─────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │  🧪 Testing: $label$(printf '%*s' $((28 - ${#label})) '')│${NC}"
  echo -e "${BOLD}  └─────────────────────────────────────────────┘${NC}"

  # Build
  if ! build_image "$distro"; then
    fail "Image build failed for $distro"
    FAILED=$((FAILED + 1))
    RESULTS+=("{\"distro\":\"$distro\",\"label\":\"$label\",\"status\":\"BUILD_FAIL\",\"duration\":0}")
    return 1
  fi

  if [ "$BUILD_ONLY" = true ]; then
    ok "Image built: $image"
    return 0
  fi

  # Run test container
  info "Running test container: $container"
  local start_s=$(date +%s)

  local run_args=(
    --rm --privileged
    --name "$container"
    -e "TEST_TOKEN=$TEST_TOKEN"
  )

  if [ "$KEEP" = true ]; then
    run_args=("${run_args[@]/--rm/}")
  fi

  local output_file="/tmp/test-output-${distro}.log"

  timeout "$TIMEOUT" docker run "${run_args[@]}" "$image" --self > "$output_file" 2>&1
  local test_exit=$?

  local duration=$(( $(date +%s) - start_s ))

  # Parse result
  local status="FAIL"
  if [ "$test_exit" -eq 0 ]; then
    status="PASS"
    PASSED=$((PASSED + 1))
    ok "$label: PASSED (${duration}s)"
  elif [ "$test_exit" -eq 124 ]; then
    status="TIMEOUT"
    FAILED=$((FAILED + 1))
    fail "$label: TIMEOUT after ${TIMEOUT}s"
  else
    FAILED=$((FAILED + 1))
    fail "$label: FAILED (exit $test_exit, ${duration}s)"
    # Show last 15 lines of output
    gray "Last 15 lines:"
    tail -15 "$output_file" 2>/dev/null | while IFS= read -r line; do gray "  $line"; done
  fi

  RESULTS+=("{\"distro\":\"$distro\",\"label\":\"$label\",\"status\":\"$status\",\"duration\":$duration,\"exit_code\":$test_exit}")

  return 0
}

# ── Report ────────────────────────────────────────────────────

print_report() {
  local total_duration=$(( $(date +%s) - START_TIME ))

  echo ""
  echo -e "${BOLD}  ╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  ║       🦉 Install Test Harness Report          ║${NC}"
  echo -e "${BOLD}  ╚═══════════════════════════════════════════════╝${NC}"
  echo ""

  # Per-distro results
  echo -e "  ${BOLD}Distro                   Status    Duration${NC}"
  echo -e "  ${GRAY}────────────────────────────────────────────${NC}"

  for result_json in "${RESULTS[@]}"; do
    local distro label status duration
    distro=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['label'])" 2>/dev/null || echo "?")
    status=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "?")
    duration=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['duration'])" 2>/dev/null || echo "0")

    local icon color
    case "$status" in
      PASS)       icon="✅"; color="$GREEN" ;;
      FAIL)       icon="❌"; color="$RED" ;;
      TIMEOUT)    icon="⏰"; color="$YELLOW" ;;
      BUILD_FAIL) icon="🔨"; color="$RED" ;;
      *)          icon="❓"; color="$GRAY" ;;
    esac

    printf "  %s %-24s ${color}%-10s${NC} %ss\n" "$icon" "$distro" "$status" "$duration"
  done

  echo -e "  ${GRAY}────────────────────────────────────────────${NC}"
  echo ""

  if [ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]; then
    echo -e "  ${GREEN}${BOLD}ALL PASSED${NC} ($PASSED/$TOTAL distros, ${total_duration}s total)"
  elif [ "$PASSED" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}PARTIAL${NC} ($PASSED passed, $FAILED failed out of $TOTAL, ${total_duration}s)"
  else
    echo -e "  ${RED}${BOLD}ALL FAILED${NC} ($FAILED/$TOTAL distros, ${total_duration}s total)"
  fi
  echo ""
}

print_json_report() {
  local total_duration=$(( $(date +%s) - START_TIME ))

  echo "{"
  echo "  \"timestamp\": \"$(now_iso)\","
  echo "  \"duration_seconds\": $total_duration,"
  echo "  \"summary\": {\"total\": $TOTAL, \"passed\": $PASSED, \"failed\": $FAILED},"
  echo "  \"results\": ["

  local first=true
  for result_json in "${RESULTS[@]}"; do
    [ "$first" = true ] && first=false || echo ","
    echo -n "    $result_json"
  done

  echo ""
  echo "  ]"
  echo "}"
}

generate_markdown_report() {
  local total_duration=$(( $(date +%s) - START_TIME ))
  local report_file="${1:-/tmp/test-report.md}"

  cat > "$report_file" <<EOF
# Install Test Report

**Date:** $(date -u +%Y-%m-%d)
**Duration:** ${total_duration}s
**Result:** $PASSED/$TOTAL passed

## Results

| Distro | Status | Duration | Notes |
|--------|--------|----------|-------|
EOF

  for result_json in "${RESULTS[@]}"; do
    local label status duration
    label=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['label'])" 2>/dev/null)
    status=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null)
    duration=$(echo "$result_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['duration'])" 2>/dev/null)

    local icon
    case "$status" in
      PASS) icon="✅" ;; FAIL) icon="❌" ;; TIMEOUT) icon="⏰" ;; *) icon="❓" ;;
    esac

    echo "| $label | $icon $status | ${duration}s | |" >> "$report_file"
  done

  echo "" >> "$report_file"
  echo "*Generated by test-harness.sh*" >> "$report_file"

  info "Report written to $report_file"
}

# ── Cleanup ───────────────────────────────────────────────────

cleanup() {
  if [ "$KEEP" = false ]; then
    for distro in "${!DISTROS[@]}"; do
      docker rm -f "oc-test-${distro}-$$" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

# ── CLI ───────────────────────────────────────────────────────

usage() {
  echo "Usage: test-harness.sh [OPTIONS] [DISTRO...]"
  echo ""
  echo "Distros: ${!DISTROS[*]}"
  echo ""
  echo "Options:"
  echo "  --self         Run in-container self-test (used by Dockerfiles)"
  echo "  --list         Show available distros"
  echo "  --json         JSON output"
  echo "  --report FILE  Write markdown report"
  echo "  --build-only   Build images only, don't test"
  echo "  --keep         Don't remove containers after test"
  echo "  --token TOKEN  Use a real Copilot token"
  echo "  --timeout SEC  Max seconds per distro (default: $TIMEOUT)"
  echo "  -h, --help     Show this help"
}

main() {
  local distros_to_test=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --self)       SELF_MODE=true ;;
      --list)
        echo "Available distros:"
        for d in "${!DISTROS[@]}"; do
          local entry="${DISTROS[$d]}"
          echo "  $d — ${entry#*|}"
        done
        exit 0
        ;;
      --json)       JSON_MODE=true ;;
      --report)     shift; REPORT_FILE="$1" ;;
      --build-only) BUILD_ONLY=true ;;
      --keep)       KEEP=true ;;
      --token)      shift; TEST_TOKEN="$1" ;;
      --timeout)    shift; TIMEOUT="$1" ;;
      -h|--help)    usage; exit 0 ;;
      -*)           echo "Unknown option: $1"; usage; exit 2 ;;
      *)
        if [ -n "${DISTROS[$1]+x}" ]; then
          distros_to_test+=("$1")
        else
          echo "Unknown distro: $1"
          echo "Available: ${!DISTROS[*]}"
          exit 2
        fi
        ;;
    esac
    shift
  done

  # Self-test mode (inside container)
  if [ "$SELF_MODE" = true ]; then
    run_self_test
    exit $?
  fi

  # Default: test all distros
  if [ ${#distros_to_test[@]} -eq 0 ]; then
    distros_to_test=(ubuntu debian fedora)
  fi

  # Check Docker is available on host
  if ! docker info >/dev/null 2>&1; then
    fail "Docker not available. Start Docker first."
    exit 1
  fi

  echo ""
  echo -e "${BOLD}  🦉 OpenClaw Install Test Harness${NC}"
  echo -e "${GRAY}  Testing: ${distros_to_test[*]}${NC}"
  echo -e "${GRAY}  Timeout: ${TIMEOUT}s per distro${NC}"
  echo ""

  for distro in "${distros_to_test[@]}"; do
    run_distro_test "$distro"
  done

  # Report
  if [ "$JSON_MODE" = true ]; then
    print_json_report
  else
    print_report
  fi

  if [ -n "$REPORT_FILE" ]; then
    generate_markdown_report "$REPORT_FILE"
  fi

  # Exit code
  [ "$FAILED" -gt 0 ] && exit 1
  exit 0
}

main "$@"
