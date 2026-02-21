# OpenClaw Friends Installer
# Usage: irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_COPILOT_TOKEN"

function Install-OpenClaw {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CopilotToken
    )

    $ErrorActionPreference = "Stop"
    $installDir = "$env:USERPROFILE\openclaw"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   OpenClaw Installer (Friends Edition)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # --- Validate token format ---
    if ($CopilotToken.Length -lt 10) {
        Write-Host "  ERROR: Token looks too short. Check that you pasted the full token." -ForegroundColor Red
        return
    }
    if ($CopilotToken -eq "YOUR_COPILOT_TOKEN" -or $CopilotToken -eq "YOUR_TOKEN") {
        Write-Host "  ERROR: Replace YOUR_TOKEN with the actual token you were given." -ForegroundColor Red
        return
    }

    # --- Step 1: Check prerequisites ---
    Write-Host "[1/7] Checking prerequisites..." -ForegroundColor Yellow

    # Check if WSL2 is available
    $wslInstalled = $false
    try {
        $wslOutput = wsl --status 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
    } catch {
        # wsl command not found at all
    }

    if (-not $wslInstalled) {
        Write-Host "  WSL2 not found. Installing..." -ForegroundColor Yellow
        try {
            wsl --install --no-distribution 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: WSL2 install failed. Try running PowerShell as Administrator." -ForegroundColor Red
                return
            }
        } catch {
            Write-Host "  ERROR: WSL2 install failed: $_" -ForegroundColor Red
            Write-Host "  Try running PowerShell as Administrator." -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "  WSL2 installed! You need to RESTART your computer." -ForegroundColor Red
        Write-Host "  After restart, run this command again." -ForegroundColor Red
        Write-Host ""

        # Try to register a reminder (non-critical, don't fail if no admin)
        try {
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"Write-Host 'Run your OpenClaw installer again after restart!' -ForegroundColor Cyan; Start-Sleep 10`""
            $trigger = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName "OpenClaw-Reminder" -Action $action -Trigger $trigger -Force | Out-Null
            Write-Host "  (A reminder will appear after you log back in)" -ForegroundColor Gray
        } catch {
            Write-Host "  Reminder: run the install command again after reboot." -ForegroundColor Yellow
        }

        return
    }
    Write-Host "  WSL2: OK" -ForegroundColor Green

    # Check if Docker is available and running
    $dockerInstalled = $false
    $dockerVersion = ""
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $dockerInstalled = $true }
    } catch {}

    if (-not $dockerInstalled) {
        Write-Host "  Docker not found. Installing Docker Desktop..." -ForegroundColor Yellow

        $installed = $false

        # Try winget first
        try {
            $null = winget --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Installing via winget..." -ForegroundColor Yellow
                winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $installed = $true }
            }
        } catch {}

        # Fall back to direct download
        if (-not $installed) {
            $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
            $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
            Write-Host "  Downloading Docker Desktop (this may take a few minutes)..." -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing
                Start-Process -FilePath $dockerInstaller -ArgumentList "install", "--quiet", "--accept-license" -Wait
                Remove-Item $dockerInstaller -Force -ErrorAction SilentlyContinue
                $installed = $true
            } catch {
                Write-Host "  ERROR: Docker download/install failed: $_" -ForegroundColor Red
                Write-Host "  Install Docker Desktop manually from https://docker.com/products/docker-desktop" -ForegroundColor Yellow
                return
            }
        }

        Write-Host ""
        Write-Host "  Docker Desktop installed!" -ForegroundColor Green
        Write-Host "  Please:" -ForegroundColor Yellow
        Write-Host "    1. START Docker Desktop" -ForegroundColor Yellow
        Write-Host "    2. Wait for it to say 'Docker Desktop is running'" -ForegroundColor Yellow
        Write-Host "    3. Run this install command again" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    Write-Host "  Docker: OK (v$dockerVersion)" -ForegroundColor Green

    # Verify Docker is actually responding (not just installed but stopped)
    try {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Docker is installed but not running. Start Docker Desktop first." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host "  Docker is installed but not responding. Start Docker Desktop first." -ForegroundColor Red
        return
    }

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

    # auth-profiles.json
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

    # github-copilot.token.json
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
    try {
        $composeOutput = docker compose up -d 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Docker Compose failed to start:" -ForegroundColor Red
            Write-Host "  $composeOutput" -ForegroundColor Red
            Pop-Location
            return
        }
    } catch {
        Write-Host "  ERROR: Failed to start containers: $_" -ForegroundColor Red
        Pop-Location
        return
    }
    Pop-Location

    # Wait for gateway to become ready (up to 90 seconds)
    Write-Host "  Containers started. Waiting for OpenClaw to be ready..." -ForegroundColor Yellow
    $ready = $false
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep -Seconds 5
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:18789/" -UseBasicParsing -TimeoutSec 3 2>&1
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {}
        Write-Host "  Still starting... ($([int](($i+1)*5))s)" -ForegroundColor Gray
    }

    if (-not $ready) {
        Write-Host ""
        Write-Host "  OpenClaw is still starting (this is normal on first run)." -ForegroundColor Yellow
        Write-Host "  It needs to download packages. Check progress with:" -ForegroundColor Yellow
        Write-Host "    cd $installDir && docker compose logs -f" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host "  OpenClaw is ready!" -ForegroundColor Green
    }

    # --- Step 7: Show connection info ---
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   OpenClaw is running!" -ForegroundColor Green
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
    if ($ready) {
        Start-Process "http://localhost:18789/?token=$gatewayToken"
        Write-Host "  Browser opened!" -ForegroundColor Green
    } else {
        Write-Host "  Once it's ready, open: http://localhost:18789/?token=$gatewayToken" -ForegroundColor Cyan
    }
    Write-Host ""

    # Clean up install state and reminder task
    Remove-Item "$env:USERPROFILE\.openclaw-install-state.json" -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName "OpenClaw-Reminder" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
