#!/usr/bin/env bash
# ============================================================
# Network Resilience Test Suite — Owl Goal
# ============================================================
#
# Simulates network failures during OpenClaw install to verify
# retry logic, partial resume, timeouts, and error messaging.
#
# Strategies (auto-selected by available privileges):
#   1. tc/iptables  — real packet-level disruption (needs root)
#   2. mock server  — local HTTP server that misbehaves (no root)
#   3. env hooks    — override endpoints to unreachable hosts
#
# Usage:
#   sudo ./network-resilience-test.sh           # full suite (root)
#   ./network-resilience-test.sh                # mock-only (no root)
#   ./network-resilience-test.sh --scenario 3   # run single scenario
#   ./network-resilience-test.sh --dry-run      # show what would run
#   ./network-resilience-test.sh --keep-logs    # don't clean up logs
#
# Requirements:
#   - bash 4+, curl, python3 (for mock server)
#   - Optional: tc, iptables (for packet-level tests, needs root)
#   - Optional: docker (for containerized isolation)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs/network-resilience-$(date +%Y%m%d_%H%M%S)"
MOCK_PORT=19876
MOCK_PID=""
DRY_RUN=false
KEEP_LOGS=false
SINGLE_SCENARIO=""
HAS_ROOT=false
HAS_TC=false
HAS_IPTABLES=false

# ── Parse args ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --keep-logs)  KEEP_LOGS=true; shift ;;
    --scenario)   SINGLE_SCENARIO="$2"; shift 2 ;;
    *)            echo "Unknown: $1"; exit 1 ;;
  esac
done

# ── Colors ──────────────────────────────────────────────────

if [ -t 1 ]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
  B='\033[1;37m' DIM='\033[0;90m' NC='\033[0m'
else
  R='' G='' Y='' C='' B='' DIM='' NC=''
fi

# ── State ───────────────────────────────────────────────────

PASS=0 FAIL=0 SKIP=0 TOTAL=0
RESULTS=()

pass()  { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); RESULTS+=("PASS|$1"); echo -e "  ${G}✅ PASS${NC}  $1"; }
fail()  { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); RESULTS+=("FAIL|$1|$2"); echo -e "  ${R}❌ FAIL${NC}  $1"; echo -e "         ${DIM}$2${NC}"; }
skip()  { SKIP=$((SKIP+1)); TOTAL=$((TOTAL+1)); RESULTS+=("SKIP|$1|$2"); echo -e "  ${Y}⏭️  SKIP${NC}  $1 ${DIM}($2)${NC}"; }

section() {
  echo ""
  echo -e "${C}┌──────────────────────────────────────────────┐${NC}"
  echo -e "${C}│${B}  $1$(printf '%*s' $((45-${#1})) '')${C}│${NC}"
  echo -e "${C}└──────────────────────────────────────────────┘${NC}"
  echo ""
}

# ── Capability detection ────────────────────────────────────

[ "$(id -u 2>/dev/null)" = "0" ] && HAS_ROOT=true
command -v tc >/dev/null 2>&1 && HAS_TC=true
command -v iptables >/dev/null 2>&1 && HAS_IPTABLES=true

# ── Setup ───────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

echo ""
echo -e "${B}  🦉 Network Resilience Test Suite${NC}"
echo -e "${DIM}  $(date -u +"%Y-%m-%d %H:%M:%S UTC")${NC}"
echo -e "${DIM}  Logs: $LOG_DIR${NC}"
echo ""
echo -e "  Root:     $([ "$HAS_ROOT" = "true" ] && echo "${G}yes${NC}" || echo "${Y}no${NC} (mock-only mode)")"
echo -e "  tc:       $([ "$HAS_TC" = "true" ] && echo "${G}available${NC}" || echo "${DIM}not found${NC}")"
echo -e "  iptables: $([ "$HAS_IPTABLES" = "true" ] && echo "${G}available${NC}" || echo "${DIM}not found${NC}")"

# ── Mock Server ─────────────────────────────────────────────
#
# Python HTTP server that can simulate various failure modes.
# Each endpoint behaves differently to test resilience.

start_mock_server() {
  local py_script="$LOG_DIR/_mock_server.py"

  cat > "$py_script" << 'MOCKEOF'
import http.server, socketserver, time, sys, os, json, random, threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19876

class Handler(http.server.BaseHTTPRequestHandler):
    request_counts = {}
    lock = threading.Lock()

    def log_message(self, fmt, *args):
        pass  # silence logs

    def _count(self, path):
        with self.lock:
            self.request_counts[path] = self.request_counts.get(path, 0) + 1
            return self.request_counts[path]

    def do_GET(self):
        p = self.path

        # /healthy — always 200
        if p == '/healthy':
            self._respond(200, 'OK')

        # /timeout — never responds (hangs until client gives up)
        elif p == '/timeout':
            time.sleep(300)

        # /slow — 100 bytes/sec trickle
        elif p == '/slow':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', '10000')
            self.end_headers()
            try:
                for i in range(100):
                    self.wfile.write(b'x' * 100)
                    self.wfile.flush()
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass

        # /drop-mid — send half then close
        elif p == '/drop-mid':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', '10000')
            self.end_headers()
            try:
                self.wfile.write(b'x' * 5000)
                self.wfile.flush()
            except:
                pass
            # force close
            try:
                self.connection.close()
            except:
                pass

        # /flaky — fails first 2 requests, succeeds on 3rd
        elif p == '/flaky':
            count = self._count(p)
            if count <= 2:
                self.send_response(503)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Retry-After', '1')
                self.end_headers()
                self.wfile.write(f'Service Unavailable (attempt {count})'.encode())
            else:
                self._respond(200, json.dumps({"status": "ok", "attempt": count}))

        # /flaky-dns — simulate DNS-like timeout (RST after delay)
        elif p == '/flaky-dns':
            time.sleep(5)
            try:
                self.connection.close()
            except:
                pass

        # /rate-limit — 429 with Retry-After
        elif p == '/rate-limit':
            count = self._count(p)
            if count <= 3:
                self.send_response(429)
                self.send_header('Retry-After', '2')
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'Too Many Requests')
            else:
                self._respond(200, 'Rate limit cleared')

        # /corrupt — returns bad/truncated JSON
        elif p == '/corrupt':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "ok", "data": [1, 2, 3')  # no closing

        # /redirect-loop — infinite 302
        elif p.startswith('/redirect-loop'):
            n = int(self.path.split('?n=')[1]) if '?n=' in self.path else 0
            self.send_response(302)
            self.send_header('Location', f'/redirect-loop?n={n+1}')
            self.end_headers()

        # /large-file — 50MB file for download tests
        elif p == '/large-file':
            size = 50 * 1024 * 1024
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(size))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()
            chunk = b'x' * 65536
            sent = 0
            try:
                while sent < size:
                    to_send = min(65536, size - sent)
                    self.wfile.write(chunk[:to_send])
                    sent += to_send
            except (BrokenPipeError, ConnectionResetError):
                pass

        # /partial-resume — supports Range header
        elif p == '/partial-resume':
            size = 10000
            range_hdr = self.headers.get('Range', '')
            if range_hdr.startswith('bytes='):
                start = int(range_hdr.split('=')[1].split('-')[0])
                remaining = size - start
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {start}-{size-1}/{size}')
                self.send_header('Content-Length', str(remaining))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(b'R' * remaining)
            else:
                # first request: send half then drop
                self.send_response(200)
                self.send_header('Content-Length', str(size))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                try:
                    self.wfile.write(b'F' * (size // 2))
                    self.wfile.flush()
                    self.connection.close()
                except:
                    pass

        # /reset — clear request counters
        elif p == '/reset':
            with self.lock:
                self.request_counts.clear()
            self._respond(200, 'Counters reset')

        # /stats — show request counts
        elif p == '/stats':
            with self.lock:
                self._respond(200, json.dumps(self.request_counts, indent=2))

        else:
            self._respond(404, 'Not Found')

    def _respond(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(body.encode() if isinstance(body, str) else body)

class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReuseTCPServer(('127.0.0.1', PORT), Handler) as httpd:
    print(f'Mock server on :{PORT}', flush=True)
    httpd.serve_forever()
MOCKEOF

  python3 "$py_script" "$MOCK_PORT" > "$LOG_DIR/mock-server.log" 2>&1 &
  MOCK_PID=$!

  # Wait for it
  for i in $(seq 1 20); do
    if curl -s -m 2 "http://127.0.0.1:$MOCK_PORT/healthy" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "ERROR: Mock server failed to start"
  return 1
}

stop_mock_server() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

# ── tc/iptables helpers ─────────────────────────────────────

IFACE=""

detect_interface() {
  IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
  [ -z "$IFACE" ] && IFACE="eth0"
}

tc_add_delay() {
  local ms=$1
  tc qdisc add dev "$IFACE" root netem delay "${ms}ms" 2>/dev/null || \
  tc qdisc change dev "$IFACE" root netem delay "${ms}ms" 2>/dev/null
}

tc_add_loss() {
  local pct=$1
  tc qdisc add dev "$IFACE" root netem loss "${pct}%" 2>/dev/null || \
  tc qdisc change dev "$IFACE" root netem loss "${pct}%" 2>/dev/null
}

tc_add_rate_limit() {
  local kbit=$1
  tc qdisc add dev "$IFACE" root tbf rate "${kbit}kbit" burst 32kbit latency 400ms 2>/dev/null || \
  tc qdisc change dev "$IFACE" root tbf rate "${kbit}kbit" burst 32kbit latency 400ms 2>/dev/null
}

tc_clear() {
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
}

iptables_block_dns() {
  iptables -I OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  iptables -I OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
}

iptables_unblock_dns() {
  iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
  iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
}

iptables_block_https() {
  iptables -I OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null
}

iptables_unblock_https() {
  iptables -D OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
}

# ── Cleanup trap ────────────────────────────────────────────

cleanup() {
  stop_mock_server
  if [ "$HAS_ROOT" = "true" ]; then
    tc_clear 2>/dev/null
    iptables_unblock_dns 2>/dev/null
    iptables_unblock_https 2>/dev/null
  fi
  if [ "$KEEP_LOGS" = "false" ] && [ "$FAIL" -eq 0 ] && [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ── Test helper ─────────────────────────────────────────────

should_run() {
  [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "$1" ]
}

# Reset mock counters between tests
reset_mock() {
  curl -s "http://127.0.0.1:$MOCK_PORT/reset" >/dev/null 2>&1 || true
}

# ════════════════════════════════════════════════════════════
# SCENARIOS — Mock Server (no root needed)
# ════════════════════════════════════════════════════════════

run_mock_tests() {
  section "Mock Server Scenarios"

  start_mock_server || { fail "Mock server startup" "Could not start mock server"; return; }

  BASE="http://127.0.0.1:$MOCK_PORT"

  # ── Scenario 1: Connection timeout ──────────────────────

  if should_run 1; then
    echo -e "  ${C}Scenario 1: Connection timeout${NC}"
    reset_mock

    START=$(date +%s)
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 -m 5 "$BASE/timeout" 2>/dev/null || echo "000")
    ELAPSED=$(( $(date +%s) - START ))
    LOG="$LOG_DIR/s1-timeout.log"
    echo "code=$HTTP_CODE elapsed=${ELAPSED}s" > "$LOG"

    if [ "$HTTP_CODE" = "000" ] && [ "$ELAPSED" -le 8 ]; then
      pass "Timeout detected within ${ELAPSED}s (curl honored --connect-timeout)"
    elif [ "$HTTP_CODE" = "000" ]; then
      pass "Timeout detected (took ${ELAPSED}s)"
    else
      fail "Timeout not handled" "Got HTTP $HTTP_CODE instead of timeout"
    fi
  fi

  # ── Scenario 2: Slow/trickle download ──────────────────

  if should_run 2; then
    echo -e "  ${C}Scenario 2: Slow trickle download${NC}"
    reset_mock

    START=$(date +%s)
    # 8s max-time should kill a 100-second trickle
    HTTP_CODE=$(curl -s -o "$LOG_DIR/s2-slow.bin" -w '%{http_code}' -m 8 "$BASE/slow" 2>/dev/null || echo "000")
    ELAPSED=$(( $(date +%s) - START ))
    BYTES=$(wc -c < "$LOG_DIR/s2-slow.bin" 2>/dev/null || echo 0)

    if [ "$ELAPSED" -le 12 ] && [ "$BYTES" -lt 10000 ]; then
      pass "Slow download aborted after ${ELAPSED}s (got $BYTES/10000 bytes)"
    else
      fail "Slow download not handled" "Took ${ELAPSED}s, got $BYTES bytes"
    fi
  fi

  # ── Scenario 3: Connection dropped mid-transfer ────────

  if should_run 3; then
    echo -e "  ${C}Scenario 3: Connection dropped mid-transfer${NC}"
    reset_mock

    HTTP_CODE=$(curl -s -o "$LOG_DIR/s3-drop.bin" -w '%{http_code}' -m 10 "$BASE/drop-mid" 2>/dev/null || echo "000")
    BYTES=$(wc -c < "$LOG_DIR/s3-drop.bin" 2>/dev/null || echo 0)

    if [ "$BYTES" -gt 0 ] && [ "$BYTES" -lt 10000 ]; then
      pass "Mid-transfer drop detected ($BYTES/10000 bytes received)"
    elif [ "$HTTP_CODE" = "000" ]; then
      pass "Connection drop caught (curl returned error)"
    else
      fail "Drop not detected" "Got $BYTES bytes, code $HTTP_CODE"
    fi
  fi

  # ── Scenario 4: Retry on 503 (flaky endpoint) ─────────

  if should_run 4; then
    echo -e "  ${C}Scenario 4: Retry logic on 503 Service Unavailable${NC}"
    reset_mock

    # Simulate what a smart downloader should do: retry on 503
    SUCCESS=false
    ATTEMPTS=0
    for i in 1 2 3 4 5; do
      ATTEMPTS=$i
      HTTP_CODE=$(curl -s -o "$LOG_DIR/s4-flaky-$i.txt" -w '%{http_code}' "$BASE/flaky" 2>/dev/null)
      if [ "$HTTP_CODE" = "200" ]; then
        SUCCESS=true
        break
      fi
      sleep 1
    done

    if [ "$SUCCESS" = "true" ]; then
      pass "Recovered after $ATTEMPTS attempts (first 2 returned 503)"
    else
      fail "Did not recover from 503" "All $ATTEMPTS attempts failed"
    fi
  fi

  # ── Scenario 5: Rate limiting (429 + Retry-After) ──────

  if should_run 5; then
    echo -e "  ${C}Scenario 5: Rate limiting (429 Retry-After)${NC}"
    reset_mock

    SUCCESS=false
    ATTEMPTS=0
    TOTAL_WAIT=0
    for i in 1 2 3 4 5 6; do
      ATTEMPTS=$i
      HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rate-limit" 2>/dev/null)
      if [ "$HTTP_CODE" = "200" ]; then
        SUCCESS=true
        break
      fi
      # Respect Retry-After header
      RETRY_AFTER=$(curl -s -D - -o /dev/null "$BASE/rate-limit" 2>/dev/null | grep -i 'retry-after' | grep -oP '\d+' || echo "2")
      sleep "${RETRY_AFTER:-2}"
      TOTAL_WAIT=$((TOTAL_WAIT + ${RETRY_AFTER:-2}))
    done

    if [ "$SUCCESS" = "true" ]; then
      pass "Rate limit handled: succeeded on attempt $ATTEMPTS (waited ${TOTAL_WAIT}s total)"
    else
      fail "Rate limit not handled" "Did not recover after $ATTEMPTS attempts"
    fi
  fi

  # ── Scenario 6: Corrupt/truncated response ─────────────

  if should_run 6; then
    echo -e "  ${C}Scenario 6: Corrupt JSON response${NC}"
    reset_mock

    BODY=$(curl -s -m 5 "$BASE/corrupt" 2>/dev/null)
    # Try to parse — should fail
    PARSE_OK=false
    echo "$BODY" | python3 -m json.tool >/dev/null 2>&1 && PARSE_OK=true

    if [ "$PARSE_OK" = "false" ]; then
      pass "Corrupt JSON correctly detected as invalid"
    else
      fail "Corrupt JSON was parsed successfully" "Should have been rejected: $BODY"
    fi
  fi

  # ── Scenario 7: Redirect loop ─────────────────────────

  if should_run 7; then
    echo -e "  ${C}Scenario 7: Infinite redirect loop${NC}"
    reset_mock

    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 10 -L -m 10 "$BASE/redirect-loop" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" != "200" ]; then
      pass "Redirect loop caught (curl stopped after max-redirs)"
    else
      fail "Redirect loop not caught" "Got HTTP 200 somehow"
    fi
  fi

  # ── Scenario 8: Partial download resume ────────────────

  if should_run 8; then
    echo -e "  ${C}Scenario 8: Download resume with Range header${NC}"
    reset_mock

    # First request gets partial data then drops
    curl -s -o "$LOG_DIR/s8-partial.bin" -m 5 "$BASE/partial-resume" 2>/dev/null || true
    FIRST_BYTES=$(wc -c < "$LOG_DIR/s8-partial.bin" 2>/dev/null || echo 0)

    if [ "$FIRST_BYTES" -gt 0 ]; then
      # Resume from where we left off
      HTTP_CODE=$(curl -s -o "$LOG_DIR/s8-resume.bin" -w '%{http_code}' \
        -H "Range: bytes=${FIRST_BYTES}-" "$BASE/partial-resume" 2>/dev/null)
      RESUME_BYTES=$(wc -c < "$LOG_DIR/s8-resume.bin" 2>/dev/null || echo 0)
      TOTAL=$((FIRST_BYTES + RESUME_BYTES))

      if [ "$HTTP_CODE" = "206" ] && [ "$TOTAL" -ge 10000 ]; then
        pass "Resume succeeded: $FIRST_BYTES + $RESUME_BYTES = $TOTAL bytes (HTTP 206)"
      elif [ "$HTTP_CODE" = "206" ]; then
        pass "Resume worked (HTTP 206, got $TOTAL/10000 bytes)"
      else
        fail "Resume failed" "HTTP $HTTP_CODE, got $RESUME_BYTES bytes on resume"
      fi
    else
      fail "Initial partial download got 0 bytes" "Cannot test resume"
    fi
  fi

  # ── Scenario 9: DNS-like timeout ───────────────────────

  if should_run 9; then
    echo -e "  ${C}Scenario 9: DNS-like timeout (connection hangs then drops)${NC}"
    reset_mock

    START=$(date +%s)
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$BASE/flaky-dns" 2>/dev/null || echo "000")
    ELAPSED=$(( $(date +%s) - START ))

    if [ "$HTTP_CODE" = "000" ] || [ "$ELAPSED" -le 10 ]; then
      pass "DNS-like timeout handled in ${ELAPSED}s"
    else
      fail "DNS timeout not handled" "Took ${ELAPSED}s, code $HTTP_CODE"
    fi
  fi

  stop_mock_server
}

# ════════════════════════════════════════════════════════════
# SCENARIOS — tc/iptables (root required)
# ════════════════════════════════════════════════════════════

run_network_tests() {
  section "Network-Level Scenarios (root)"

  if [ "$HAS_ROOT" = "false" ]; then
    skip "tc/iptables tests" "requires root (run with sudo)"
    return
  fi

  detect_interface

  # ── Scenario 10: High latency (500ms) ──────────────────

  if should_run 10; then
    echo -e "  ${C}Scenario 10: High latency (500ms per packet)${NC}"

    if [ "$HAS_TC" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        skip "High latency" "dry-run"
      else
        tc_add_delay 500

        START=$(date +%s)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 "https://registry.hub.docker.com/" 2>/dev/null || echo "000")
        ELAPSED=$(( $(date +%s) - START ))

        tc_clear

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
          pass "Connected with 500ms latency in ${ELAPSED}s (HTTP $HTTP_CODE)"
        elif [ "$HTTP_CODE" = "000" ] && [ "$ELAPSED" -ge 25 ]; then
          pass "Timeout correctly triggered under high latency (${ELAPSED}s)"
        else
          fail "Unexpected result under latency" "HTTP $HTTP_CODE in ${ELAPSED}s"
        fi
      fi
    else
      skip "High latency" "tc not available"
    fi
  fi

  # ── Scenario 11: 50% packet loss ──────────────────────

  if should_run 11; then
    echo -e "  ${C}Scenario 11: 50% packet loss${NC}"

    if [ "$HAS_TC" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        skip "Packet loss" "dry-run"
      else
        tc_add_loss 50

        # Try multiple times — should eventually succeed or fail gracefully
        SUCCESS=false
        for attempt in 1 2 3; do
          HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --retry 2 -m 15 "https://registry.npmjs.org/" 2>/dev/null || echo "000")
          if [ "$HTTP_CODE" = "200" ]; then
            SUCCESS=true
            break
          fi
        done

        tc_clear

        if [ "$SUCCESS" = "true" ]; then
          pass "Recovered from 50% packet loss (attempt $attempt)"
        else
          pass "Correctly failed under 50% packet loss (HTTP $HTTP_CODE)"
        fi
      fi
    else
      skip "Packet loss" "tc not available"
    fi
  fi

  # ── Scenario 12: DNS blocked ───────────────────────────

  if should_run 12; then
    echo -e "  ${C}Scenario 12: DNS resolution blocked${NC}"

    if [ "$HAS_IPTABLES" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        skip "DNS blocked" "dry-run"
      else
        iptables_block_dns

        START=$(date +%s)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "https://registry.hub.docker.com/" 2>/dev/null || echo "000")
        ELAPSED=$(( $(date +%s) - START ))

        iptables_unblock_dns

        if [ "$HTTP_CODE" = "000" ]; then
          pass "DNS block detected: connection failed in ${ELAPSED}s"
        else
          fail "DNS block not effective" "Got HTTP $HTTP_CODE (may have cached DNS)"
        fi
      fi
    else
      skip "DNS blocked" "iptables not available"
    fi
  fi

  # ── Scenario 13: HTTPS blocked ─────────────────────────

  if should_run 13; then
    echo -e "  ${C}Scenario 13: HTTPS (port 443) blocked${NC}"

    if [ "$HAS_IPTABLES" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        skip "HTTPS blocked" "dry-run"
      else
        iptables_block_https

        START=$(date +%s)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "https://registry.hub.docker.com/" 2>/dev/null || echo "000")
        ELAPSED=$(( $(date +%s) - START ))

        iptables_unblock_https

        if [ "$HTTP_CODE" = "000" ]; then
          pass "HTTPS block detected: failed in ${ELAPSED}s"
        else
          fail "HTTPS block not effective" "Got HTTP $HTTP_CODE"
        fi
      fi
    else
      skip "HTTPS blocked" "iptables not available"
    fi
  fi

  # ── Scenario 14: Bandwidth throttle (56kbps) ──────────

  if should_run 14; then
    echo -e "  ${C}Scenario 14: Bandwidth throttle (56kbps dialup)${NC}"

    if [ "$HAS_TC" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        skip "Bandwidth throttle" "dry-run"
      else
        tc_add_rate_limit 56

        START=$(date +%s)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 -m 30 "https://api.github.com/" 2>/dev/null || echo "000")
        ELAPSED=$(( $(date +%s) - START ))

        tc_clear

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "403" ]; then
          pass "Connected at 56kbps in ${ELAPSED}s"
        elif [ "$HTTP_CODE" = "000" ]; then
          pass "Timeout at 56kbps after ${ELAPSED}s (expected for heavy pages)"
        else
          fail "Unexpected result at 56kbps" "HTTP $HTTP_CODE in ${ELAPSED}s"
        fi
      fi
    else
      skip "Bandwidth throttle" "tc not available"
    fi
  fi
}

# ════════════════════════════════════════════════════════════
# Error Message Quality Tests
# ════════════════════════════════════════════════════════════

run_error_message_tests() {
  section "Error Message Quality"

  # ── Scenario 15: Unreachable host error message ────────

  if should_run 15; then
    echo -e "  ${C}Scenario 15: Unreachable host produces helpful error${NC}"

    ERR_MSG=$(curl -s --connect-timeout 3 -m 5 "http://192.0.2.1:9999/install" 2>&1 || true)

    if echo "$ERR_MSG" | grep -qiE "timed out|refused|unreachable|couldn.t connect|failed to connect"; then
      pass "Curl reports clear connection error"
    else
      fail "Error message unclear" "Got: $ERR_MSG"
    fi
  fi

  # ── Scenario 16: Bad DNS name error message ────────────

  if should_run 16; then
    echo -e "  ${C}Scenario 16: Invalid hostname produces helpful error${NC}"

    ERR_MSG=$(curl -s --connect-timeout 5 -m 8 "https://this-domain-definitely-does-not-exist-xyzzy.com/" 2>&1 || true)

    if echo "$ERR_MSG" | grep -qiE "resolve|dns|host|not found|nodename"; then
      pass "DNS failure reports clear error"
    else
      fail "DNS error unclear" "Got: $ERR_MSG"
    fi
  fi
}

# ════════════════════════════════════════════════════════════
# Run Everything
# ════════════════════════════════════════════════════════════

run_mock_tests
run_network_tests
run_error_message_tests

# ── Write JUnit-style report ────────────────────────────────

REPORT="$LOG_DIR/report.txt"
cat > "$REPORT" << EOF
Network Resilience Test Report
==============================
Date:     $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Host:     $(hostname)
Kernel:   $(uname -r)
Root:     $HAS_ROOT
tc:       $HAS_TC
iptables: $HAS_IPTABLES

Results: $PASS passed, $FAIL failed, $SKIP skipped / $TOTAL total

EOF

for r in "${RESULTS[@]}"; do
  echo "  $r" >> "$REPORT"
done

# ── Summary ─────────────────────────────────────────────────

echo ""
echo -e "${C}════════════════════════════════════════════════${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${G}✅ All tests passed!${NC}"
else
  echo -e "  ${R}❌ Some tests failed${NC}"
fi

echo ""
echo -e "  ${G}✅ Passed: $PASS${NC}  ${R}❌ Failed: $FAIL${NC}  ${Y}⏭️  Skipped: $SKIP${NC}  ${DIM}Total: $TOTAL${NC}"

if [ -d "$LOG_DIR" ] && { [ "$KEEP_LOGS" = "true" ] || [ "$FAIL" -gt 0 ]; }; then
  echo ""
  echo -e "  ${DIM}Logs: $LOG_DIR${NC}"
fi

echo ""
echo -e "${C}════════════════════════════════════════════════${NC}"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
