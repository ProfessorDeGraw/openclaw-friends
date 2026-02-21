# OpenClaw Offline Bundle Creator
# Creates a self-contained package for air-gapped installations.
#
# Usage:
#   .\bundle-offline.ps1                          # Create bundle in current dir
#   .\bundle-offline.ps1 -OutputPath C:\bundles   # Custom output location
#   .\bundle-offline.ps1 -IncludeDocker           # Include Docker Desktop installer
#
# The bundle contains:
#   - install.ps1 (the installer)
#   - docker-compose.yml (template)
#   - node:22.22.0-bookworm Docker image (saved as .tar)
#   - Config templates
#   - INSTALL-OFFLINE.md (instructions)

param(
    [string]$OutputPath = ".",
    [switch]$IncludeDocker
)

$ErrorActionPreference = "Stop"
$bundleName = "openclaw-offline-bundle-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$bundleDir = Join-Path $OutputPath $bundleName

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   OpenClaw Offline Bundle Creator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
$dockerOk = $false
try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
} catch {}

if (-not $dockerOk) {
    Write-Host "  ERROR: Docker is required to create the bundle" -ForegroundColor Red
    Write-Host "  (Need to pull and save the container image)" -ForegroundColor Gray
    exit 1
}

# Create bundle directory
Write-Host "[1/5] Creating bundle directory..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
New-Item -ItemType Directory -Path "$bundleDir\config" -Force | Out-Null
Write-Host "  Created: $bundleDir" -ForegroundColor Green

# Pull and save Docker image
Write-Host "[2/5] Pulling and saving Docker image..." -ForegroundColor Yellow
Write-Host "  Pulling node:22.22.0-bookworm (this may take a while)..." -ForegroundColor Gray
docker pull node:22.22.0-bookworm 2>&1 | Out-Null
Write-Host "  Saving image to tar..." -ForegroundColor Gray
docker save node:22.22.0-bookworm -o "$bundleDir\node-22.22.0-bookworm.tar"
$imageSize = [math]::Round((Get-Item "$bundleDir\node-22.22.0-bookworm.tar").Length / 1MB)
Write-Host "  Saved: node-22.22.0-bookworm.tar ($imageSize MB)" -ForegroundColor Green

# Optionally include Docker Desktop
if ($IncludeDocker) {
    Write-Host "[2b] Downloading Docker Desktop installer..." -ForegroundColor Yellow
    $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    Invoke-WebRequest -Uri $dockerUrl -OutFile "$bundleDir\DockerDesktopInstaller.exe" -UseBasicParsing
    Write-Host "  Saved: DockerDesktopInstaller.exe" -ForegroundColor Green
}

# Copy installer
Write-Host "[3/5] Copying installer..." -ForegroundColor Yellow
$installerUrl = "https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1"
try {
    Invoke-WebRequest -Uri $installerUrl -OutFile "$bundleDir\install.ps1" -UseBasicParsing
    Write-Host "  Downloaded latest install.ps1" -ForegroundColor Green
} catch {
    # Fall back to local copy
    if (Test-Path ".\install.ps1") {
        Copy-Item ".\install.ps1" "$bundleDir\install.ps1"
        Write-Host "  Copied local install.ps1" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not get install.ps1" -ForegroundColor Yellow
    }
}

# Create config templates
Write-Host "[4/5] Creating config templates..." -ForegroundColor Yellow

@"
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "enabled": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "auth": {
      "mode": "token",
      "token": "`${OPENCLAW_GATEWAY_TOKEN}"
    }
  }
}
"@ | Set-Content "$bundleDir\config\openclaw-template.json" -Encoding UTF8

@"
{
  "github-copilot:github": {
    "token": "YOUR_COPILOT_TOKEN_HERE"
  }
}
"@ | Set-Content "$bundleDir\config\auth-profiles-template.json" -Encoding UTF8

Write-Host "  Config templates created" -ForegroundColor Green

# Create offline install instructions
Write-Host "[5/5] Creating documentation..." -ForegroundColor Yellow

@"
# OpenClaw Offline Installation

## Prerequisites
- Windows 10/11 with WSL2 enabled
- Docker Desktop installed (included in bundle if created with -IncludeDocker)

## Steps

### 1. Install Docker (if needed)
If Docker Desktop is not installed:
``````
.\DockerDesktopInstaller.exe install --quiet --accept-license
``````

### 2. Load the Docker image
``````powershell
docker load -i node-22.22.0-bookworm.tar
``````

### 3. Run the installer
``````powershell
.\install.ps1
# When prompted, enter your GitHub Copilot token
``````

### 4. Verify
``````powershell
docker ps
# Should show openclaw-friend container running
``````

## What's in this bundle
- ``install.ps1`` — OpenClaw installer script
- ``node-22.22.0-bookworm.tar`` — Docker image (pre-pulled)
- ``config/`` — Configuration templates
- ``INSTALL-OFFLINE.md`` — This file
$(if ($IncludeDocker) { "- ``DockerDesktopInstaller.exe`` — Docker Desktop installer" })

## Troubleshooting
- If ``docker load`` fails, ensure Docker Desktop is running
- If the installer can't find the image, it will try to pull — ensure the image is loaded first
- For token issues, see: https://github.com/ProfessorDeGraw/openclaw-friends/blob/main/TROUBLESHOOTING.md

Bundle created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')
"@ | Set-Content "$bundleDir\INSTALL-OFFLINE.md" -Encoding UTF8

Write-Host "  Documentation created" -ForegroundColor Green

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Bundle Created Successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Location: $bundleDir" -ForegroundColor Cyan
Write-Host "  Contents:" -ForegroundColor White
Get-ChildItem $bundleDir -Recurse | ForEach-Object {
    $size = if ($_.PSIsContainer) { "" } else { " ($([math]::Round($_.Length/1KB)) KB)" }
    $rel = $_.FullName.Replace($bundleDir, "").TrimStart("\")
    Write-Host "    $rel$size" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  To create a zip: Compress-Archive -Path '$bundleDir\*' -DestinationPath '$bundleDir.zip'" -ForegroundColor Gray
Write-Host ""
