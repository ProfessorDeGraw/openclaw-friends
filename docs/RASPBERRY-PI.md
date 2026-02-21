# Raspberry Pi Setup Guide 🍓

Run OpenClaw on a Raspberry Pi — your own AI assistant on $35 hardware.

---

## Table of Contents

- [Supported Models](#supported-models)
- [Prerequisites](#prerequisites)
- [Step 1: Prepare the Pi](#step-1-prepare-the-pi)
- [Step 2: Install Docker](#step-2-install-docker)
- [Step 3: Install OpenClaw](#step-3-install-openclaw)
- [Step 4: Optimize for Pi](#step-4-optimize-for-pi)
- [Step 5: Verify](#step-5-verify)
- [Performance Tuning](#performance-tuning)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Recommended Accessories](#recommended-accessories)

---

## Supported Models

| Model | RAM | Status | Notes |
|-------|-----|--------|-------|
| **Pi 5** (4GB/8GB) | 4–8 GB | ✅ Recommended | Fast, plenty of RAM |
| **Pi 4** (4GB/8GB) | 4–8 GB | ✅ Works great | Most common choice |
| **Pi 4** (2GB) | 2 GB | ⚠️ Tight | Works with memory tuning |
| **Pi 4** (1GB) | 1 GB | ⚠️ Minimal | Needs swap, single agent only |
| **Pi 3B+** | 1 GB | ⚠️ Minimal | Slow but functional |
| **Pi Zero 2 W** | 512 MB | ❌ Not recommended | Too little RAM |

> **TL;DR:** Get a Pi 4 or 5 with 4GB+ RAM. Use a good SD card or USB SSD.

---

## Prerequisites

- Raspberry Pi with **64-bit OS** (Raspberry Pi OS Lite 64-bit recommended)
- **4GB+ RAM** recommended (2GB minimum)
- **16GB+ SD card** (or better: USB SSD)
- Network connection (Ethernet or Wi-Fi)
- A GitHub Copilot subscription (for the AI model)

---

## Step 1: Prepare the Pi

### 1.1 Flash the OS

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash **Raspberry Pi OS Lite (64-bit)**:

```bash
# Or via CLI if you have rpi-imager installed:
rpi-imager --cli \
  --os "Raspberry Pi OS Lite (64-bit)" \
  --storage /dev/sdX \
  --hostname openclaw-pi \
  --enable-ssh \
  --set-username pi \
  --set-password "your-password"
```

> 💡 **Use Lite (no desktop)** — you don't need a GUI. Save the RAM for OpenClaw.

### 1.2 Boot and Connect

```bash
# Find your Pi on the network
ping openclaw-pi.local

# SSH in
ssh pi@openclaw-pi.local
```

### 1.3 Update the System

```bash
sudo apt update && sudo apt upgrade -y
```

### 1.4 Verify 64-bit Kernel

```bash
uname -m
# Must show: aarch64
# If it shows armv7l, you're on 32-bit — reflash with 64-bit OS

dpkg --print-architecture
# Must show: arm64
```

### 1.5 Reduce GPU Memory (Headless Server)

Free up RAM by minimizing GPU allocation:

```bash
# Set GPU memory to 16MB (minimum for headless)
echo "gpu_mem=16" | sudo tee -a /boot/firmware/config.txt

# Reboot to apply
sudo reboot
```

Verify after reboot:

```bash
vcgencmd get_mem gpu
# Should show: gpu=16M

free -h
# You should see more available RAM now
```

---

## Step 2: Install Docker

```bash
# Install Docker via official script
curl -fsSL https://get.docker.com | sudo sh

# Add your user to the docker group (avoids needing sudo)
sudo usermod -aG docker $USER

# Log out and back in for group change to take effect
exit
# SSH back in
ssh pi@openclaw-pi.local

# Verify
docker run --rm hello-world
docker --version
```

### Enable Docker on Boot

```bash
sudo systemctl enable docker
sudo systemctl enable containerd
```

### Verify ARM64 Support

```bash
docker info --format '{{.Architecture}}'
# Should show: aarch64

docker run --rm arm64v8/alpine uname -m
# Should show: aarch64
```

---

## Step 3: Install OpenClaw

### 3.1 Quick Install

```bash
# Clone the installer
git clone https://github.com/openclaw/openclaw-friends.git
cd openclaw-friends

# Run the installer (auto-detects ARM64)
bash install.sh
```

### 3.2 Manual Install (if install.sh isn't available yet)

```bash
# Create project directory
mkdir -p ~/openclaw-friend && cd ~/openclaw-friend

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  openclaw:
    image: node:22-bookworm-slim
    container_name: openclaw-friend
    restart: unless-stopped
    working_dir: /root
    command: >-
      sh -c "npm install -g openclaw@latest &&
      openclaw gateway --bind lan --port 18789 --allow-unconfigured"
    ports:
      - "18800:18789"
      - "18801:18790"
    volumes:
      - config:/root/.openclaw
      - workspace:/root/.openclaw/workspace
    environment:
      - HOME=/root
      - TERM=xterm-256color
      - NODE_ENV=production
      - NODE_OPTIONS=--max-old-space-size=384
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

volumes:
  config:
  workspace:
EOF

# Start it
docker compose up -d

# Watch logs
docker compose logs -f
```

### 3.3 First Run

```bash
# Wait for npm install to finish (takes 2-5 minutes on Pi)
docker compose logs -f --tail 20

# Once you see "Gateway listening on ...", open the web UI:
echo "Open: http://$(hostname -I | awk '{print $1}'):18801"
```

---

## Step 4: Optimize for Pi

### 4.1 Node.js Memory Limit

Critical on Pi — prevent OOM kills:

```bash
# Already set in docker-compose.yml above, but verify:
docker exec openclaw-friend node -e "
  const v8 = require('v8');
  const heap = v8.getHeapStatistics();
  console.log('Heap limit:', Math.round(heap.heap_size_limit / 1024 / 1024), 'MB');
"
# Should show ~384 MB (not the default 1.5GB+)
```

### 4.2 Add Swap (Essential for 1-2GB Pi)

```bash
# Check current swap
free -h

# Create 2GB swap file
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make it persistent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Set swappiness (lower = prefer RAM, higher = use swap more)
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Verify
free -h
# Should show Swap: 2.0Gi
```

### 4.3 Use a USB SSD (Recommended)

SD cards are slow and wear out. A USB SSD is a massive improvement:

```bash
# Check if USB SSD is detected
lsblk

# If using USB SSD as Docker storage:
sudo systemctl stop docker
sudo mv /var/lib/docker /var/lib/docker.bak

# Mount SSD (assumes /dev/sda1, adjust as needed)
sudo mkdir -p /mnt/ssd
sudo mount /dev/sda1 /mnt/ssd
echo '/dev/sda1 /mnt/ssd ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab

# Move Docker data to SSD
sudo mkdir -p /mnt/ssd/docker
sudo ln -s /mnt/ssd/docker /var/lib/docker
sudo systemctl start docker

# Verify Docker is using the SSD
docker info --format '{{.DockerRootDir}}'
```

### 4.4 Disable Unnecessary Services

```bash
# Disable Bluetooth (if not needed)
sudo systemctl disable bluetooth
sudo systemctl stop bluetooth

# Disable Wi-Fi (if using Ethernet)
# echo "dtoverlay=disable-wifi" | sudo tee -a /boot/firmware/config.txt

# Disable HDMI output (saves ~25mA)
sudo tvservice -o 2>/dev/null || true

# Check what's eating RAM
ps aux --sort=-%mem | head -10
```

### 4.5 Docker Log Rotation

Prevent logs from filling up the SD card:

```bash
# Set global Docker log limits
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
```

---

## Step 5: Verify

```bash
# Check container is running
docker ps

# Check resource usage
docker stats --no-stream openclaw-friend

# Check architecture inside container
docker exec openclaw-friend uname -m
# Should show: aarch64

docker exec openclaw-friend node -e "console.log(process.arch)"
# Should show: arm64

# Check web UI is accessible
curl -sf http://localhost:18801/ | head -5

# Run the ARM64 test suite
bash tests/arm64-test.sh --phase arch
bash tests/arm64-test.sh --phase memory
```

---

## Performance Tuning

### Memory Budget (for multi-agent setups)

| Pi Model | Available RAM | Recommended Setup |
|----------|--------------|-------------------|
| 1GB | ~800MB | 1 agent (384MB limit) + system |
| 2GB | ~1.7GB | 1 agent (512MB limit) + system |
| 4GB | ~3.6GB | 2 agents (512MB each) or 1 agent (1GB) |
| 8GB | ~7.5GB | 3-4 agents (512MB-1GB each) |

```bash
# Check how much RAM is actually available for containers
free -m | awk '/Mem:/{printf "Total: %dMB | Used: %dMB | Free for Docker: ~%dMB\n", $2, $3, $7}'

# Monitor in real-time
watch -n 5 'docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"'
```

### CPU Throttling

Pis throttle under heat. Monitor and prevent:

```bash
# Check current CPU temperature
vcgencmd measure_temp
# Anything above 80°C means throttling

# Check if currently throttled
vcgencmd get_throttled
# 0x0 = no throttling (good)
# 0x50005 = throttled due to temperature (add a fan!)

# Monitor temperature continuously
watch -n 2 vcgencmd measure_temp
```

### Overclock (Pi 4/5, with cooling)

Only if you have a heatsink + fan:

```bash
# Edit config (Pi 4 example)
sudo nano /boot/firmware/config.txt

# Add:
# over_voltage=6
# arm_freq=2000

# Pi 5 (already fast, usually not needed):
# arm_freq=2800

sudo reboot

# Verify new frequency
vcgencmd measure_clock arm
```

---

## Monitoring

### Quick Health Check

```bash
# One-liner system status
echo "=== Pi Health ===" && \
vcgencmd measure_temp && \
echo "CPU: $(top -bn1 | grep Cpu | awk '{print $2}')%" && \
free -h | grep Mem && \
df -h / | tail -1 && \
docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} CPU, {{.MemUsage}}" 2>/dev/null
```

### Cron Monitoring

```bash
# Add to crontab: check every 15 minutes, log warnings
(crontab -l 2>/dev/null; echo "*/15 * * * * /home/pi/openclaw-friend/tests/arm64-test.sh --phase memory --ci >> /var/log/openclaw-health.log 2>&1") | crontab -

# Auto-restart if container dies
(crontab -l 2>/dev/null; echo "*/5 * * * * docker ps -q -f name=openclaw-friend | grep -q . || docker compose -f /home/pi/openclaw-friend/docker-compose.yml up -d >> /var/log/openclaw-restart.log 2>&1") | crontab -
```

---

## Troubleshooting

### Container keeps restarting (OOM killed)

```bash
# Check if OOM killed
docker inspect openclaw-friend --format '{{.State.OOMKilled}}'
# true = out of memory

# Check kernel log for OOM events
dmesg | grep -i "out of memory\|oom" | tail -5

# Fix: reduce Node.js heap size
# In docker-compose.yml, change NODE_OPTIONS:
#   NODE_OPTIONS=--max-old-space-size=256

# Or increase container memory limit:
#   deploy.resources.limits.memory: 768M

# Apply changes
docker compose down && docker compose up -d
```

### Very slow startup

```bash
# First boot installs openclaw via npm — this is slow on Pi (~3-5 min)
# Check progress:
docker compose logs -f | grep -i "npm\|install\|added"

# Speed up future starts by building a local image:
docker exec openclaw-friend sh -c "which openclaw && openclaw --version"
docker commit openclaw-friend openclaw-pi:local

# Update docker-compose.yml to use local image:
# image: openclaw-pi:local
# command: openclaw gateway --bind lan --port 18789 --allow-unconfigured
```

### SD card corruption

```bash
# Check filesystem
sudo fsck -n /dev/mmcblk0p2

# Reduce write wear — mount with noatime
# In /etc/fstab, add noatime option:
# /dev/mmcblk0p2 / ext4 defaults,noatime 0 1

# Move Docker and logs to USB SSD (see Step 4.3)
# Move /var/log to tmpfs:
echo 'tmpfs /var/log tmpfs defaults,noatime,nosuid,size=50m 0 0' | sudo tee -a /etc/fstab
```

### Wi-Fi drops / network issues

```bash
# Use Ethernet if possible — much more reliable

# If Wi-Fi only, disable power management:
sudo iwconfig wlan0 power off

# Make it persistent:
echo 'wireless-power off' | sudo tee -a /etc/network/interfaces

# Or via NetworkManager:
sudo nmcli connection modify "your-wifi" wifi.powersave 2
```

### "exec format error" when running containers

```bash
# This means you're pulling an amd64 image on ARM
# Fix: make sure you're using multi-arch images

# Check image architecture
docker inspect node:22-bookworm-slim --format '{{.Architecture}}'
# Should show: arm64

# If wrong, pull explicitly:
docker pull --platform linux/arm64 node:22-bookworm-slim
```

---

## Recommended Accessories

| Accessory | Why | Approximate Cost |
|-----------|-----|-----------------|
| **USB SSD (128GB+)** | 10x faster than SD, no wear-out | $15–25 |
| **Active cooler / fan** | Prevents throttling | $5–15 |
| **Ethernet cable** | More reliable than Wi-Fi | $5 |
| **Official Pi power supply** | Prevents undervoltage | $10–15 |
| **Case with cooling** | Protection + airflow | $10–20 |

```bash
# Verify power supply is adequate (no undervoltage warnings)
vcgencmd get_throttled
# 0x0 = perfect
# If you see 0x50000 = currently under-voltage — get a better PSU!

dmesg | grep -i "under.voltage\|undervolt"
# Should return nothing
```

---

## Quick Reference

```bash
# Start OpenClaw on Pi
cd ~/openclaw-friend && docker compose up -d

# Stop
docker compose down

# View logs
docker compose logs -f --tail 50

# Check status
docker stats --no-stream openclaw-friend

# Check Pi health
vcgencmd measure_temp && free -h && df -h /

# Update OpenClaw
docker compose down
docker compose pull
docker compose up -d

# Run ARM64 test suite
bash tests/arm64-test.sh

# Backup before changes
docker run --rm -v openclaw-friend_config:/data -v ~/backup:/backup \
  alpine tar czf /backup/openclaw-config-$(date +%F).tar.gz -C /data .
```

---

*Happy hacking on your Pi! 🍓 — The OpenClaw Team 🐾*
