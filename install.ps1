# OpenClaw Friends Installer
# Usage (interactive):
#   irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw
# Usage (headless/CI):
#   Install-OpenClaw [-CopilotToken "TOKEN"] [-HeadlessMode] [-ChannelType discord|telegram|signal] [-ChannelToken <token>]
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
#   -Telemetry        Enable anonymous install telemetry (local log only)

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

        [switch]$DryRun,

        [switch]$Telemetry
    )

    $ErrorActionPreference = "Stop"
    $script:INSTALLER_VERSION = "1.1.0"
    $script:INSTALLER_REPO = "ProfessorDeGraw/openclaw-friends"
    $script:INSTALLER_BRANCH = "main"
    $script:INSTALLER_FILE = "install.ps1"

    # --- Telemetry (opt-in only) ---
    function Send-Telemetry {
        param(
            [string]$Event,
            [hashtable]$Data = @{}
        )
        if (-not $Telemetry) { return }
        try {
            $payload = @{
                event = $Event
                installer_version = $script:INSTALLER_VERSION
                os = [System.Environment]::OSVersion.VersionString
                arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
                timestamp = (Get-Date -Format "o")
                session_id = $script:telemetrySessionId
            }
            foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
            # Write to local telemetry log (no network calls)
            $logDir = Join-Path $env:TEMP "openclaw-telemetry"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $logFile = Join-Path $logDir "install-telemetry.jsonl"
            ($payload | ConvertTo-Json -Compress) | Add-Content $logFile
        } catch {}
    }
    $script:telemetrySessionId = [guid]::NewGuid().ToString("N").Substring(0, 12)
    $installDir = "$env:USERPROFILE\openclaw-friend"

    # ══════════════════════════════════════════════════════════════
    # Progress Bar System
    # ══════════════════════════════════════════════════════════════

    $script:Steps = @(
        @{ Name = "Prerequisites";      Desc = "Checking Docker & WSL2" }
        @{ Name = "Directory";           Desc = "Creating install directory" }
        @{ Name = "Security";            Desc = "Generating gateway token" }
        @{ Name = "Configuration";       Desc = "Writing config files" }
        @{ Name = "Docker Compose";      Desc = "Creating container setup" }
        @{ Name = "Launch";              Desc = "Starting containers" }
        @{ Name = "Ready";               Desc = "Verifying gateway" }
    )
    $script:TotalSteps = $script:Steps.Count
    $script:CurrentStep = 0
    $script:StepStartTime = $null
    $script:InstallStartTime = Get-Date
    $script:BarWidth = 30

    function Show-Progress {
        <#
        .SYNOPSIS
            Render a visual progress bar with step name, percentage, and elapsed time.
        #>
        param(
            [int]$Step,
            [string]$Status = "",
            [switch]$Sub,        # indented sub-status (no bar redraw)
            [switch]$Complete    # final 100% bar
        )

        if ($HeadlessMode) { return }

        if ($Complete) {
            $pct = 100
            $filled = $script:BarWidth
            $empty = 0
            $elapsed = ((Get-Date) - $script:InstallStartTime).TotalSeconds
            $timeStr = "{0:N0}s total" -f $elapsed
            $stepLabel = "Installation complete"
            $bar = ("█" * $filled)
            Write-Host ""
            Write-Host "  ┌──────────────────────────────────────┐" -ForegroundColor Green
            Write-Host "  │ $bar │ 100%" -ForegroundColor Green
            Write-Host "  └──────────────────────────────────────┘" -ForegroundColor Green
            Write-Host "  ✓ $stepLabel ($timeStr)" -ForegroundColor Green
            Write-Host ""
            return
        }

        if ($Sub) {
            # Sub-status line (no bar, just indented info)
            if ($Status) {
                Write-Host "    › $Status" -ForegroundColor Gray
            }
            return
        }

        $script:CurrentStep = $Step
        $script:StepStartTime = Get-Date

        $pct = [math]::Floor(($Step / $script:TotalSteps) * 100)
        $filled = [math]::Floor(($Step / $script:TotalSteps) * $script:BarWidth)
        $empty = $script:BarWidth - $filled
        $bar = ("█" * $filled) + ("░" * $empty)

        $stepInfo = $script:Steps[$Step - 1]
        $stepLabel = $stepInfo.Name
        $stepDesc = $stepInfo.Desc
        if ($Status) { $stepDesc = $Status }

        $elapsed = ((Get-Date) - $script:InstallStartTime).TotalSeconds
        $timeStr = "{0:N0}s" -f $elapsed

        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │ $bar │ $pct%" -ForegroundColor Cyan
        Write-Host "  └──────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host "  [$Step/$script:TotalSteps] $stepLabel — $stepDesc ($timeStr)" -ForegroundColor Yellow
    }

    function Show-WaitProgress {
        <#
        .SYNOPSIS
            Show a waiting spinner/counter for long-running sub-operations.
        #>
        param(
            [int]$Current,
            [int]$Max,
            [string]$Label
        )
        if ($HeadlessMode) { return }

        $waitPct = [math]::Floor(($Current / $Max) * 100)
        $miniLen = 10
        $miniFilled = [math]::Floor(($Current / $Max) * $miniLen)
        $miniEmpty = $miniLen - $miniFilled
        $miniBar = ("▓" * $miniFilled) + ("░" * $miniEmpty)
        Write-Host "    ⏳ [$miniBar] ${Current}s/${Max}s — $Label" -ForegroundColor Gray
    }

    # ══════════════════════════════════════════════════════════════
    # Output Helpers
    # ══════════════════════════════════════════════════════════════

    function Log-Ok    { param([string]$msg) if (-not $HeadlessMode) { Write-Host "    ✓ $msg" -ForegroundColor Green } }
    function Log-Warn  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "    ⚠ $msg" -ForegroundColor Yellow } }
    function Log-Err   { param([string]$msg) Write-Host "    ✗ ERROR: $msg" -ForegroundColor Red }
    function Log-Info  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "    $msg" -ForegroundColor Cyan } }
    function Log-Gray  { param([string]$msg) if (-not $HeadlessMode) { Write-Host "    $msg" -ForegroundColor Gray } }

    # ── Checksum verification helper ──
    function Verify-FileChecksum {
        param(
            [string]$FilePath,
            [string]$ExpectedHash,
            [string]$Algorithm = "SHA256"
        )
        if (-not $ExpectedHash) { return $true }
        if (-not (Test-Path $FilePath)) { return $false }
        $actual = (Get-FileHash -Path $FilePath -Algorithm $Algorithm).Hash
        if ($actual -eq $ExpectedHash) {
            Log-Ok "Checksum verified ($Algorithm)"
            return $true
        } else {
            Log-Warn "Checksum mismatch! Expected: $ExpectedHash"
            Log-Warn "                   Got:      $actual"
            return $false
        }
    }

    function Verify-ConfigIntegrity {
        param([string]$Dir)
        $issues = @()
        Get-ChildItem "$Dir\config\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $null = Get-Content $_.FullName -Raw | ConvertFrom-Json
            } catch {
                $issues += "Invalid JSON: $($_.Name)"
            }
        }
        $composePath = "$Dir\docker-compose.yml"
        if (Test-Path $composePath) {
            $content = Get-Content $composePath -Raw
            if ($content.Length -lt 100) {
                $issues += "docker-compose.yml appears truncated ($($content.Length) bytes)"
            }
            if ($content -notmatch "openclaw") {
                $issues += "docker-compose.yml missing openclaw service"
            }
        }
        return $issues
    }

    # ══════════════════════════════════════════════════════════════
    # Version / Update / DryRun (unchanged logic, abbreviated)
    # ══════════════════════════════════════════════════════════════

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
            $remoteScript = (Invoke-WebRequest -Uri $remoteUrl -UseBasicParsing -TimeoutSec 15).Content

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

            $scriptPath = ""
            $defaultPath = Join-Path $installDir "install.ps1"

            if ($MyInvocation.ScriptName -and (Test-Path $MyInvocation.ScriptName)) {
                $scriptPath = $MyInvocation.ScriptName
            } elseif (Test-Path $defaultPath) {
                $scriptPath = $defaultPath
            } else {
                $scriptPath = $defaultPath
            }

            if (Test-Path $scriptPath) {
                $backupPath = "$scriptPath.bak"
                Copy-Item -Path $scriptPath -Destination $backupPath -Force
                Write-Host "  Backed up current: $backupPath" -ForegroundColor Gray
            }

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

    # ── Resolve token (param → env → interactive → skip) ────────
    if (-not $CopilotToken -or $CopilotToken -eq "") {
        # Try environment variable
        if ($env:COPILOT_TOKEN) {
            $CopilotToken = $env:COPILOT_TOKEN
            Log-Ok "Token loaded from COPILOT_TOKEN environment variable"
        } elseif (-not $HeadlessMode) {
            # Interactive prompt
            Write-Host ""
            Write-Host "  Enter your Copilot token (or press Enter to skip):" -ForegroundColor Yellow
            Write-Host "  You can add it later in config/github-copilot.token.json" -ForegroundColor Gray
            Write-Host ""
            $tokenInput = Read-Host "  Token"
            if ($tokenInput -and $tokenInput.Trim() -ne "") {
                $CopilotToken = $tokenInput.Trim()
            }
        }
    }
    $hasToken = ($CopilotToken -and $CopilotToken -ne "" -and $CopilotToken.Length -ge 10 -and
                 $CopilotToken -ne "YOUR_COPILOT_TOKEN" -and $CopilotToken -ne "YOUR_TOKEN")

    # ── Dry-run flag ──────────────��───────────────────────────────
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

        try {
            $build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
            $osName = (Get-CimInstance Win32_OperatingSystem).Caption
            Add-Check "Operating System" $true "$osName (build $build)"
        } catch { Add-Check "Operating System" $true "Could not detect version (non-critical)" }

        $psVer = $PSVersionTable.PSVersion
        Add-Check "PowerShell" ($psVer.Major -ge 5) "v$psVer"

        $wslOk = $false
        try { $null = wsl --status 2>&1; if ($LASTEXITCODE -eq 0) { $wslOk = $true } } catch {}
        Add-Check "WSL2" $wslOk $(if ($wslOk) { "Installed" } else { "Not found — installer will set it up" })

        $dockerOk = $false; $dockerVer = ""
        try { $dockerVer = docker version --format '{{.Server.Version}}' 2>&1; if ($LASTEXITCODE -eq 0) { $dockerOk = $true } } catch {}
        Add-Check "Docker Engine" $dockerOk $(if ($dockerOk) { "v$dockerVer" } else { "Not found — installer will download Docker Desktop" })

        $composeOk = $false
        try { $composeVer = docker compose version --short 2>&1; if ($LASTEXITCODE -eq 0) { $composeOk = $true } } catch {}
        Add-Check "Docker Compose" $composeOk $(if ($composeOk) { "v$composeVer" } else { "Not available (comes with Docker Desktop)" })

        $portFree = $true
        try { $listeners = netstat -ano 2>$null | Select-String ":18789\s"; if ($listeners) { $portFree = $false } } catch {}
        Add-Check "Port 18789" $portFree $(if ($portFree) { "Available" } else { "IN USE" })

        $drive = Get-PSDrive C -ErrorAction SilentlyContinue
        $freeGB = if ($drive) { [math]::Round($drive.Free / 1GB, 1) } else { 0 }
        Add-Check "Disk Space (C:)" ($freeGB -ge 5) "${freeGB}GB free (need 5GB+)"

        $netOk = $false
        try { $r = Invoke-WebRequest -Uri "https://registry.hub.docker.com/" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop; if ($r.StatusCode -eq 200) { $netOk = $true } } catch {}
        Add-Check "Internet (Docker Hub)" $netOk $(if ($netOk) { "Reachable" } else { "Cannot reach Docker Hub" })

        Add-Check "Existing Install" $true $(if (Test-Path $installDir) { "Found at $installDir (will be updated)" } else { "Clean install" })

        Add-Check "Copilot Token" $hasToken $(if ($hasToken) { "Provided (length: $($CopilotToken.Length))" } else { "Not provided — can add after install" })

        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Add-Check "Admin Rights" $true $(if ($isAdmin) { "Running as Administrator" } else { "Not admin — WSL/Docker install may need elevation" })

        try {
            $totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            Add-Check "System RAM" ($totalRAM -ge 4) "${totalRAM}GB (4GB+ recommended)"
        } catch { Add-Check "System RAM" $true "Could not detect" }

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
        $critical = $checks | Where-Object { -not $_.Pass -and $_.Name -in @("Port 18789", "Disk Space (C:)", "Internet (Docker Hub)") }

        if ($critical.Count -eq 0) {
            Write-Host "  Ready to install! ($passed/$total checks passed)" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Run without -DryRun to install:" -ForegroundColor White
            Write-Host "    Install-OpenClaw" -ForegroundColor Cyan
        } else {
            Write-Host "  Not ready — $($critical.Count) issue(s) to fix first:" -ForegroundColor Red
            foreach ($c in $critical) {
                Write-Host "    • $($c.Name): $($c.Detail)" -ForegroundColor Red
            }
        }
        Write-Host ""
        return
    }

    # ══════════════════════════════════════════════════════════════
    # Main Installation Flow
    # ══════════════════════════════════════════════════════════════

    # --- Validate inputs ---
    if ($CopilotToken -and $CopilotToken.Length -gt 0 -and $CopilotToken.Length -lt 10) {
        Log-Warn "Token looks short ($($CopilotToken.Length) chars). Continuing anyway — you can update it later."
        $hasToken = $false
    }
    if ($CopilotToken -eq "YOUR_COPILOT_TOKEN" -or $CopilotToken -eq "YOUR_TOKEN") {
        Log-Warn "Placeholder token detected. Install will proceed without credentials."
        $hasToken = $false
        $CopilotToken = ""
    }
    if (-not $hasToken) {
        Log-Warn "No Copilot token — installing without LLM credentials. Add token later to config/github-copilot.token.json"
    }
    if ($ChannelType -ne "none" -and $ChannelToken -eq "") {
        Log-Warn "No -ChannelToken provided for $ChannelType. You'll need to add the token later."
    }

    if (-not $HeadlessMode) {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║   OpenClaw Installer (Friends Ed.)   ║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Cyan
    }

    # ──────────────────────────────────────────────────────────────
    # Step 1: Prerequisites
    # ────────────────────────���─────────────────────────────────────
    Show-Progress -Step 1

    # Check WSL2
    Show-Progress -Sub -Status "Checking WSL2..."
    $wslInstalled = $false
    try {
        $wslOutput = wsl --status 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
    } catch {}

    if (-not $wslInstalled) {
        Show-Progress -Sub -Status "Installing WSL2..."
        try {
            wsl --install --no-distribution 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Log-Err "WSL2 install failed. Try running PowerShell as Administrator."
                return
            }
        } catch {
            Log-Err "WSL2 install failed: $_"
            return
        }

        if ($HeadlessMode) {
            Write-Host "REBOOT_REQUIRED"
        } else {
            Write-Host ""
            Write-Host "    WSL2 installed! You need to RESTART your computer." -ForegroundColor Red
            Write-Host "    After restart, run this command again." -ForegroundColor Red
            Write-Host ""
        }
        try {
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"Write-Host 'Run your OpenClaw installer again after restart!' -ForegroundColor Cyan; Start-Sleep 10`""
            $trigger = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName "OpenClaw-Reminder" -Action $action -Trigger $trigger -Force | Out-Null
        } catch {}
        return
    }
    Log-Ok "WSL2: OK"

    # Check Docker
    Show-Progress -Sub -Status "Checking Docker..."
    $dockerInstalled = $false
    $dockerVersion = ""
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $dockerInstalled = $true }
    } catch {}

    if (-not $dockerInstalled) {
        Show-Progress -Sub -Status "Installing Docker Desktop..."

        $installed = $false
        try {
            $null = winget --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                Show-Progress -Sub -Status "Installing via winget..."
                winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $installed = $true }
            }
        } catch {}

        if (-not $installed) {
            $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
            $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
            Show-Progress -Sub -Status "Downloading Docker Desktop..."
            try {
                Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing
                $dlHash = (Get-FileHash -Path $dockerInstaller -Algorithm SHA256).Hash
                Log-Gray "SHA256: $dlHash"
                Show-Progress -Sub -Status "Running Docker installer..."
                Start-Process -FilePath $dockerInstaller -ArgumentList "install", "--quiet", "--accept-license" -Wait
                Remove-Item $dockerInstaller -Force -ErrorAction SilentlyContinue
                $installed = $true
            } catch {
                Log-Err "Docker download/install failed: $_"
                Log-Warn "Install Docker Desktop manually from https://docker.com/products/docker-desktop"
                return
            }
        }

        Show-Progress -Sub -Status "Starting Docker Desktop..."
        try { Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue } catch {}
    }

    # Wait for Docker daemon (up to 2 minutes)
    Show-Progress -Sub -Status "Waiting for Docker daemon..."
    if (-not $HeadlessMode -and -not $dockerInstalled) {
        Log-Warn "If Docker Desktop isn't open, please start it now."
    }
    $dockerReady = $false
    $maxDockerWait = 120
    for ($retry = 0; $retry -lt 24; $retry++) {
        try {
            $null = docker version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerReady = $true
                break
            }
        } catch {}
        if ($retry -eq 0) {
            try { Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue } catch {}
        }
        $elapsed = [int](($retry + 1) * 5)
        Show-WaitProgress -Current $elapsed -Max $maxDockerWait -Label "Waiting for Docker..."
        Start-Sleep -Seconds 5
    }

    if (-not $dockerReady) {
        if ($HeadlessMode) {
            Log-Err "Docker not responding after 120s."
        } else {
            Write-Host ""
            Write-Host "    Docker is not responding after 2 minutes." -ForegroundColor Red
            Write-Host "    1. Open Docker Desktop manually" -ForegroundColor Yellow
            Write-Host "    2. Wait for 'Docker Desktop is running'" -ForegroundColor Yellow
            Write-Host "    3. Run this install command again" -ForegroundColor Yellow
            Write-Host ""
        }
        return
    }

    $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
    Log-Ok "Docker: OK (v$dockerVersion)"

    # ──────────────────────────────────────────────────────────────
    # Step 2: Directory
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 2
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$installDir\config" | Out-Null
    Log-Ok "Created: $installDir"

    # ──────────────────────────────────────────────────────────────
    # Step 3: Security Token
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 3
    $gatewayToken = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Log-Ok "Gateway token generated"

    # ──────────────────────────────────────────────────────────────
    # Step 4: Configuration
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 4

    # Build channel configuration
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

    Show-Progress -Sub -Status "Writing openclaw.json..."
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

    Show-Progress -Sub -Status "Writing auth profiles..."
    if ($hasToken) {
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

        @"
{
  "token": "$CopilotToken",
  "refresh": true
}
"@ | Set-Content "$installDir\config\github-copilot.token.json" -Encoding UTF8
    } else {
        @"
{
  "version": 1,
  "profiles": {}
}
"@ | Set-Content "$installDir\config\auth-profiles.json" -Encoding UTF8

        @"
{
  "token": "",
  "refresh": true
}
"@ | Set-Content "$installDir\config\github-copilot.token.json" -Encoding UTF8
    }

    Show-Progress -Sub -Status "Writing SOUL.md..."
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

    # Verify generated files
    $configIssues = Verify-ConfigIntegrity $installDir
    if ($configIssues.Count -gt 0) {
        foreach ($issue in $configIssues) { Log-Warn "Config issue: $issue" }
    } else {
        Log-Ok "All config files verified"
    }

    # ──────────────────────────────────────────────────────────────
    # Step 5: Docker Compose
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 5

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

    Log-Ok "Docker Compose file created"

    # ──────────────────────────────────────────────────────────────
    # Step 6: Launch
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 6

    Push-Location $installDir
    try {
        Show-Progress -Sub -Status "Pulling images & starting containers..."
        Log-Gray "Directory: $installDir"
        $composeOutput = docker compose up -d 2>&1 | Out-String
        if ($composeOutput.Trim()) { Log-Gray $composeOutput.Trim() }
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

    Log-Ok "Containers started"

    # ──────────────────────────────────────────────────────────────
    # Step 7: Ready Check
    # ──────────────────────────────────────────────────────────────
    Show-Progress -Step 7

    Show-Progress -Sub -Status "Waiting for gateway (first run downloads packages)..."
    $ready = $false
    $maxGatewayWait = 180
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
        Show-WaitProgress -Current $elapsed -Max $maxGatewayWait -Label "Gateway starting..."
    }

    if (-not $ready) {
        if (-not $HeadlessMode) {
            Log-Warn "OpenClaw is still starting (normal on first run)."
            Log-Warn "Check progress: cd $installDir && docker compose logs -f"
        }
    } else {
        Log-Ok "OpenClaw gateway is ready!"
    }

    # ══════════════════════════════════════════════════════════════
    # Final Output
    # ══════════════════════════════════════════════════════════════
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
        Write-Host "INSTALL_OK"
        Write-Host "URL=$url"
        Write-Host "TOKEN=$gatewayToken"
        Write-Host "DIR=$installDir"
        Write-Host "CHANNEL=$ChannelType"
        Write-Host "READY=$($ready.ToString().ToLower())"
    } else {
        # Final progress bar — 100%
        Show-Progress -Complete

        Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║       OpenClaw is running! 🐾        ║" -ForegroundColor Green
        Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "    Open in your browser:" -ForegroundColor White
        Write-Host "    $url" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    Your token (save this!): $gatewayToken" -ForegroundColor Yellow
        Write-Host "    Install location: $installDir" -ForegroundColor Gray
        if ($ChannelType -ne "none") {
            Write-Host "    Channel: $ChannelType (pre-configured)" -ForegroundColor Gray
        }
        Write-Host ""

        if ($ready) {
            Start-Process $url
            Write-Host "    Browser opened!" -ForegroundColor Green
        } else {
            Write-Host "    Once it's ready, open: $url" -ForegroundColor Cyan
        }
        Write-Host ""

        Send-Telemetry "install_success" @{ channel = $ChannelType }
        # Getting Started Checklist
        Write-Host "  ── Getting Started ──────────────────────" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    [1] Open the web UI and say hello!" -ForegroundColor White
        Write-Host "        $url" -ForegroundColor Gray
        Write-Host ""
        Write-Host "    [2] Give your AI a name and personality" -ForegroundColor White
        Write-Host "        Edit SOUL.md in the workspace" -ForegroundColor Gray
        Write-Host ""

        if ($ChannelType -eq "none") {
            Write-Host "    [3] Add a messaging channel (optional)" -ForegroundColor White
            Write-Host "        Re-run with -ChannelType discord|telegram|signal" -ForegroundColor Gray
        } else {
            Write-Host "    [3] $ChannelType is pre-configured" -ForegroundColor White
            if ($ChannelToken -eq "") {
                Write-Host "        Add your bot token to: $installDir\config\openclaw.json" -ForegroundColor Gray
            } else {
                Write-Host "        Should be connected once the gateway starts" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "    [4] Check status:  cd $installDir && docker compose logs -f" -ForegroundColor Gray
        Write-Host "    [5] Stop:          cd $installDir && docker compose down" -ForegroundColor Gray
        Write-Host "    [6] Restart:       cd $installDir && docker compose up -d" -ForegroundColor Gray
        Write-Host ""
        Write-Host "    Need help? Check TROUBLESHOOTING.md or ask in Discord" -ForegroundColor Yellow
        Write-Host ""
    }

    # Cleanup
    Remove-Item "$env:USERPROFILE\.openclaw-install-state.json" -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName "OpenClaw-Reminder" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
