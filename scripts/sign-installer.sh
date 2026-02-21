#!/bin/bash
# sign-installer.sh — Sign OpenClaw install scripts for integrity verification
#
# Uses OpenSSL Ed25519 for fast, modern signatures (no GPG keyring needed).
# Falls back to RSA-2048 if Ed25519 not supported.
#
# Usage:
#   ./sign-installer.sh                        # sign all install scripts
#   ./sign-installer.sh --file install.ps1     # sign one file
#   ./sign-installer.sh --keygen               # generate signing keypair
#   ./sign-installer.sh --keydir /path/to/keys # custom key location
#   ./sign-installer.sh --list                 # show current signatures
#
# Outputs:
#   signatures/<filename>.sig    — binary signature
#   signatures/<filename>.sha256 — SHA-256 checksum
#   signatures/CHECKSUMS.txt     — all checksums in one file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEY_DIR="${KEYDIR:-$REPO_ROOT/.signing-keys}"
SIG_DIR="$REPO_ROOT/signatures"

# Files to sign
INSTALL_FILES=(
  "install.ps1"
  "install.sh"
  "docker-compose.yml"
  "scripts/upgrade.sh"
  "scripts/check-compat.sh"
)

# ── Helpers ───────────────────────────────────────────────────

info()  { echo "  ℹ️  $1"; }
ok()    { echo "  ✅ $1"; }
warn()  { echo "  ⚠️  $1"; }
fail()  { echo "  ❌ $1"; }

# ── Key Generation ────────────────────────────────────────────

generate_keys() {
  echo ""
  echo "  🔑 Generating signing keypair"
  echo "  ══════════════════════════════"
  echo ""

  mkdir -p "$KEY_DIR"
  chmod 700 "$KEY_DIR"

  local key_type="ed25519"
  local private_key="$KEY_DIR/openclaw-sign.key"
  local public_key="$KEY_DIR/openclaw-sign.pub"

  if [ -f "$private_key" ]; then
    warn "Private key already exists at $private_key"
    read -rp "  Overwrite? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
      info "Cancelled"
      return 1
    fi
  fi

  # Try Ed25519 first, fall back to RSA
  if openssl genpkey -algorithm Ed25519 -out "$private_key" 2>/dev/null; then
    openssl pkey -in "$private_key" -pubout -out "$public_key" 2>/dev/null
    ok "Ed25519 keypair generated"
  else
    warn "Ed25519 not supported, falling back to RSA-2048"
    key_type="rsa"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" 2>/dev/null
    openssl pkey -in "$private_key" -pubout -out "$public_key" 2>/dev/null
    ok "RSA-2048 keypair generated"
  fi

  chmod 600 "$private_key"
  chmod 644 "$public_key"

  # Write key metadata
  cat > "$KEY_DIR/key-info.json" <<EOF
{
  "algorithm": "$key_type",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "private_key": "$(basename "$private_key")",
  "public_key": "$(basename "$public_key")",
  "fingerprint": "$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
}
EOF

  echo ""
  ok "Private key: $private_key (KEEP SECRET)"
  ok "Public key:  $public_key (distribute this)"
  echo ""

  # Copy public key to repo for distribution
  mkdir -p "$SIG_DIR"
  cp "$public_key" "$SIG_DIR/openclaw-sign.pub"
  ok "Public key copied to $SIG_DIR/openclaw-sign.pub"

  local fingerprint
  fingerprint=$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
  info "Key fingerprint: ${fingerprint:0:16}..."

  echo ""
  echo "  ⚠️  Back up $private_key securely!"
  echo "  ⚠️  Never commit the private key to git!"
  echo ""
}

# ── Signing ───────────────────────────────────────────────────

detect_key_type() {
  local key="$1"
  if openssl pkey -in "$key" -text -noout 2>/dev/null | grep -qi "ed25519"; then
    echo "ed25519"
  else
    echo "rsa"
  fi
}

sign_file() {
  local filepath="$1"
  local private_key="$KEY_DIR/openclaw-sign.key"

  if [ ! -f "$filepath" ]; then
    warn "File not found: $filepath"
    return 1
  fi

  if [ ! -f "$private_key" ]; then
    fail "No signing key found. Run: $0 --keygen"
    return 1
  fi

  local basename
  basename=$(basename "$filepath")
  local sig_file="$SIG_DIR/${basename}.sig"
  local hash_file="$SIG_DIR/${basename}.sha256"

  mkdir -p "$SIG_DIR"

  # Detect key type and sign accordingly
  local key_type
  key_type=$(detect_key_type "$private_key")

  if [ "$key_type" = "ed25519" ]; then
    openssl pkeyutl -sign \
      -inkey "$private_key" \
      -rawin \
      -in <(sha256sum "$filepath" | cut -d' ' -f1 | tr -d '\n' | xxd -r -p) \
      -out "$sig_file" 2>/dev/null

    if [ $? -ne 0 ]; then
      # Fallback: sign the file hash as text
      sha256sum "$filepath" | cut -d' ' -f1 | \
        openssl pkeyutl -sign -inkey "$private_key" -out "$sig_file" 2>/dev/null
    fi
  else
    openssl dgst -sha256 -sign "$private_key" -out "$sig_file" "$filepath" 2>/dev/null
  fi

  # Generate checksum
  local checksum
  checksum=$(sha256sum "$filepath" | cut -d' ' -f1)
  echo "$checksum  $basename" > "$hash_file"

  local sig_size
  sig_size=$(wc -c < "$sig_file")
  local file_size
  file_size=$(wc -c < "$filepath")

  ok "Signed: $basename ($file_size bytes → $sig_size byte sig)"

  echo "$checksum"
}

sign_all() {
  local private_key="$KEY_DIR/openclaw-sign.key"

  echo ""
  echo "  🔏 Signing install scripts"
  echo "  ═══════════════════════════"
  echo ""

  if [ ! -f "$private_key" ]; then
    fail "No signing key found at $private_key"
    echo ""
    info "Generate one with: $0 --keygen"
    return 1
  fi

  local key_type
  key_type=$(detect_key_type "$private_key")
  info "Using $key_type key"
  echo ""

  mkdir -p "$SIG_DIR"

  local checksums_file="$SIG_DIR/CHECKSUMS.txt"
  local signed=0
  local skipped=0

  # Header
  cat > "$checksums_file" <<EOF
# OpenClaw Install Script Checksums
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Key type: $key_type
# Verify: ./scripts/verify-installer.sh
#
EOF

  for relpath in "${INSTALL_FILES[@]}"; do
    local filepath="$REPO_ROOT/$relpath"
    if [ -f "$filepath" ]; then
      local checksum
      checksum=$(sign_file "$filepath")
      if [ $? -eq 0 ]; then
        echo "$checksum  $relpath" >> "$checksums_file"
        signed=$((signed + 1))
      fi
    else
      warn "Skipped (not found): $relpath"
      skipped=$((skipped + 1))
    fi
  done

  echo ""
  echo "  ──────────────────────────────"
  ok "$signed file(s) signed, $skipped skipped"
  ok "Checksums: $checksums_file"
  ok "Signatures: $SIG_DIR/*.sig"
  echo ""
}

# ── List ──────────────────────────────────────────────────────

list_signatures() {
  echo ""
  echo "  📋 Current Signatures"
  echo "  ═════════════════════"
  echo ""

  if [ ! -d "$SIG_DIR" ]; then
    warn "No signatures directory found"
    return
  fi

  local count=0
  for sig in "$SIG_DIR"/*.sig; do
    [ -f "$sig" ] || continue
    local basename
    basename=$(basename "$sig" .sig)
    local sig_size
    sig_size=$(wc -c < "$sig")
    local hash_file="$SIG_DIR/${basename}.sha256"

    if [ -f "$hash_file" ]; then
      local checksum
      checksum=$(cut -d' ' -f1 < "$hash_file")
      echo "  🔏 $basename"
      echo "     SHA-256: ${checksum:0:16}..."
      echo "     Sig: $sig_size bytes"

      # Check if source file still matches
      local source="$REPO_ROOT/$basename"
      if [ -f "$source" ]; then
        local current
        current=$(sha256sum "$source" | cut -d' ' -f1)
        if [ "$current" = "$checksum" ]; then
          echo "     Status: ✅ matches current file"
        else
          echo "     Status: ⚠️ file has changed since signing"
        fi
      fi
      echo ""
    fi
    count=$((count + 1))
  done

  if [ "$count" -eq 0 ]; then
    warn "No signatures found. Run: $0"
  else
    info "$count signature(s) found"
  fi
  echo ""
}

# ── CLI ───────────────────────────────────────────────────────

main() {
  local single_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --keygen)  generate_keys; exit $? ;;
      --list)    list_signatures; exit 0 ;;
      --file)    shift; single_file="$1" ;;
      --keydir)  shift; KEY_DIR="$1" ;;
      --help|-h)
        echo "Usage: sign-installer.sh [OPTIONS]"
        echo ""
        echo "  --keygen           Generate signing keypair"
        echo "  --file FILE        Sign a single file"
        echo "  --keydir PATH      Custom key directory"
        echo "  --list             Show current signatures"
        echo "  -h, --help         Show this help"
        exit 0
        ;;
      *) single_file="$1" ;;
    esac
    shift
  done

  if [ -n "$single_file" ]; then
    mkdir -p "$SIG_DIR"
    sign_file "$single_file"
  else
    sign_all
  fi
}

main "$@"
