# OpenClaw Friends Installer
# Usage (interactive):
#   irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_COPILOT_TOKEN"
# Usage (headless/CI):
#   Install-OpenClaw -CopilotToken "TOKEN" -HeadlessMode -ChannelType discord
# Flags:
#   -HeadlessMode     Skip browser launch, suppress interactive prompts, output machine-readable info
#   -ChannelType      Pre-configure a messaging channel: discord, telegram, signal, or none (default: none)
#   -ChannelToken     Bot token for the chosen channel (Discord bot token, Telegram bot token, etc.)

function Install-OpenClaw {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CopilotToken,

        [switch]$HeadlessMode,

        [ValidateSet("none", "discord", "telegram", "signal")]
        [string]$ChannelType = "none",

        [string]$ChannelToken = ""
    )

    $ErrorActionPreference = "Stop"
    $installDir = "$env:USERPROFILE\openclaw-friend"

    # --- Output helpers (respect headless mode) ---
    function Log-Step  { param([string]$msg) if (-not $HeadlessMode) { Write-Host $msg -ForegroundColor Yellow } }
    function Log-Ok    { param([string]$msg) if (-not $HeadlessMode) { Write-Host "  $msg" -ForegroundColor Green } }
    function Log-Warn  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "  $msg" -ForegroundColor Yellow } }
    function Log-Err   { param([string]$msg) Write-Host "  ERROR: $msg" -ForegroundColor Red }
    function Log-Info  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "  $msg" -ForegroundColor Cyan } }
    function Log-Gray  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "  $msg" -ForegroundColor Gray } }

    if (-not $HeadlessMode) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "   OpenClaw Installer (Friends Edition)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
    }

    # --- Validate token format ---
    if ($CopilotToken.Length -lt 10) {
        Log-Err "Token looks too short. Check that you pasted the full token."
        return
    }
    if ($CopilotToken -eq "YOUR_COPILOT_TOKEN" -or $CopilotToken -eq "YOUR_TOKEN") {
        Log-Err "Replace YOUR_TOKEN with the actual token you were given."
        return
    }

    # --- Validate channel config ---
    if ($ChannelType -ne "none" -and $ChannelToken -eq "") {
        Log-Warn "No -ChannelToken provided for $ChannelType. Channel will be configured but you'll need to add the token later."
    }

    # --- Step 1: Check prerequisites ---
    Log-Step "[1/7] Checking prerequisites..."

    # Check if WSL2 is available
    $wslInstalled = $false
    try {
        $wslOutput = wsl --status 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
    } catch {
        # wsl command not found at all
    }

    if (-not $wslInstalled) {
        Log-Warn "WSL2 not found. Installing..."
        try {
            wsl --install --no-distribution 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Log-Err "WSL2 install failed. Try running PowerShell as Administrator."
                return
            }
        } catch {
            Log-Err "WSL2 install failed: $_"
            Log-Warn "Try running PowerShell as Administrator."
            return
        }

        if ($HeadlessMode) {
            Write-Host "REBOOT_REQUIRED"
        } else {
            Write-Host ""
            Write-Host "  WSL2 installed! You need to RESTART your computer." -ForegroundColor Red
            Write-Host "  After restart, run this command again." -ForegroundColor Red
            Write-Host ""
        }

        # Try to register a reminder (non-critical, don't fail if no admin)
        if (-not $HeadlessMode) {
            try {
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"Write-Host 'Run your OpenClaw installer again after restart!' -ForegroundColor Cyan; Start-Sleep 10`""
                $trigger = New-ScheduledTaskTrigger -AtLogon
                Register-ScheduledTask -TaskName "OpenClaw-Reminder" -Action $action -Trigger $trigger -Force | Out-Null
                Log-Gray "(A reminder will appear after you log back in)"
            } catch {
                Log-Warn "Reminder: run the install command again after reboot."
            }
        }

        return
    }
    Log-Ok "WSL2: OK"

    # Check if Docker is available and running
    $dockerInstalled = $false
    $dockerVersion = ""
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $dockerInstalled = $true }
    } catch {}

    if (-not $dockerInstalled) {
        Log-Warn "Docker not found. Installing Docker Desktop..."

        $installed = $false

        # Try winget first
        try {
            $null = winget --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                Log-Warn "Installing via winget..."
                winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $installed = $true }
            }
        } catch {}

        # Fall back to direct download
        if (-not $installed) {
            $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
            $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
            Log-Warn "Downloading Docker Desktop (this may take a few minutes)..."
            try {
                Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing
                Start-Process -FilePath $dockerInstaller -ArgumentList "install", "--quiet", "--accept-license" -Wait
                Remove-Item $dockerInstaller -Force -ErrorAction SilentlyContinue
                $installed = $true
            } catch {
                Log-Err "Docker download/install failed: $_"
                Log-Warn "Install Docker Desktop manually from https://docker.com/products/docker-desktop"
                return
            }
        }

        Log-Ok "Docker Desktop installed! Trying to start it..."
        try {
            Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
        } catch {}
    }

    # Wait for Docker daemon to be ready (retry up to 2 minutes)
    Log-Step "  Waiting for Docker to be ready (up to 2 minutes)..."
    if (-not $HeadlessMode) {
        Log-Warn "If Docker Desktop isn't open, please start it now."
    }
    $dockerReady = $false
    for ($retry = 0; $retry -lt 24; $retry++) {
        try {
            $null = docker version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerReady = $true
                break
            }
        } catch {}
        if ($retry -eq 0) {
            # Try launching Docker Desktop if not running
            try {
                Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
            } catch {}
        }
        $elapsed = [int](($retry + 1) * 5)
        Log-Gray "Docker not ready yet... retrying in 5s (${elapsed}s / 120s)"
        Start-Sleep -Seconds 5
    }

    if (-not $dockerReady) {
        if ($HeadlessMode) {
            Log-Err "Docker not responding after 120s."
        } else {
            Write-Host ""
            Write-Host "  Docker is not responding after 2 minutes." -ForegroundColor Red
            Write-Host "  Please:" -ForegroundColor Yellow
            Write-Host "    1. Open Docker Desktop manually" -ForegroundColor Yellow
            Write-Host "    2. Wait for it to say 'Docker Desktop is running'" -ForegroundColor Yellow
            Write-Host "    3. Run this install command again" -ForegroundColor Yellow
            Write-Host ""
        }
        return
    }

    $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
    Log-Ok "Docker: OK (v$dockerVersion)"

    # --- Step 2: Create install directory ---
    Log-Step "[2/7] Setting up directory..."
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$installDir\config" | Out-Null
    Log-Ok "Created: $installDir"

    # --- Step 3: Generate gateway token ---
    Log-Step "[3/7] Generating security token..."
    $gatewayToken = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Log-Ok "Token generated"

    # --- Step 4: Create config files ---
    Log-Step "[4/7] Creating configuration..."

    # Build channel configuration based on -ChannelType
    $channelConfig = "{}"
    switch ($ChannelType) {
        "discord" {
            $discordToken = if ($ChannelToken) { $ChannelToken } else { "PASTE_DISCORD_BOT_TOKEN_HERE" }
            $channelConfig = @"
{
      "discord": {
        "adapter": "discord",
        "token": "$discordToken",
        "enabled": true
      }
    }
"@
        }
        "telegram" {
            $telegramToken = if ($ChannelToken) { $ChannelToken } else { "PASTE_TELEGRAM_BOT_TOKEN_HERE" }
            $channelConfig = @"
{
      "telegram": {
        "adapter": "telegram",
        "token": "$telegramToken",
        "enabled": true
      }
    }
"@
        }
        "signal" {
            $signalNumber = if ($ChannelToken) { $ChannelToken } else { "PASTE_SIGNAL_NUMBER_HERE" }
            $channelConfig = @"
{
      "signal": {
        "adapter": "signal",
        "number": "$signalNumber",
        "enabled": true
      }
    }
"@
        }
    }

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
  "channels": $channelConfig,
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

    # SOUL.md for the workspace
    @"
# SOUL.md - Who Is Your Assistant?

_This file defines your assistant's personality. Edit it however you like._

## Personality
- Friendly and casual, but not over the top
- Clear and concise - no walls of text
- Light humor when appropriate

## Principles
- Be helpful first, clever second
- If you don't know something, say so
- Respect the human's time

## Kate Connection
- You can reach Kate (the original OpenClaw) by posting to Discord
- Use this in your tools: curl -X POST "https://discord.com/api/webhooks/1474709375800049765/WZYloKJUvuw_UjjK9MZGGWvUMPDUSp8D95X3UPI7E94V3G4ROU87L3yII2FPAamrbLZV" -H "Content-Type: application/json" -d '{"username":"Friend OpenClaw","content":"your message"}'
- Kate will see your message in Discord and can help

---
_Make it yours._
"@ | Set-Content "$installDir\config\SOUL.md" -Encoding UTF8

    Log-Ok "Config files created"
    if ($ChannelType -ne "none") {
        Log-Ok "Channel pre-configured: $ChannelType"
        if ($ChannelToken -eq "") {
            Log-Warn "Remember to update the placeholder token in $installDir\config\openclaw.json"
        }
    }

    # --- Step 5: Create docker-compose.yml ---
    Log-Step "[5/7] Creating Docker configuration..."

    @"
services:
  openclaw-gateway:
    image: node:22.22.0-bookworm
    container_name: openclaw-friend
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
      cp -f /tmp/SOUL.md /root/.openclaw/workspace/SOUL.md &&
      openclaw doctor --fix &&
      openclaw gateway --bind lan --port 18789 --allow-unconfigured"
    ports:
      - "18800:18789"
      - "18801:18790"
    volumes:
      - friend-config:/root/.openclaw
      - friend-workspace:/root/.openclaw/workspace
      - ./config/openclaw.json:/tmp/openclaw-seed.json:ro
      - ./config/github-copilot.token.json:/tmp/copilot-token.json:ro
      - ./config/auth-profiles.json:/tmp/auth-profiles.json:ro
      - ./config/SOUL.md:/tmp/SOUL.md:ro
    environment:
      - HOME=/root
      - TERM=xterm-256color
      - NODE_ENV=production
      - OPENCLAW_GATEWAY_TOKEN=$gatewayToken

volumes:
  friend-config:
  friend-workspace:
"@ | Set-Content "$installDir\docker-compose.yml" -Encoding UTF8

    Log-Ok "Docker compose created"

    # --- Step 6: Start OpenClaw ---
    Log-Step "[6/7] Starting OpenClaw..."
    Push-Location $installDir
    try {
        $composeOutput = docker compose up -d 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Log-Err "Docker Compose failed to start: $composeOutput"
            Pop-Location
            return
        }
    } catch {
        Log-Err "Failed to start containers: $_"
        Pop-Location
        return
    }
    Pop-Location

    # Wait for gateway to become ready (up to 3 minutes)
    Log-Step "  Containers started. Waiting for OpenClaw gateway to be ready (up to 3 minutes)..."
    Log-Gray "First run downloads packages — this is normal."
    $ready = $false
    for ($i = 0; $i -lt 36; $i++) {
        Start-Sleep -Seconds 5
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:18800/" -UseBasicParsing -TimeoutSec 3 2>&1
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {}
        $elapsed = [int](($i + 1) * 5)
        Log-Gray "Still starting... (${elapsed}s / 180s)"
    }

    if (-not $ready) {
        if (-not $HeadlessMode) {
            Write-Host ""
            Log-Warn "OpenClaw is still starting (this is normal on first run)."
            Log-Warn "It needs to download packages. Check progress with:"
            Log-Info "cd $installDir && docker compose logs -f"
            Write-Host ""
        }
    } else {
        Log-Ok "OpenClaw is ready!"
    }

    # --- Step 7: Show connection info ---
    $url = "http://localhost:18800/?token=$gatewayToken"

    # Save connection info
    @"
OpenClaw Connection Info
========================
URL: $url
Token: $gatewayToken
Install: $installDir
Channel: $ChannelType
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@ | Set-Content "$installDir\CONNECTION-INFO.txt" -Encoding UTF8

    if ($HeadlessMode) {
        # Machine-readable output for scripts/CI
        Write-Host "INSTALL_OK"
        Write-Host "URL=$url"
        Write-Host "TOKEN=$gatewayToken"
        Write-Host "DIR=$installDir"
        Write-Host "CHANNEL=$ChannelType"
        Write-Host "READY=$($ready.ToString().ToLower())"
    } else {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "   OpenClaw is running!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Open in your browser:" -ForegroundColor White
        Write-Host "  $url" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Your token (save this!): $gatewayToken" -ForegroundColor Yellow
        Write-Host "  Install location: $installDir" -ForegroundColor Gray
        if ($ChannelType -ne "none") {
            Write-Host "  Channel: $ChannelType (pre-configured)" -ForegroundColor Gray
        }
        Write-Host ""

        # Open browser (interactive only)
        if ($ready) {
            Start-Process $url
            Write-Host "  Browser opened!" -ForegroundColor Green
        } else {
            Write-Host "  Once it's ready, open: $url" -ForegroundColor Cyan
        }
        Write-Host ""

        # --- Getting Started Checklist ---
        Write-Host "----------------------------------------" -ForegroundColor Cyan
        Write-Host "   Getting Started" -ForegroundColor Cyan
        Write-Host "----------------------------------------" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Open the web UI and say hello!" -ForegroundColor White
        Write-Host "      $url" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [2] Give your AI a name and personality" -ForegroundColor White
        Write-Host "      Edit SOUL.md in the workspace to customize" -ForegroundColor Gray
        Write-Host ""

        if ($ChannelType -eq "none") {
            Write-Host "  [3] Add a messaging channel (optional)" -ForegroundColor White
            Write-Host "      Re-run with -ChannelType discord|telegram|signal" -ForegroundColor Gray
            Write-Host "      Or configure manually in openclaw.json" -ForegroundColor Gray
        } else {
            Write-Host "  [3] $ChannelType is pre-configured" -ForegroundColor White
            if ($ChannelToken -eq "") {
                Write-Host "      Add your bot token to: $installDir\config\openclaw.json" -ForegroundColor Gray
            } else {
                Write-Host "      Should be connected once the gateway starts" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "  [4] Check status anytime" -ForegroundColor White
        Write-Host "      cd $installDir && docker compose logs -f" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [5] Stop / restart" -ForegroundColor White
        Write-Host "      cd $installDir && docker compose down" -ForegroundColor Gray
        Write-Host "      cd $installDir && docker compose up -d" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Need help? Check TROUBLESHOOTING.md or ask in Discord" -ForegroundColor Yellow
        Write-Host ""
    }

    # Clean up install state and reminder task
    Remove-Item "$env:USERPROFILE\.openclaw-install-state.json" -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName "OpenClaw-Reminder" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
