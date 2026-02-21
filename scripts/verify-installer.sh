#!/bin/bash
# verify-installer.sh — Verify OpenClaw install script integrity before execution
#
# Checks SHA-256 checksums and OpenSSL signatures to ensure install scripts
# haven't been tampered with since signing.
#
# Usage:
#   ./verify-installer.sh                     # verify all signed files
#   ./verify-installer.sh install.ps1         # verify one file
#   ./verify-installer.sh --fetch             # download + verify before run
#   ./verify-installer.sh --strict            # exit 1 on any warning
#   ./verify-installer.sh --json              # JSON output
#   ./verify-installer.sh --pubkey /path/key  # custom public key
#
# Exit codes:
#   0 = all verified
#   1 = verification failed (tampering or missing sig)
#   2 = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIG_DIR="$REPO_ROOT/signatures"
PUBKEY="$SIG_DIR/openclaw-sign.pub"

# Remote URLs for --fetch mode
RAW_BASE="https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main"

# ── Helpers ───────────────────────────────────────────────────

info()  { [ "$QUIET" = false ] && echo "  ℹ️  $1"; }
ok()    { [ "$QUIET" = false ] && echo "  ✅ $1"; }
warn()  { [ "$QUIET" = false ] && echo "  ⚠️  $1"; }
fail()  { [ "$QUIET" = false ] && echo "  ❌ $1"; }

QUIET=false
STRICT=false
JSON_MODE=false

# ── Detect key type ──────────────────────────────────────────

detect_key_type() {
  local key="$1"
  if openssl pkey -pubin -in "$key" -text -noout 2>/dev/null | grep -qi "ed25519"; then
    echo "ed25519"
  else
    echo "rsa"
  fi
}

# ── Verify single file ───────────────────────────────────────

verify_file() {
  local filepath="$1"
  local basename
  basename=$(basename "$filepath")

  local sig_file="$SIG_DIR/${basename}.sig"
  local hash_file="$SIG_DIR/${basename}.sha256"

  local result="unknown"
  local details=""

  # Step 1: Check signature file exists
  if [ ! -f "$sig_file" ]; then
    result="unsigned"
    details="No signature found for $basename"
    if [ "$STRICT" = true ]; then
      result="failed"
    fi
    echo "$result|$details"
    return
  fi

  # Step 2: Verify SHA-256 checksum
  if [ -f "$hash_file" ]; then
    local expected
    expected=$(cut -d' ' -f1 < "$hash_file")
    local actual
    actual=$(sha256sum "$filepath" | cut -d' ' -f1)

    if [ "$expected" != "$actual" ]; then
      result="tampered"
      details="Checksum mismatch: expected ${expected:0:16}..., got ${actual:0:16}..."
      echo "$result|$details"
      return
    fi
    details="Checksum: ${actual:0:16}... ✓"
  fi

  # Step 3: Verify cryptographic signature
  if [ ! -f "$PUBKEY" ]; then
    result="unverifiable"
    details="No public key found at $PUBKEY"
    echo "$result|$details"
    return
  fi

  local key_type
  key_type=$(detect_key_type "$PUBKEY")
  local sig_ok=false

  if [ "$key_type" = "ed25519" ]; then
    # Try verifying the hash digest
    local file_hash
    file_hash=$(sha256sum "$filepath" | cut -d' ' -f1)

    if echo -n "$file_hash" | xxd -r -p | \
       openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
       -sigfile "$sig_file" 2>/dev/null; then
      sig_ok=true
    elif echo -n "$file_hash" | \
         openssl pkeyutl -verify -pubin -inkey "$PUBKEY" \
         -sigfile "$sig_file" 2>/dev/null; then
      sig_ok=true
    fi
  else
    if openssl dgst -sha256 -verify "$PUBKEY" -signature "$sig_file" "$filepath" 2>/dev/null | grep -q "Verified OK"; then
      sig_ok=true
    fi
  fi

  if [ "$sig_ok" = true ]; then
    result="verified"
    details="Signature valid ($key_type). $details"
  else
    result="bad_signature"
    details="Signature verification FAILED. File may have been tampered with."
  fi

  echo "$result|$details"
}

# ── Verify all ────────────────────────────────────────────────

verify_all() {
  [ "$QUIET" = false ] && [ "$JSON_MODE" = false ] && {
    echo ""
    echo "  🔐 OpenClaw Installer Verification"
    echo "  ═══════════════════════════════════"
    echo ""
  }

  if [ ! -d "$SIG_DIR" ]; then
    fail "No signatures directory found at $SIG_DIR"
    return 1
  fi

  local total=0
  local verified=0
  local failed=0
  local unsigned=0
  local results_json="["

  # Collect files to verify
  local files_to_check=()

  if [ -f "$SIG_DIR/CHECKSUMS.txt" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue
      [ -z "$line" ] && continue
      local relpath
      relpath=$(echo "$line" | awk '{print $2}')
      [ -n "$relpath" ] && files_to_check+=("$relpath")
    done < "$SIG_DIR/CHECKSUMS.txt"
  fi

  # Also check any .sig files
  for sig in "$SIG_DIR"/*.sig; do
    [ -f "$sig" ] || continue
    local base
    base=$(basename "$sig" .sig)
    local found=false
    for f in "${files_to_check[@]+"${files_to_check[@]}"}"; do
      [ "$(basename "$f")" = "$base" ] && found=true && break
    done
    if [ "$found" = false ]; then
      files_to_check+=("$base")
    fi
  done

  local first_json=true

  for relpath in "${files_to_check[@]+"${files_to_check[@]}"}"; do
    local filepath="$REPO_ROOT/$relpath"
    [ -f "$filepath" ] || filepath="$REPO_ROOT/$(basename "$relpath")"
    [ -f "$filepath" ] || { warn "File not found: $relpath"; continue; }

    total=$((total + 1))
    local result_line
    result_line=$(verify_file "$filepath")
    local status="${result_line%%|*}"
    local detail="${result_line#*|}"

    case "$status" in
      verified)
        verified=$((verified + 1))
        [ "$JSON_MODE" = false ] && ok "$(basename "$filepath"): $detail"
        ;;
      tampered|bad_signature)
        failed=$((failed + 1))
        [ "$JSON_MODE" = false ] && fail "$(basename "$filepath"): $detail"
        ;;
      unsigned)
        unsigned=$((unsigned + 1))
        [ "$JSON_MODE" = false ] && warn "$(basename "$filepath"): $detail"
        ;;
      *)
        [ "$JSON_MODE" = false ] && warn "$(basename "$filepath"): $detail"
        ;;
    esac

    if [ "$JSON_MODE" = true ]; then
      [ "$first_json" = true ] && first_json=false || results_json+=","
      detail_escaped=$(echo "$detail" | sed 's/"/\\"/g')
      results_json+=$(printf '\n    {"file":"%s","status":"%s","detail":"%s"}' \
        "$(basename "$filepath")" "$status" "$detail_escaped")
    fi
  done

  results_json+=$'\n  ]'

  if [ "$JSON_MODE" = true ]; then
    local all_ok="true"
    [ "$failed" -gt 0 ] && all_ok="false"
    [ "$STRICT" = true ] && [ "$unsigned" -gt 0 ] && all_ok="false"

    cat <<EOF
{
  "verified": $all_ok,
  "summary": {"total": $total, "verified": $verified, "failed": $failed, "unsigned": $unsigned},
  "results": $results_json
}
EOF
    [ "$all_ok" = "false" ] && return 1
    return 0
  fi

  echo ""
  echo "  ──────────────────────────────"

  if [ "$failed" -gt 0 ]; then
    fail "$failed file(s) FAILED verification — DO NOT RUN these scripts!"
    echo ""
    return 1
  elif [ "$verified" -gt 0 ] && [ "$unsigned" -eq 0 ]; then
    ok "All $verified file(s) verified successfully"
    echo ""
    return 0
  elif [ "$unsigned" -gt 0 ]; then
    warn "$verified verified, $unsigned unsigned"
    echo ""
    [ "$STRICT" = true ] && return 1
    return 0
  else
    warn "No files to verify"
    echo ""
    return 1
  fi
}

# ── Fetch & Verify ────────────────────────────────────────────

fetch_and_verify() {
  local target="${1:-install.ps1}"

  [ "$QUIET" = false ] && {
    echo ""
    echo "  📥 Fetch & Verify: $target"
    echo "  ═══════════════════════════"
    echo ""
  }

  local tmpdir
  tmpdir=$(mktemp -d /tmp/openclaw-verify.XXXXXX)

  # Download file + signature + checksum + public key
  info "Downloading $target..."
  curl -sL "$RAW_BASE/$target" -o "$tmpdir/$target" || { fail "Download failed"; rm -rf "$tmpdir"; return 1; }
  ok "Downloaded $target ($(wc -c < "$tmpdir/$target") bytes)"

  info "Downloading signature..."
  curl -sL "$RAW_BASE/signatures/${target}.sig" -o "$tmpdir/${target}.sig" 2>/dev/null || true
  curl -sL "$RAW_BASE/signatures/${target}.sha256" -o "$tmpdir/${target}.sha256" 2>/dev/null || true
  curl -sL "$RAW_BASE/signatures/openclaw-sign.pub" -o "$tmpdir/openclaw-sign.pub" 2>/dev/null || true

  # Verify checksum
  if [ -f "$tmpdir/${target}.sha256" ] && [ -s "$tmpdir/${target}.sha256" ]; then
    local expected actual
    expected=$(cut -d' ' -f1 < "$tmpdir/${target}.sha256")
    actual=$(sha256sum "$tmpdir/$target" | cut -d' ' -f1)

    if [ "$expected" = "$actual" ]; then
      ok "Checksum verified: ${actual:0:16}..."
    else
      fail "Checksum MISMATCH — file may be tampered!"
      fail "Expected: ${expected:0:32}..."
      fail "Got:      ${actual:0:32}..."
      rm -rf "$tmpdir"
      return 1
    fi
  else
    warn "No checksum available — cannot verify integrity"
    if [ "$STRICT" = true ]; then
      rm -rf "$tmpdir"
      return 1
    fi
  fi

  # Verify signature
  if [ -f "$tmpdir/${target}.sig" ] && [ -s "$tmpdir/${target}.sig" ] && [ -f "$tmpdir/openclaw-sign.pub" ]; then
    local old_pubkey="$PUBKEY"
    PUBKEY="$tmpdir/openclaw-sign.pub"
    local old_sigdir="$SIG_DIR"
    SIG_DIR="$tmpdir"

    local result_line
    result_line=$(verify_file "$tmpdir/$target")
    local status="${result_line%%|*}"

    PUBKEY="$old_pubkey"
    SIG_DIR="$old_sigdir"

    if [ "$status" = "verified" ]; then
      ok "Signature verified"
    else
      fail "Signature verification FAILED"
      rm -rf "$tmpdir"
      return 1
    fi
  else
    warn "No signature available"
  fi

  echo ""
  ok "File is at: $tmpdir/$target"
  info "To run: powershell -File $tmpdir/$target"
  echo ""

  rm -rf "$tmpdir"
}

# ── CLI ───────────────────────────────────────────────────────

main() {
  local single_file=""
  local fetch_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --strict)  STRICT=true ;;
      --json)    JSON_MODE=true; QUIET=true ;;
      --quiet)   QUIET=true ;;
      --fetch)   fetch_mode=true ;;
      --pubkey)  shift; PUBKEY="$1" ;;
      --help|-h)
        echo "Usage: verify-installer.sh [OPTIONS] [FILE]"
        echo ""
        echo "  --strict       Fail on unsigned files too"
        echo "  --json         JSON output"
        echo "  --quiet        Suppress output (exit code only)"
        echo "  --fetch        Download and verify from GitHub"
        echo "  --pubkey KEY   Use custom public key"
        echo "  -h, --help     Show this help"
        exit 0
        ;;
      *)
        single_file="$1"
        ;;
    esac
    shift
  done

  if [ "$fetch_mode" = true ]; then
    fetch_and_verify "${single_file:-install.ps1}"
    exit $?
  fi

  if [ -n "$single_file" ]; then
    local filepath="$single_file"
    [ -f "$filepath" ] || filepath="$REPO_ROOT/$single_file"
    [ -f "$filepath" ] || { fail "File not found: $single_file"; exit 1; }

    local result_line
    result_line=$(verify_file "$filepath")
    local status="${result_line%%|*}"
    local detail="${result_line#*|}"

    if [ "$JSON_MODE" = true ]; then
      local valid="true"
      [[ "$status" == "tampered" || "$status" == "bad_signature" ]] && valid="false"
      printf '{"file":"%s","status":"%s","valid":%s,"detail":"%s"}\n' \
        "$(basename "$filepath")" "$status" "$valid" "$(echo "$detail" | sed 's/"/\\"/g')"
    else
      case "$status" in
        verified)      ok "$(basename "$filepath"): $detail" ;;
        tampered|bad*) fail "$(basename "$filepath"): $detail" ;;
        *)             warn "$(basename "$filepath"): $detail" ;;
      esac
    fi

    [[ "$status" == "tampered" || "$status" == "bad_signature" ]] && exit 1
    exit 0
  fi

  verify_all
}

main "$@"
