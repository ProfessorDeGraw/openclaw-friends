# OpenClaw Installer Test Matrix 🦉

Comprehensive validation checklist for the OpenClaw installer across OS versions, shell environments, and Docker states.

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ⬜ | Not tested |
| ✅ | Pass |
| ❌ | Fail |
| ⚠️ | Pass with issues (note in comments) |
| N/A | Not applicable |

---

## 1. Windows

### 1.1 Windows 11 (23H2+)

| # | Scenario | Docker Pre-installed | Shell | Result | Notes |
|---|----------|---------------------|-------|--------|-------|
| W1 | Clean install | No | PowerShell 7+ | ⬜ | |
| W2 | Clean install | No | PowerShell 5.1 | ⬜ | |
| W3 | Clean install | Yes (Docker Desktop) | PowerShell 7+ | ⬜ | |
| W4 | Clean install | Yes (Docker Desktop) | PowerShell 5.1 | ⬜ | |
| W5 | Clean install | No | CMD | ⬜ | |
| W6 | WSL2 present, no Docker | No | PowerShell 7+ | ⬜ | |
| W7 | WSL2 + Docker Desktop | Yes | PowerShell 7+ | ⬜ | |
| W8 | Upgrade from previous version | Yes | PowerShell 7+ | ⬜ | |
| W9 | Non-admin user | No | PowerShell 7+ | ⬜ | Should prompt for elevation |
| W10 | Restricted execution policy | No | PowerShell 5.1 | ⬜ | `Set-ExecutionPolicy` handling |

### 1.2 Windows 10 (22H2)

| # | Scenario | Docker Pre-installed | Shell | Result | Notes |
|---|----------|---------------------|-------|--------|-------|
| W11 | Clean install | No | PowerShell 5.1 | ⬜ | |
| W12 | Clean install | Yes (Docker Desktop) | PowerShell 5.1 | ⬜ | |
| W13 | Clean install | No | PowerShell 7+ | ⬜ | |
| W14 | WSL2 absent (WSL1 only) | No | PowerShell 5.1 | ⬜ | Installer should handle WSL upgrade |
| W15 | No WSL at all | No | PowerShell 5.1 | ⬜ | Full WSL2 bootstrap |
| W16 | Upgrade from previous version | Yes | PowerShell 5.1 | ⬜ | |

### Windows Checks (apply to all above)

- [ ] Installer downloads and starts without errors
- [ ] WSL2 installed/enabled if missing
- [ ] Docker Desktop installed if missing
- [ ] Docker starts and responds to `docker info`
- [ ] OpenClaw container pulls and runs
- [ ] Web UI accessible at `http://localhost:18789`
- [ ] Firewall prompt handled gracefully
- [ ] Reboot required → clear messaging to user
- [ ] Uninstall/cleanup works

---

## 2. macOS

### 2.1 macOS Sequoia (15.x) — Apple Silicon

| # | Scenario | Docker Pre-installed | Shell | Result | Notes |
|---|----------|---------------------|-------|--------|-------|
| M1 | Clean install | No | zsh (default) | ⬜ | |
| M2 | Clean install | Yes (Docker Desktop) | zsh | ⬜ | |
| M3 | Clean install | Yes (OrbStack) | zsh | ⬜ | |
| M4 | Clean install | No | bash 3.2 | ⬜ | macOS ships ancient bash |
| M5 | Clean install | No | bash 5 (Homebrew) | ⬜ | |
| M6 | Upgrade from previous version | Yes | zsh | ⬜ | |
| M7 | Homebrew absent | No | zsh | ⬜ | |
| M8 | Homebrew present | No | zsh | ⬜ | |

### 2.2 macOS Sonoma (14.x) — Apple Silicon

| # | Scenario | Docker Pre-installed | Shell | Result | Notes |
|---|----------|---------------------|-------|--------|-------|
| M9 | Clean install | No | zsh | ⬜ | |
| M10 | Clean install | Yes (Docker Desktop) | zsh | ⬜ | |
| M11 | Upgrade from previous version | Yes | zsh | ⬜ | |

### 2.3 macOS Ventura (13.x) — Intel

| # | Scenario | Docker Pre-installed | Shell | Result | Notes |
|---|----------|---------------------|-------|--------|-------|
| M12 | Clean install | No | zsh | ⬜ | |
| M13 | Clean install | Yes (Docker Desktop) | zsh | ⬜ | |
| M14 | Upgrade from previous version | Yes | zsh | ⬜ | |

### macOS Checks (apply to all above)

- [ ] Installer runs without Gatekeeper blocks (or handles them)
- [ ] Rosetta 2 handled for any x86 dependencies (Apple Silicon)
- [ ] Docker installed if missing (Docker Desktop or OrbStack)
- [ ] Docker daemon starts and responds
- [ ] OpenClaw container pulls and runs
- [ ] Web UI accessible at `http://localhost:18789`
- [ ] No SIP (System Integrity Protection) conflicts
- [ ] Works without Xcode Command Line Tools pre-installed
- [ ] Uninstall/cleanup works

---

## 3. Linux

### 3.1 Ubuntu

| # | Distro | Version | Docker Pre-installed | Shell | Result | Notes |
|---|--------|---------|---------------------|-------|--------|-------|
| L1 | Ubuntu | 24.04 LTS | No | bash 5.x | ⬜ | |
| L2 | Ubuntu | 24.04 LTS | Yes (apt) | bash 5.x | ⬜ | |
| L3 | Ubuntu | 24.04 LTS | Yes (snap) | bash 5.x | ⬜ | Snap Docker has quirks |
| L4 | Ubuntu | 22.04 LTS | No | bash 5.x | ⬜ | |
| L5 | Ubuntu | 22.04 LTS | Yes (apt) | bash 5.x | ⬜ | |
| L6 | Ubuntu | 20.04 LTS | No | bash 5.x | ⬜ | |
| L7 | Ubuntu | 24.04 LTS | No | zsh | ⬜ | |

### 3.2 Debian

| # | Distro | Version | Docker Pre-installed | Shell | Result | Notes |
|---|--------|---------|---------------------|-------|--------|-------|
| L8 | Debian | 12 (Bookworm) | No | bash 5.x | ⬜ | |
| L9 | Debian | 12 (Bookworm) | Yes | bash 5.x | ⬜ | |
| L10 | Debian | 11 (Bullseye) | No | bash 5.x | ⬜ | |

### 3.3 Fedora / RHEL

| # | Distro | Version | Docker Pre-installed | Shell | Result | Notes |
|---|--------|---------|---------------------|-------|--------|-------|
| L11 | Fedora | 40 | No (podman default) | bash 5.x | ⬜ | Podman ≠ Docker — handle |
| L12 | Fedora | 40 | Yes (docker-ce) | bash 5.x | ⬜ | |
| L13 | Fedora | 39 | No | bash 5.x | ⬜ | |
| L14 | RHEL | 9 | No | bash 5.x | ⬜ | |
| L15 | AlmaLinux | 9 | No | bash 5.x | ⬜ | |

### 3.4 Arch / Other

| # | Distro | Version | Docker Pre-installed | Shell | Result | Notes |
|---|--------|---------|---------------------|-------|--------|-------|
| L16 | Arch | Rolling | No | bash 5.x | ⬜ | |
| L17 | Arch | Rolling | Yes | zsh | ⬜ | |
| L18 | Raspberry Pi OS | Bookworm (arm64) | No | bash 5.x | ⬜ | ARM64 images |

### Linux Checks (apply to all above)

- [ ] Installer runs with and without `sudo`
- [ ] `curl | bash` one-liner works
- [ ] Docker installed from official repo if missing
- [ ] User added to `docker` group (or handled via rootless)
- [ ] Snap Docker detected and handled (or warned)
- [ ] Podman-only systems: clear error or compatibility shim
- [ ] `systemd` vs `init` handled
- [ ] SELinux (Fedora/RHEL) doesn't block container
- [ ] AppArmor (Ubuntu/Debian) doesn't block container
- [ ] OpenClaw container pulls and runs
- [ ] Web UI accessible at `http://localhost:18789`
- [ ] Uninstall/cleanup works
- [ ] Works on minimal/server installs (no desktop)

---

## 4. Cross-Platform Checks

These apply to **every** test case above.

### Installer Behavior

- [ ] Idempotent — running twice doesn't break anything
- [ ] Existing config preserved on re-install
- [ ] Clear error messages on failure (not raw stack traces)
- [ ] Offline/air-gapped detection with helpful message
- [ ] Proxy/corporate firewall detection
- [ ] Disk space check before pulling images
- [ ] Timeout handling for slow connections

### Post-Install Validation

- [ ] `openclaw status` returns healthy
- [ ] Web UI loads at `http://localhost:18789`
- [ ] First-run wizard triggers (no IDENTITY.md)
- [ ] Assistant responds to messages
- [ ] Container survives host reboot
- [ ] Logs accessible via `openclaw logs` or `docker logs`

### Upgrade Path

- [ ] v0.x → v1.0 upgrade preserves workspace
- [ ] MEMORY.md, SOUL.md, IDENTITY.md survive upgrade
- [ ] Docker image pulls new version correctly
- [ ] Rollback possible if upgrade fails

### Network & Security

- [ ] Works behind NAT (no inbound ports needed)
- [ ] No data sent externally without user-configured API keys
- [ ] HTTPS proxy (`HTTP_PROXY` / `HTTPS_PROXY`) respected
- [ ] Container runs as non-root internally (or warns)

---

## 5. Edge Cases

| # | Scenario | Expected | Result | Notes |
|---|----------|----------|--------|-------|
| E1 | Disk full during install | Graceful error | ⬜ | |
| E2 | Docker daemon dies mid-install | Retry or clear error | ⬜ | |
| E3 | Port 18789 already in use | Detect + suggest alternative | ⬜ | |
| E4 | Non-English system locale | No crashes | ⬜ | |
| E5 | Username with spaces | Paths handled correctly | ⬜ | Windows mainly |
| E6 | Very long PATH variable | No truncation issues | ⬜ | Windows |
| E7 | Multiple Docker contexts | Correct context used | ⬜ | |
| E8 | Docker Compose v1 vs v2 | Both handled | ⬜ | `docker-compose` vs `docker compose` |
| E9 | Existing `.openclaw` directory | Preserved, not overwritten | ⬜ | |
| E10 | ^C during install | Clean partial state | ⬜ | No zombie containers |

---

## How to Use This

1. Pick your row(s) based on the OS you're testing
2. Run the installer
3. Walk through the per-OS checklist + cross-platform checks
4. Mark result (✅/❌/⚠️) and add notes
5. File issues for any ❌ or ⚠️ with the row number (e.g. "W14 fails — WSL1 upgrade loop")

## Priority Order

Test these first — they cover the most users:

1. **W1** — Windows 11, no Docker, PowerShell 7+
2. **M1** — macOS Sequoia, Apple Silicon, no Docker
3. **L1** — Ubuntu 24.04, no Docker
4. **W3** — Windows 11, Docker Desktop exists
5. **L4** — Ubuntu 22.04, no Docker
6. **M9** — macOS Sonoma, no Docker

---

*Last updated: $(date +%Y-%m-%d) — Generated by Nova ⭐*
