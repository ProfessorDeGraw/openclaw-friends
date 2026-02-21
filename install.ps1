# OpenClaw Friends Installer
# Usage (interactive):
#   irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_COPILOT_TOKEN"
# Usage (headless/CI):
#   Install-OpenClaw -CopilotToken "TOKEN" -HeadlessMode -ChannelType discord
# Version/Update:
#   Install-OpenClaw -Version
#   Install-OpenClaw -Update
# Flags:
#   -HeadlessMode     Skip browser launch, suppress interactive prompts, output machine-readable info
#   -ChannelType      Pre-configure a messaging channel: discord, telegram, signal, or none (default: none)
#   -ChannelToken     Bot token for the chosen channel (Discord bot token, Telegram bot token, etc.)
#   -Version          Print installer version and exit
#   -Update           Check for newer version on GitHub and self-update
#   -DryRun           Validate prerequisites without installing anything

function Install-OpenClaw {
    param(
        [Parameter(Mandatory=$false)]
        [string]$CopilotToken = "",

        [switch]$HeadlessMode,

        [ValidateSet("none", "discord", "telegram", "signal")]
        [string]$ChannelType = "none",

        [string]$ChannelToken = "",

        [switch]$Version,

        [switch]$Update,

        [switch]$DryRun
    )

    $ErrorActionPreference = "Stop"
    $script:INSTALLER_VERSION = "1.0.0"
    $script:INSTALLER_REPO = "ProfessorDeGraw/openclaw-friends"
    $script:INSTALLER_BRANCH = "main"
    $script:INSTALLER_FILE = "install.ps1"
    $installDir = "$env:USERPROFILE\openclaw-friend"

    # ── Version flag ──────────────────────────────────────────────
    if ($Version) {
        Write-Host "OpenClaw Friends Installer v$($script:INSTALLER_VERSION)"
        return
    }

    # ── Update flag ───────────────────────────────────────────────
    if ($Update) {
        Write-Host ""
        Write-Host "  Checking for updates..." -ForegroundColor Cyan

        $remoteUrl = "https://raw.githubusercontent.com/$($script:INSTALLER_REPO)/$($script:INSTALLER_BRANCH)/$($script:INSTALLER_FILE)"

        try {
            # Fetch remote script
            $remoteScript = (Invoke-WebRequest -Uri $remoteUrl -UseBasicParsing -TimeoutSec 15).Content

            # Extract remote version
            $remoteVersion = "unknown"
            if ($remoteScript -match 'INSTALLER_VERSION\s*=\s*"([^"]+)"') {
                $remoteVersion = $Matches[1]
            }

            Write-Host "  Local version:  v$($script:INSTALLER_VERSION)" -ForegroundColor Gray
            Write-Host "  Remote version: v$remoteVersion" -ForegroundColor Gray

            if ($remoteVersion -eq $script:INSTALLER_VERSION) {
                Write-Host ""
                Write-Host "  Already up to date!" -ForegroundColor Green
                Write-Host ""
                return
            }

            # Compare versions (simple semver: split on dots, compare numerically)
            function Compare-SemVer {
                param([string]$a, [string]$b)
                $aParts = $a.Split('.') | ForEach-Object { [int]$_ }
                $bParts = $b.Split('.') | ForEach-Object { [int]$_ }
                for ($i = 0; $i -lt [Math]::Max($aParts.Count, $bParts.Count); $i++) {
                    $av = if ($i -lt $aParts.Count) { $aParts[$i] } else { 0 }
                    $bv = if ($i -lt $bParts.Count) { $bParts[$i] } else { 0 }
                    if ($av -lt $bv) { return -1 }
                    if ($av -gt $bv) { return 1 }
                }
                return 0
            }

            $cmp = Compare-SemVer $script:INSTALLER_VERSION $remoteVersion
            if ($cmp -ge 0) {
                Write-Host ""
                Write-Host "  Local version is same or newer. No update needed." -ForegroundColor Green
                Write-Host ""
                return
            }

            Write-Host ""
            Write-Host "  New version available: v$($script:INSTALLER_VERSION) -> v$remoteVersion" -ForegroundColor Yellow

            # Determine where this script lives on disk
            $scriptPath = ""
            # If loaded via irm | iex, we won't have a file path — save to default location
            $defaultPath = Join-Path $installDir "install.ps1"

            if ($MyInvocation.ScriptName -and (Test-Path $MyInvocation.ScriptName)) {
                $scriptPath = $MyInvocation.ScriptName
            } elseif (Test-Path $defaultPath) {
                $scriptPath = $defaultPath
            } else {
                $scriptPath = $defaultPath
            }

            # Back up current version
            if (Test-Path $scriptPath) {
                $backupPath = "$scriptPath.bak"
                Copy-Item -Path $scriptPath -Destination $backupPath -Force
                Write-Host "  Backed up current: $backupPath" -ForegroundColor Gray
            }

            # Write new version
            New-Item -ItemType Directory -Force -Path (Split-Path $scriptPath) | Out-Null
            $remoteScript | Set-Content -Path $scriptPath -Encoding UTF8
            Write-Host "  Updated: $scriptPath" -ForegroundColor Green
            Write-Host ""
            Write-Host "  To use the new version, reload and run:" -ForegroundColor Cyan
            Write-Host "    . `"$scriptPath`"" -ForegroundColor White
            Write-Host "    Install-OpenClaw -Version" -ForegroundColor White
            Write-Host ""

        } catch {
            Write-Host "  Update check failed: $_" -ForegroundColor Red
            Write-Host "  You can update manually from:" -ForegroundColor Yellow
            Write-Host "  https://github.com/$($script:INSTALLER_REPO)" -ForegroundColor Cyan
            Write-Host ""
        }
        return
    }

    # ── Require token for install ─────────────────────────────────
    if (-not $CopilotToken -or $CopilotToken -eq "") {
        Write-Host ""
        Write-Host "  Usage: Install-OpenClaw <CopilotToken> [-HeadlessMode] [-ChannelType discord|telegram|signal] [-ChannelToken <token>]" -ForegroundColor Yellow
        Write-Host "         Install-OpenClaw -Version" -ForegroundColor Gray
        Write-Host "         Install-OpenClaw -Update" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Error: CopilotToken is required for installation." -ForegroundColor Red
        Write-Host ""
        return
    }

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

    # ── Dry-run flag ─────────────────────────────────────────────
    if ($DryRun) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "   OpenClaw Pre-Install Check (Dry Run)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""

        $checks = @()
        $allPassed = $true

        function Add-Check {
            param([string]$Name, [bool]$Pass, [string]$Detail)
            $script:checks += [PSCustomObject]@{ Name=$Name; Pass=$Pass; Detail=$Detail }
            if (-not $Pass) { $script:allPassed = $false }
        }

        # --- Check 1: OS ---
        try {
            $build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
            $isWin11 = [int]$build -ge 22000
            $osName = (Get-CimInstance Win32_OperatingSystem).Caption
            Add-Check "Operating System" $true "$osName (build $build)"
        } catch {
            Add-Check "Operating System" $true "Could not detect version (non-critical)"
        }

        # --- Check 2: PowerShell ---
        $psVer = $PSVersionTable.PSVersion
        Add-Check "PowerShell" ($psVer.Major -ge 5) "v$psVer"

        # --- Check 3: WSL2 ---
        $wslOk = $false
        try {
            $null = wsl --status 2>&1
            if ($LASTEXITCODE -eq 0) { $wslOk = $true }
        } catch {}
        Add-Check "WSL2" $wslOk $(if ($wslOk) { "Installed and available" } else { "Not found — installer will set it up (requires restart)" })

        # --- Check 4: Docker ---
        $dockerOk = $false
        $dockerVer = ""
        try {
            $dockerVer = docker version --format '{{.Server.Version}}' 2>&1
            if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
        } catch {}
        Add-Check "Docker Engine" $dockerOk $(if ($dockerOk) { "v$dockerVer" } else { "Not found — installer will download Docker Desktop" })

        # --- Check 5: Docker Compose ---
        $composeOk = $false
        try {
            $composeVer = docker compose version --short 2>&1
            if ($LASTEXITCODE -eq 0) { $composeOk = $true }
        } catch {}
        Add-Check "Docker Compose" $composeOk $(if ($composeOk) { "v$composeVer" } else { "Not available (comes with Docker Desktop)" })

        # --- Check 6: Port 18789 ---
        $portFree = $true
        try {
            $listeners = netstat -ano 2>$null | Select-String ":18789\s"
            if ($listeners) { $portFree = $false }
        } catch {}
        Add-Check "Port 18789" $portFree $(if ($portFree) { "Available" } else { "IN USE — another service is using this port" })

        # --- Check 7: Disk space ---
        $drive = Get-PSDrive C -ErrorAction SilentlyContinue
        $freeGB = if ($drive) { [math]::Round($drive.Free / 1GB, 1) } else { 0 }
        $diskOk = $freeGB -ge 5
        Add-Check "Disk Space (C:)" $diskOk "${freeGB}GB free $(if ($diskOk) { '(need 5GB+)' } else { '— need at least 5GB' })"

        # --- Check 8: Internet ---
        $netOk = $false
        try {
            $r = Invoke-WebRequest -Uri "https://registry.hub.docker.com/" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $netOk = $true }
        } catch {}
        Add-Check "Internet (Docker Hub)" $netOk $(if ($netOk) { "Reachable" } else { "Cannot reach Docker Hub — check connection/firewall" })

        # --- Check 9: Existing install ---
        $existsAlready = Test-Path $installDir
        Add-Check "Existing Install" $true $(if ($existsAlready) { "Found at $installDir (will be updated)" } else { "Clean — no previous install" })

        # --- Check 10: Token ---
        $tokenOk = $false
        if ($CopilotToken.Length -ge 10 -and $CopilotToken -ne "YOUR_COPILOT_TOKEN" -and $CopilotToken -ne "YOUR_TOKEN") {
            $tokenOk = $true
        }
        Add-Check "Copilot Token" $tokenOk $(if ($tokenOk) { "Provided (length: $($CopilotToken.Length))" } else { "Not provided or invalid — pass -CopilotToken" })

        # --- Check 11: Admin rights ---
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Add-Check "Admin Rights" $true $(if ($isAdmin) { "Running as Administrator" } else { "Not admin — WSL/Docker install may need elevation" })

        # --- Check 12: RAM ---
        try {
            $totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            $ramOk = $totalRAM -ge 4
            Add-Check "System RAM" $ramOk "${totalRAM}GB $(if ($ramOk) { '(4GB+ recommended)' } else { '— may be tight, 4GB+ recommended' })"
        } catch {
            Add-Check "System RAM" $true "Could not detect (non-critical)"
        }

        # --- Print results ---
        Write-Host ""
        $passed = ($checks | Where-Object { $_.Pass }).Count
        $total = $checks.Count

        foreach ($c in $checks) {
            $icon = if ($c.Pass) { "✅" } else { "❌" }
            $color = if ($c.Pass) { "Green" } else { "Red" }
            Write-Host "  $icon " -NoNewline -ForegroundColor $color
            Write-Host "$($c.Name): " -NoNewline -ForegroundColor White
            Write-Host "$($c.Detail)" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "----------------------------------------" -ForegroundColor Cyan

        $critical = $checks | Where-Object { -not $_.Pass -and $_.Name -in @("Port 18789", "Disk Space (C:)", "Internet (Docker Hub)", "Copilot Token") }

        if ($critical.Count -eq 0) {
            Write-Host "  Ready to install! ($passed/$total checks passed)" -ForegroundColor Green
            Write-Host ""
            $blockers = $checks | Where-Object { -not $_.Pass }
            if ($blockers.Count -gt 0) {
                Write-Host "  Note: $(($blockers | ForEach-Object { $_.Name }) -join ', ') not detected" -ForegroundColor Yellow
                Write-Host "  but the installer will handle $(if ($blockers.Count -eq 1) { 'it' } else { 'them' }) automatically." -ForegroundColor Yellow
                Write-Host ""
            }
            Write-Host "  Run without -DryRun to install:" -ForegroundColor White
            Write-Host "    Install-OpenClaw -CopilotToken `"YOUR_TOKEN`"" -ForegroundColor Cyan
        } else {
            Write-Host "  Not ready — $($critical.Count) issue(s) to fix first:" -ForegroundColor Red
            foreach ($c in $critical) {
                Write-Host "    • $($c.Name): $($c.Detail)" -ForegroundColor Red
            }
        }

        Write-Host ""
        return
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
        Write-Host "  Running from: $(Get-Location)" -ForegroundColor Gray
        Write-Host "  Directory: $installDir" -ForegroundColor Gray
        $composeOutput = docker compose up -d 2>&1 | Out-String
        Write-Host $composeOutput -ForegroundColor Gray
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
