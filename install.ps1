# OpenClaw Friends Installer
# Usage: irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_COPILOT_TOKEN"

function Install-OpenClaw {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CopilotToken
    )

    $ErrorActionPreference = "Stop"
    $installDir = "$env:USERPROFILE\openclaw"
    $discordWebhook = $null  # Set by config if needed

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   OpenClaw Installer (Friends Edition)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- Step 1: Check prerequisites ---
    Write-Host "[1/7] Checking prerequisites..." -ForegroundColor Yellow

    # Check if WSL2 is available
    $wslInstalled = $false
    try {
        $wslVersion = wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
    } catch {}

    if (-not $wslInstalled) {
        Write-Host "  WSL2 not found. Installing..." -ForegroundColor Yellow
        wsl --install --no-distribution
        Write-Host ""
        Write-Host "  WSL2 installed! You need to RESTART your computer." -ForegroundColor Red
        Write-Host "  After restart, run this command again." -ForegroundColor Red
        Write-Host ""
        # Save state so we can resume
        @{ Step = "post-wsl"; Token = $CopilotToken } | ConvertTo-Json | Set-Content "$env:USERPROFILE\.openclaw-install-state.json"
        
        # Register scheduled task to remind user
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"Write-Host 'Run your OpenClaw installer again after restart!' -ForegroundColor Cyan; Start-Sleep 10`""
        $trigger = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName "OpenClaw-Reminder" -Action $action -Trigger $trigger -Force | Out-Null
        
        return
    }
    Write-Host "  WSL2: OK" -ForegroundColor Green

    # Check if Docker is available
    $dockerInstalled = $false
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $dockerInstalled = $true }
    } catch {}

    if (-not $dockerInstalled) {
        Write-Host "  Docker not found. Installing Docker Desktop..." -ForegroundColor Yellow
        
        # Try winget first
        $wingetAvailable = $false
        try { winget --version 2>&1 | Out-Null; $wingetAvailable = $true } catch {}
        
        if ($wingetAvailable) {
            winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
        } else {
            # Download directly
            $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
            $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
            Write-Host "  Downloading Docker Desktop..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing
            Start-Process -FilePath $dockerInstaller -ArgumentList "install", "--quiet", "--accept-license" -Wait
            Remove-Item $dockerInstaller -Force
        }
        
        Write-Host ""
        Write-Host "  Docker Desktop installed!" -ForegroundColor Green
        Write-Host "  Please START Docker Desktop, wait for it to be ready," -ForegroundColor Yellow
        Write-Host "  then run this command again." -ForegroundColor Yellow
        Write-Host ""
        return
    }
    Write-Host "  Docker: OK ($dockerVersion)" -ForegroundColor Green

    # --- Step 2: Create install directory ---
    Write-Host "[2/7] Setting up directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$installDir\config" | Out-Null
    Write-Host "  Created: $installDir" -ForegroundColor Green

    # --- Step 3: Generate gateway token ---
    Write-Host "[3/7] Generating security token..." -ForegroundColor Yellow
    $gatewayToken = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Write-Host "  Token generated" -ForegroundColor Green

    # --- Step 4: Create config files ---
    Write-Host "[4/7] Creating configuration..." -ForegroundColor Yellow

    # openclaw.json
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
      "token": "$gatewayToken"
    }
  },
  "auth": {
    "profiles": {
      "github-copilot:github": {
        "provider": "github-copilot",
        "mode": "token"
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace",
      "model": {
        "primary": "github-copilot/claude-opus-4.6"
      }
    }
  },
  "tools": {
    "allow": ["group:fs", "group:runtime", "group:sessions", "group:memory", "group:messaging"]
  },
  "channels": {},
  "models": {
    "mode": "merge",
    "providers": {}
  }
}
"@ | Set-Content "$installDir\config\openclaw.json" -Encoding UTF8

    # auth-profiles.json (with the shared copilot token)
    @"
{
  "version": 1,
  "profiles": {
    "github-copilot:github": {
      "type": "token",
      "provider": "github-copilot",
      "token": "$CopilotToken"
    }
  }
}
"@ | Set-Content "$installDir\config\auth-profiles.json" -Encoding UTF8

    # github-copilot.token.json (placeholder — OpenClaw will refresh this)
    @"
{
  "token": "$CopilotToken",
  "refresh": true
}
"@ | Set-Content "$installDir\config\github-copilot.token.json" -Encoding UTF8

    Write-Host "  Config files created" -ForegroundColor Green

    # --- Step 5: Create docker-compose.yml ---
    Write-Host "[5/7] Creating Docker configuration..." -ForegroundColor Yellow

    @"
services:
  openclaw-gateway:
    image: node:22.22.0-bookworm
    container_name: openclaw-gateway
    restart: unless-stopped
    working_dir: /root
    command: >-
      sh -c "git config --global user.email 'openclaw@localhost' &&
      git config --global user.name 'OpenClaw' &&
      cp -f /tmp/openclaw-seed.json /root/.openclaw/openclaw.json &&
      mkdir -p /root/.openclaw/credentials /root/.openclaw/agents/main/agent &&
      cp -f /tmp/copilot-token.json /root/.openclaw/credentials/github-copilot.token.json &&
      cp -f /tmp/auth-profiles.json /root/.openclaw/agents/main/agent/auth-profiles.json &&
      npm install -g openclaw@latest &&
      openclaw doctor --fix &&
      openclaw gateway --bind lan --port 18789 --allow-unconfigured"
    ports:
      - "18789:18789"
      - "18790:18790"
    volumes:
      - openclaw-config:/root/.openclaw
      - openclaw-workspace:/root/.openclaw/workspace
      - ./config/openclaw.json:/tmp/openclaw-seed.json:ro
      - ./config/github-copilot.token.json:/tmp/copilot-token.json:ro
      - ./config/auth-profiles.json:/tmp/auth-profiles.json:ro
    environment:
      - HOME=/root
      - TERM=xterm-256color
      - NODE_ENV=production
      - OPENCLAW_GATEWAY_TOKEN=$gatewayToken

volumes:
  openclaw-config:
  openclaw-workspace:
"@ | Set-Content "$installDir\docker-compose.yml" -Encoding UTF8

    Write-Host "  Docker compose created" -ForegroundColor Green

    # --- Step 6: Start OpenClaw ---
    Write-Host "[6/7] Starting OpenClaw..." -ForegroundColor Yellow
    Push-Location $installDir
    docker compose up -d
    Pop-Location
    
    Write-Host "  OpenClaw is starting! (may take 1-2 minutes to install)" -ForegroundColor Green

    # --- Step 7: Show connection info ---
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   OpenClaw is ready!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Open in your browser:" -ForegroundColor White
    Write-Host "  http://localhost:18789/?token=$gatewayToken" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Your token (save this!): $gatewayToken" -ForegroundColor Yellow
    Write-Host "  Install location: $installDir" -ForegroundColor Gray
    Write-Host ""

    # Save connection info
    @"
OpenClaw Connection Info
========================
URL: http://localhost:18789/?token=$gatewayToken
Token: $gatewayToken
Install: $installDir
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@ | Set-Content "$installDir\CONNECTION-INFO.txt" -Encoding UTF8

    # Open browser
    Start-Process "http://localhost:18789/?token=$gatewayToken"

    # Clean up any install state
    Remove-Item "$env:USERPROFILE\.openclaw-install-state.json" -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName "OpenClaw-Reminder" -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    Write-Host "  Browser opened! Give it a minute to finish installing." -ForegroundColor Green
    Write-Host ""
}
