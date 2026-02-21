# OpenClaw Friends — Compatibility Matrix

> Last updated: February 2026 · Installer v1.1.0

## Quick Answer

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| **Docker Engine** | 20.10.0 | 24.0+ |
| **Docker Compose** | v2.0.0 | v2.20+ |
| **Docker Desktop** | 4.10.0 | Latest |
| **Node.js** (in container) | 18.x | 22.x (bundled) |
| **OS — Windows** | 10 (1903+) | 11 23H2+ |
| **OS — macOS** | 12 Monterey | 14 Sonoma+ |
| **OS — Linux** | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04+ |
| **WSL** | WSL 2 | WSL 2 (latest) |
| **RAM** | 2 GB | 4 GB+ |
| **Disk** | 2 GB free | 5 GB+ |

---

## Docker Engine Versions

### ✅ Fully Supported

| Version | Release | Notes |
|---------|---------|-------|
| **27.x** | 2024+ | Current stable. All features work. |
| **26.x** | 2024 | Fully supported. |
| **25.x** | 2024 | Fully supported. |
| **24.x** | 2023 | Fully supported. Default on most current distros. |
| **23.x** | 2023 | Supported. |

### ⚠️ Compatible (with caveats)

| Version | Release | Notes |
|---------|---------|-------|
| **22.x** | 2022 | Works. Older BuildKit defaults — may see slower initial pull. |
| **21.x** | 2022 | Works. Some `docker compose` sub-commands may differ slightly. |
| **20.10.x** | 2020–2023 | Minimum supported. Compose V2 plugin required (not bundled in early releases). Use `docker-compose` standalone if V2 unavailable. |

### ❌ Not Supported

| Version | Reason |
|---------|--------|
| **20.10.0–20.10.6** | Known volume mount bugs on WSL2. Upgrade to 20.10.7+. |
| **19.x and older** | Missing Compose V2 plugin support, outdated container runtime, security vulnerabilities. |
| **Docker Toolbox** | Deprecated. Uses VirtualBox instead of native virtualization. Not compatible. |

---

## Docker Compose: V1 vs V2

OpenClaw requires **Docker Compose V2** (the `docker compose` plugin) or the standalone `docker-compose` binary with V2 compatibility.

| Feature | Compose V1 (`docker-compose`) | Compose V2 (`docker compose`) |
|---------|-------------------------------|-------------------------------|
| **Status** | ❌ EOL (July 2023) | ✅ Active |
| **Install** | Standalone binary | Docker CLI plugin (bundled with Docker Desktop) |
| **Compatibility** | Works but unsupported | Fully supported |
| **Named volumes** | ✅ | ✅ |
| **Compose file 3.x** | ✅ | ✅ |
| **`depends_on` health** | ⚠️ Limited | ✅ Full |

### Installer behavior

The `install.sh` script auto-detects compose:

```bash
# Tries V2 plugin first, falls back to standalone
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi
```

### Known Compose issues

| Issue | Affected | Fix |
|-------|----------|-----|
| `docker compose` not found | Docker Engine without plugin | `apt install docker-compose-plugin` |
| `--compatibility` flag needed | Compose V1 with V2 file | Upgrade to Compose V2 |
| Volume permission errors | Compose V2 < 2.5.0 | Upgrade Compose |
| `pull` hangs on ARM | Compose V2 < 2.15.0 | Upgrade or pull images manually |

---

## Operating Systems

### Windows

| Version | Support | Notes |
|---------|---------|-------|
| **Windows 11** | ✅ Full | WSL2 included. Docker Desktop works out of the box. |
| **Windows 10 (2004+)** | ✅ Full | WSL2 available via `wsl --install`. |
| **Windows 10 (1903–1909)** | ⚠️ Partial | WSL2 requires manual KB update. |
| **Windows 10 (pre-1903)** | ❌ No | WSL2 not available. |
| **Windows Server 2019+** | ⚠️ Partial | Docker EE/Moby. No Docker Desktop. Use `install.sh` in WSL2. |
| **Windows 8.1 / 7** | ❌ No | No WSL2 support. |

#### WSL2 Requirements

- **WSL version**: WSL 2 (not WSL 1). Check: `wsl --version`
- **Virtual Machine Platform**: Must be enabled in Windows Features
- **Hyper-V**: Recommended but not strictly required (Docker Desktop uses WSL2 backend)
- **Default distro**: Ubuntu recommended. The installer uses PowerShell, not WSL directly.

#### Common Windows issues

| Issue | Cause | Fix |
|-------|-------|-----|
| "WSL 2 requires an update" | Old WSL kernel | Run `wsl --update` |
| Docker Desktop won't start | Hyper-V conflict | Disable other hypervisors (VirtualBox, VMware) |
| Slow file I/O | Files on Windows filesystem | Keep data in WSL2 filesystem (`\\wsl$\`) |
| `docker` not found in PowerShell | PATH not set | Restart terminal after Docker Desktop install |
| Port already in use (18800) | Another service | Change port in docker-compose.yml |

### macOS

| Version | Support | Notes |
|---------|---------|-------|
| **macOS 14 Sonoma+** | ✅ Full | Apple Silicon native. Docker Desktop optimized. |
| **macOS 13 Ventura** | ✅ Full | |
| **macOS 12 Monterey** | ✅ Full | Minimum for current Docker Desktop. |
| **macOS 11 Big Sur** | ⚠️ Partial | Older Docker Desktop versions only (< 4.25). |
| **macOS 10.15 Catalina** | ⚠️ Limited | Docker Desktop 4.15 max. No security updates. |
| **macOS 10.14 and older** | ❌ No | Docker Desktop dropped support. |

#### Architecture

| Chip | Docker Support | Notes |
|------|---------------|-------|
| **Apple Silicon (M1/M2/M3/M4)** | ✅ Native | Uses `arm64` images. The OpenClaw image (`node:22-bookworm`) supports `arm64`. |
| **Intel** | ✅ Native | Uses `amd64` images. |

#### Common macOS issues

| Issue | Cause | Fix |
|-------|-------|-----|
| "Cannot connect to Docker" | Docker Desktop not running | Start Docker Desktop from Applications |
| Slow volume mounts | macOS ↔ Linux filesystem translation | Use VirtioFS (Docker Desktop settings) |
| Rosetta warnings | M1 running x86 images | All OpenClaw images support arm64 natively |

### Linux

| Distribution | Versions | Support |
|-------------|----------|---------|
| **Ubuntu** | 22.04, 24.04 | ✅ Full — tested |
| **Ubuntu** | 20.04 | ✅ Supported |
| **Debian** | 11 (Bullseye), 12 (Bookworm) | ✅ Full |
| **Fedora** | 38+ | ✅ Full |
| **CentOS Stream** | 9 | ✅ Supported |
| **RHEL** | 8+, 9+ | ✅ Supported (Docker CE or Podman + docker compat) |
| **Arch Linux** | Rolling | ✅ Supported |
| **Alpine** | 3.18+ | ⚠️ Works but untested |
| **Raspberry Pi OS** | Bookworm (64-bit) | ⚠️ Supported — `arm64` images work |

#### Common Linux issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `permission denied` on docker | User not in `docker` group | `sudo usermod -aG docker $USER` then re-login |
| `docker compose` not found | Plugin not installed | `sudo apt install docker-compose-plugin` |
| Container OOM killed | Low memory (< 2GB) | Add swap: `sudo fallocate -l 2G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile` |
| DNS resolution fails | Docker DNS config | Add `"dns": ["8.8.8.8"]` to `/etc/docker/daemon.json` |
| Slow on Raspberry Pi | ARM + limited RAM | Expected. Allow extra startup time (2–3 min). |

---

## ARM / Raspberry Pi

| Board | Architecture | Support | Notes |
|-------|-------------|---------|-------|
| **Raspberry Pi 4/5** (64-bit OS) | `arm64` | ✅ | 4GB+ RAM recommended. Use 64-bit Raspberry Pi OS. |
| **Raspberry Pi 4** (32-bit OS) | `armv7l` | ❌ | `node:22-bookworm` doesn't publish `armv7` images. |
| **Raspberry Pi 3** | `arm64` / `armv7l` | ❌ | Insufficient RAM (1GB). |
| **Other ARM64** (Oracle Cloud, AWS Graviton) | `arm64` | ✅ | Works. Cloud ARM instances are well-supported. |

---

## Container Image

OpenClaw Friends uses `node:22.22.0-bookworm` as its base image.

| Image detail | Value |
|-------------|-------|
| Base | `node:22.22.0-bookworm` (Debian 12) |
| Architectures | `amd64`, `arm64` |
| Size | ~350 MB compressed |
| Node.js | 22.22.0 LTS |
| npm | 10.x |

---

## Network Requirements

| Endpoint | Protocol | Required | Purpose |
|----------|----------|----------|---------|
| `registry.npmjs.org` | HTTPS | ✅ Install | Download `openclaw` npm package |
| `registry-1.docker.io` | HTTPS | ✅ Install | Pull `node:22` base image |
| `production.cloudflare.docker.com` | HTTPS | ✅ Install | Docker image layers |
| `api.github.com` | HTTPS | ❌ Optional | Version checks, updates |
| `discord.com/api` | HTTPS | ❌ Optional | Discord channel |
| `api.telegram.org` | HTTPS | ❌ Optional | Telegram channel |

### Proxy / Firewall

If behind a corporate proxy:

```bash
# Docker daemon proxy
sudo mkdir -p /etc/systemd/system/docker.service.d
echo '[Service]
Environment="HTTP_PROXY=http://proxy:8080"
Environment="HTTPS_PROXY=http://proxy:8080"
Environment="NO_PROXY=localhost,127.0.0.1"' | sudo tee /etc/systemd/system/docker.service.d/proxy.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
```

---

## Port Requirements

| Port | Service | Configurable |
|------|---------|-------------|
| **18800** | Gateway HTTP (mapped to container 18789) | ✅ Edit docker-compose.yml |
| **18801** | Gateway WebSocket (mapped to container 18790) | ✅ Edit docker-compose.yml |

Ensure these ports are not in use by another service. Check with:

```bash
# Linux/macOS
ss -tlnp | grep 18800
# Windows
netstat -ano | findstr 18800
```

---

## Known Issues by Version

| Issue ID | Affected | Severity | Description | Workaround |
|----------|----------|----------|-------------|------------|
| OC-001 | Docker 20.10.0–20.10.6 | 🔴 High | Volume mounts silently fail on WSL2 | Upgrade Docker to 20.10.7+ |
| OC-002 | Compose V1 all | 🟡 Medium | `depends_on` condition syntax ignored | Upgrade to Compose V2 |
| OC-003 | Docker Desktop 4.0–4.5 | 🟡 Medium | WSL2 backend crashes on sleep/resume | Upgrade Docker Desktop |
| OC-004 | macOS + VirtioFS | 🟢 Low | Occasional file watch delays | Restart Docker Desktop |
| OC-005 | Pi 4 (2GB) | 🟡 Medium | OOM during npm install in container | Add 2GB swap |
| OC-006 | Windows + antivirus | 🟢 Low | Slow container startup (15–30s extra) | Exclude Docker dirs from AV scan |
| OC-007 | Podman (rootless) | 🟡 Medium | Volume ownership differs from Docker | Use `--userns=keep-id` |

---

## Version Check

Run the compatibility checker to verify your system:

```bash
# Linux/macOS
bash scripts/check-compat.sh

# Or directly:
curl -fsSL https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/master/scripts/check-compat.sh | bash
```

See [`scripts/check-compat.sh`](../scripts/check-compat.sh) for the full automated check.

---

## Upgrade Path

If you're on an unsupported version:

### Docker Engine (Linux)
```bash
# Remove old
sudo apt-get remove docker docker-engine docker.io containerd runc
# Install current
curl -fsSL https://get.docker.com | sh
```

### Docker Desktop (Windows/macOS)
Download latest from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)

### Docker Compose V1 → V2
```bash
# Install plugin
sudo apt-get install docker-compose-plugin
# Verify
docker compose version
```
