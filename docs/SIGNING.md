# Installer Signature Verification

OpenClaw install scripts are signed to ensure they haven't been tampered with between release and execution.

## Quick Start

### Verify before running

```bash
# Download the verifier
curl -sL https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/scripts/verify-installer.sh -o verify.sh
chmod +x verify.sh

# Fetch + verify install script
./verify.sh --fetch install.ps1

# Or verify local files
./verify.sh install.ps1
./verify.sh              # verify all signed files
```

### Verify with checksum only (no script needed)

```bash
# Download checksums
curl -sL https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/signatures/CHECKSUMS.txt

# Compare
sha256sum install.ps1
# Match the hash against CHECKSUMS.txt
```

---

## How It Works

```
                    ┌─────────────┐
                    │  Developer  │
                    └──────┬──────┘
                           │
                    sign-installer.sh
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        install.ps1   install.ps1   CHECKSUMS.txt
           .sig          .sha256
              │            │            │
              └────────────┼────────────┘
                           │
                      Git Push
                           │
                     ┌─────▼─────┐
                     │  GitHub   │
                     └─────┬─────┘
                           │
                      User downloads
                           │
                    ┌──────▼──────┐
                    │    User     │
                    └──────┬──────┘
                           │
                  verify-installer.sh
                           │
                  ┌────────┼────────┐
                  ▼        ▼        ▼
              SHA-256   OpenSSL   Public
              check     verify    key
                  │        │        │
                  └────────┼────────┘
                           ▼
                    ✅ Safe to run
                    ❌ Tampered!
```

### Layers of verification

| Layer | What it checks | Protects against |
|-------|---------------|------------------|
| **SHA-256 checksum** | File content matches expected hash | Accidental corruption, CDN tampering |
| **OpenSSL signature** | Hash was signed by our private key | Sophisticated MITM, compromised mirror |
| **Public key pinning** | Signature matches distributed key | Key substitution attacks |

---

## For Maintainers

### Initial setup (one-time)

```bash
cd openclaw-friends

# Generate signing keypair
./scripts/sign-installer.sh --keygen
```

This creates:

| File | Purpose | Share? |
|------|---------|--------|
| `.signing-keys/openclaw-sign.key` | Private key — signs files | ❌ NEVER |
| `.signing-keys/openclaw-sign.pub` | Public key — verifies signatures | ✅ Yes |
| `signatures/openclaw-sign.pub` | Public key (repo copy for users) | ✅ Committed |
| `.signing-keys/key-info.json` | Key metadata | ❌ Local only |

### Sign after changes

```bash
# Sign all install scripts
./scripts/sign-installer.sh

# Sign a single file
./scripts/sign-installer.sh --file install.ps1

# Check current signatures
./scripts/sign-installer.sh --list
```

### Release workflow

```bash
# 1. Make changes to install scripts
vim install.ps1

# 2. Sign
./scripts/sign-installer.sh

# 3. Commit everything
git add install.ps1 signatures/
git commit -m "release: v1.2.3 signed"
git push
```

---

## Verification Modes

### Standard (verify local files)

```bash
./scripts/verify-installer.sh
```

Output:
```
  🔐 OpenClaw Installer Verification
  ═══════════════════════════════════

  ✅ install.ps1: Signature valid (ed25519). Checksum: a1b2c3d4e5f6...
  ✅ install.sh: Signature valid (ed25519). Checksum: f6e5d4c3b2a1...
  ⚠️  upgrade.sh: No signature found

  ──────────────────────────────
  ✅ 2 verified, 1 unsigned
```

### Strict (fail on unsigned)

```bash
./scripts/verify-installer.sh --strict
# Exit code 1 if any file is unsigned
```

### JSON (for CI/CD)

```bash
./scripts/verify-installer.sh --json
```

```json
{
  "verified": true,
  "summary": {"total": 3, "verified": 3, "failed": 0, "unsigned": 0},
  "results": [
    {"file": "install.ps1", "status": "verified", "detail": "Signature valid (ed25519)..."}
  ]
}
```

### Fetch & Verify (download + check)

```bash
./scripts/verify-installer.sh --fetch install.ps1
```

Downloads from GitHub, verifies checksum + signature, reports result.

---

## Cryptography Details

| Property | Value |
|----------|-------|
| **Algorithm** | Ed25519 (preferred) or RSA-2048 (fallback) |
| **Hash** | SHA-256 |
| **Tool** | OpenSSL (no GPG keyring required) |
| **Signature format** | Raw OpenSSL binary signature |
| **Checksum format** | GNU coreutils `sha256sum` compatible |

### Why Ed25519?

- **Fast:** ~60x faster than RSA-2048 for verification
- **Small:** 64-byte signatures (vs 256 for RSA)
- **Modern:** Used by SSH, WireGuard, Signal
- **No configuration:** No key size / padding decisions

### Why not GPG?

GPG requires keyring management, key servers, and trust models that add complexity for end users. OpenSSL is pre-installed on most systems and Ed25519 provides equivalent security with simpler tooling.

---

## Security Considerations

### What this protects against

- ✅ Tampered install scripts (MITM, compromised CDN)
- ✅ Accidental file corruption
- ✅ Unauthorized modifications to release artifacts

### What this does NOT protect against

- ❌ Compromised signing key (rotate immediately if suspected)
- ❌ Compromised GitHub account (attacker could replace key + signatures)
- ❌ Supply chain attacks on dependencies (Docker images, npm packages)

### Key rotation

If the signing key is compromised:

```bash
# 1. Generate new keypair
./scripts/sign-installer.sh --keygen

# 2. Re-sign all files
./scripts/sign-installer.sh

# 3. Commit and announce
git add signatures/
git commit -m "security: rotate signing key"

# 4. Announce the new key fingerprint through a trusted channel
```

---

## .gitignore

Add to your `.gitignore`:

```
# Signing keys (NEVER commit private key)
.signing-keys/
```

The `signatures/` directory **should** be committed — it contains only public data (signatures, checksums, public key).
