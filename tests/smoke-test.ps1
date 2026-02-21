# smoke-test.ps1 — Post-install validation for OpenClaw Friends
# Runs a series of health checks after installation and reports pass/fail.
#
# Usage:
#   .\smoke-test.ps1                           # auto-detect install dir
#   .\smoke-test.ps1 -InstallDir "C:\my\path"  # custom install dir
#   .\smoke-test.ps1 -Json                     # machine-readable JSON output
#   .\smoke-test.ps1 -Verbose                  # show extra diagnostics on failure

[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [switch]$Json,
    [int]$GatewayPort = 18800,
    [int]$BridgePort = 18801,
    [string]$ContainerName = "openclaw-friend"
)

$ErrorActionPreference = "Continue"
$script:Passed = 0
$script:Failed = 0
$script:Warned = 0
$script:Results = @()
$script:StartTime = Get-Date

# ─── Output Helpers ──────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   OpenClaw Friends — Install Smoke Test  🧪     ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Log-Pass {
    param([string]$Name, [string]$Detail = "")
    $script:Passed++
    $msg = "  ✅ PASS  $Name"
    if ($Detail) { $msg += "  ($Detail)" }
    Write-Host $msg -ForegroundColor Green
    $script:Results += @{ name = $Name; status = "pass"; detail = $Detail }
}

function Log-Fail {
    param([string]$Name, [string]$Detail = "")
    $script:Failed++
    $msg = "  ❌ FAIL  $Name"
    if ($Detail) { $msg += "  ($Detail)" }
    Write-Host $msg -ForegroundColor Red
    $script:Results += @{ name = $Name; status = "fail"; detail = $Detail }
}

function Log-Warn {
    param([string]$Name, [string]$Detail = "")
    $script:Warned++
    $msg = "  ⚠️  WARN  $Name"
    if ($Detail) { $msg += "  ($Detail)" }
    Write-Host $msg -ForegroundColor Yellow
    $script:Results += @{ name = $Name; status = "warn"; detail = $Detail }
}

function Log-Info {
    param([string]$Msg)
    Write-Host "  ℹ️  $Msg" -ForegroundColor Gray
}

function Log-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ── $Title ──" -ForegroundColor White
}

# ─── Checks ──────────────────────────────────────────────────

function Test-DockerRunning {
    Log-Section "Docker Engine"
    try {
        $version = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "Docker daemon is running" "v$version"
        } else {
            Log-Fail "Docker daemon is running" "docker version returned exit code $LASTEXITCODE"
        }
    } catch {
        Log-Fail "Docker daemon is running" "docker command not found or not accessible"
    }
}

function Test-ContainerRunning {
    Log-Section "Container"
    try {
        $state = docker inspect --format '{{.State.Status}}' $ContainerName 2>&1
        if ($LASTEXITCODE -eq 0 -and $state -eq "running") {
            Log-Pass "Container '$ContainerName' is running"

            # Check uptime
            $startedAt = docker inspect --format '{{.State.StartedAt}}' $ContainerName 2>&1
            if ($startedAt) {
                try {
                    $started = [DateTime]::Parse($startedAt)
                    $uptime = (Get-Date) - $started
                    $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
                    Log-Info "Uptime: $uptimeStr"
                } catch {}
            }

            # Check restart count
            $restarts = docker inspect --format '{{.RestartCount}}' $ContainerName 2>&1
            if ($LASTEXITCODE -eq 0) {
                $restartCount = [int]$restarts
                if ($restartCount -gt 5) {
                    Log-Warn "Container restart count" "$restartCount restarts — may indicate instability"
                } elseif ($restartCount -gt 0) {
                    Log-Info "Restart count: $restartCount"
                }
            }
        } elseif ($LASTEXITCODE -eq 0) {
            Log-Fail "Container '$ContainerName' is running" "State: $state"
        } else {
            Log-Fail "Container '$ContainerName' is running" "Container not found"
        }
    } catch {
        Log-Fail "Container '$ContainerName' is running" "$_"
    }
}

function Test-ContainerHealth {
    try {
        # Check if openclaw process is running inside container
        $procs = docker exec $ContainerName sh -c "ps aux 2>/dev/null | grep -c '[o]penclaw'" 2>&1
        if ($LASTEXITCODE -eq 0 -and [int]$procs -gt 0) {
            Log-Pass "OpenClaw process running inside container"
        } else {
            Log-Warn "OpenClaw process running inside container" "Process not detected (may still be starting)"
        }
    } catch {
        Log-Warn "OpenClaw process check" "Could not exec into container"
    }
}

function Test-GatewayHTTP {
    Log-Section "Gateway"
    $url = "http://localhost:$GatewayPort/"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 2>&1
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
            Log-Pass "Gateway HTTP responding" "port $GatewayPort → HTTP $($response.StatusCode)"
        } else {
            Log-Fail "Gateway HTTP responding" "HTTP $($response.StatusCode)"
        }
    } catch {
        $errMsg = $_.Exception.Message
        # A 401/403 still means the gateway is up
        if ($errMsg -match "401|403|Unauthorized|Forbidden") {
            Log-Pass "Gateway HTTP responding" "port $GatewayPort → auth required (expected)"
        } else {
            Log-Fail "Gateway HTTP responding" $errMsg
        }
    }
}

function Test-BridgePort {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("localhost", $BridgePort)
        $tcp.Close()
        Log-Pass "Bridge port reachable" "port $BridgePort"
    } catch {
        Log-Warn "Bridge port reachable" "port $BridgePort not responding (may be expected if unused)"
    }
}

function Test-GatewayToken {
    # Check if CONNECTION-INFO.txt exists and has a token
    $connFile = Join-Path $InstallDir "CONNECTION-INFO.txt"
    if (Test-Path $connFile) {
        $content = Get-Content $connFile -Raw
        if ($content -match "token=([A-Za-z0-9]+)") {
            $token = $Matches[1]
            # Try authenticated request
            try {
                $authUrl = "http://localhost:$GatewayPort/?token=$token"
                $response = Invoke-WebRequest -Uri $authUrl -UseBasicParsing -TimeoutSec 10 2>&1
                if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                    Log-Pass "Gateway token authentication" "Token from CONNECTION-INFO.txt works"
                } else {
                    Log-Warn "Gateway token authentication" "HTTP $($response.StatusCode)"
                }
            } catch {
                Log-Warn "Gateway token authentication" "Could not verify: $($_.Exception.Message)"
            }
        } else {
            Log-Warn "Gateway token authentication" "No token found in CONNECTION-INFO.txt"
        }
    } else {
        Log-Info "CONNECTION-INFO.txt not found — skipping token auth check"
    }
}

function Test-InstallDirectory {
    Log-Section "Install Directory"
    if (Test-Path $InstallDir) {
        Log-Pass "Install directory exists" $InstallDir
    } else {
        Log-Fail "Install directory exists" "$InstallDir not found"
        return
    }

    # Required files
    $requiredFiles = @(
        @{ Path = "docker-compose.yml"; Desc = "Docker Compose file" },
        @{ Path = "config\openclaw.json"; Desc = "OpenClaw configuration" }
    )

    foreach ($f in $requiredFiles) {
        $full = Join-Path $InstallDir $f.Path
        if (Test-Path $full) {
            Log-Pass $f.Desc
        } else {
            Log-Fail $f.Desc "$($f.Path) not found"
        }
    }

    # Optional but expected files
    $optionalFiles = @(
        @{ Path = "config\github-copilot.token.json"; Desc = "GitHub Copilot token" },
        @{ Path = "config\auth-profiles.json"; Desc = "Auth profiles" },
        @{ Path = "config\SOUL.md"; Desc = "SOUL.md seed" },
        @{ Path = "CONNECTION-INFO.txt"; Desc = "Connection info file" },
        @{ Path = ".env"; Desc = "Environment file" }
    )

    foreach ($f in $optionalFiles) {
        $full = Join-Path $InstallDir $f.Path
        if (Test-Path $full) {
            Log-Pass $f.Desc
        } else {
            Log-Warn $f.Desc "$($f.Path) not found"
        }
    }
}

function Test-WorkspaceFiles {
    Log-Section "Workspace (inside container)"
    $workspaceFiles = @(
        "SOUL.md",
        "IDENTITY.md",
        "AGENTS.md",
        "TOOLS.md",
        "USER.md"
    )

    foreach ($file in $workspaceFiles) {
        try {
            $result = docker exec $ContainerName test -f "/root/.openclaw/workspace/$file" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Log-Pass "Workspace: $file"
            } else {
                Log-Warn "Workspace: $file" "Not found (may be created on first conversation)"
            }
        } catch {
            Log-Warn "Workspace: $file" "Could not check"
        }
    }

    # Check MEMORY.md separately (only exists after conversations)
    try {
        $result = docker exec $ContainerName test -f "/root/.openclaw/workspace/MEMORY.md" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "Workspace: MEMORY.md"
        } else {
            Log-Info "MEMORY.md not found yet — created after first conversation (normal)"
        }
    } catch {}
}

function Test-ConfigValid {
    Log-Section "Configuration"
    $configPath = Join-Path $InstallDir "config\openclaw.json"
    if (-not (Test-Path $configPath)) {
        Log-Fail "openclaw.json parseable" "File not found"
        return
    }

    try {
        $content = Get-Content $configPath -Raw

        # Check for common issues: placeholder tokens still present
        if ($content -match 'YOUR_.*_HERE|REPLACE_ME|TODO|PLACEHOLDER') {
            Log-Warn "Config placeholders" "Found placeholder values — remember to update"
        }

        # Check gateway token is set
        if ($content -match '"token"\s*:\s*"(\$\{[^}]+\}|[A-Za-z0-9]{16,})"') {
            Log-Pass "Gateway token configured"
        } elseif ($content -match '"token"') {
            Log-Warn "Gateway token configured" "Token field exists but may be empty"
        }

        # Check model is configured
        if ($content -match '"primary"\s*:\s*"[^"]+"') {
            $null = $content -match '"primary"\s*:\s*"([^"]+)"'
            Log-Pass "Model configured" $Matches[1]
        } else {
            Log-Warn "Model configured" "No primary model found in config"
        }
    } catch {
        Log-Fail "Config validation" "$_"
    }
}

function Test-BackupCron {
    Log-Section "Backup System"
    try {
        # Check if auto-backup.py exists in container
        $result = docker exec $ContainerName test -f "/root/.openclaw/workspace/auto-backup.py" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "Backup script present" "auto-backup.py"
        } else {
            Log-Warn "Backup script present" "auto-backup.py not found in workspace"
        }
    } catch {
        Log-Warn "Backup script present" "Could not check"
    }

    try {
        # Check crontab for backup entry
        $crontab = docker exec $ContainerName sh -c "crontab -l 2>/dev/null || echo ''" 2>&1
        if ($crontab -match "auto-backup" -or $crontab -match "backup") {
            Log-Pass "Backup cron active"
            # Extract schedule
            if ($crontab -match "^(\S+\s+\S+\s+\S+\s+\S+\s+\S+).*backup") {
                Log-Info "Schedule: $($Matches[1])"
            }
        } else {
            Log-Warn "Backup cron active" "No backup entry in crontab"
        }
    } catch {
        Log-Warn "Backup cron check" "Could not read crontab"
    }

    try {
        # Check backup-last-run.json for staleness
        $lastRun = docker exec $ContainerName sh -c "cat /root/.openclaw/workspace/backup-last-run.json 2>/dev/null || echo ''" 2>&1
        if ($lastRun -match '"timestamp"\s*:\s*(\d+)') {
            $ts = [int64]$Matches[1]
            $lastRunTime = [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime
            $age = (Get-Date).ToUniversalTime() - $lastRunTime
            $ageStr = "{0}h {1}m ago" -f [int]$age.TotalHours, $age.Minutes

            if ($age.TotalMinutes -le 30) {
                Log-Pass "Last backup recent" $ageStr
            } elseif ($age.TotalHours -le 2) {
                Log-Warn "Last backup recent" "$ageStr (threshold: 30min)"
            } else {
                Log-Fail "Last backup recent" "$ageStr — backup may be stalled"
            }
        } else {
            Log-Info "No backup-last-run.json — backup may not have run yet"
        }
    } catch {
        Log-Info "Could not check backup recency"
    }
}

function Test-DiskSpace {
    Log-Section "System Resources"
    try {
        # Docker disk usage
        $dfOutput = docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "Docker disk usage"
            foreach ($line in $dfOutput -split "`n") {
                if ($line.Trim()) { Log-Info "  $($line.Trim())" }
            }
        }
    } catch {}

    # Check host disk space for install dir
    try {
        $drive = (Get-Item $InstallDir).PSDrive
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -lt 1) {
            Log-Fail "Disk space" "${freeGB}GB free — critically low"
        } elseif ($freeGB -lt 5) {
            Log-Warn "Disk space" "${freeGB}GB free"
        } else {
            Log-Pass "Disk space" "${freeGB}GB free"
        }
    } catch {}
}

function Test-DockerCompose {
    try {
        Push-Location $InstallDir
        $configCheck = docker compose config --quiet 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "docker-compose.yml valid"
        } else {
            Log-Fail "docker-compose.yml valid" "Syntax error: $configCheck"
        }
        Pop-Location
    } catch {
        Log-Warn "docker-compose.yml validation" "Could not validate: $_"
    }
}

function Test-NetworkConnectivity {
    Log-Section "Network"

    # Check if container can resolve DNS
    try {
        $dns = docker exec $ContainerName sh -c "nslookup github.com 2>/dev/null | head -1 || echo fail" 2>&1
        if ($dns -notmatch "fail" -and $LASTEXITCODE -eq 0) {
            Log-Pass "Container DNS resolution"
        } else {
            Log-Warn "Container DNS resolution" "DNS may not be working inside container"
        }
    } catch {
        Log-Warn "Container DNS resolution" "Could not check"
    }
}

# ─── Report ──────────────────────────────────────────────────

function Write-Report {
    $elapsed = (Get-Date) - $script:StartTime
    $total = $script:Passed + $script:Failed + $script:Warned
    $elapsedStr = "{0:N1}s" -f $elapsed.TotalSeconds

    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Cyan

    if ($script:Failed -eq 0) {
        $statusIcon = "🎉"
        $statusColor = "Green"
        $statusText = "ALL CHECKS PASSED"
    } else {
        $statusIcon = "⚠️"
        $statusColor = "Red"
        $statusText = "$($script:Failed) CHECK(S) FAILED"
    }

    Write-Host "  $statusIcon $statusText" -ForegroundColor $statusColor
    Write-Host ""
    Write-Host "  Passed: $($script:Passed)  Failed: $($script:Failed)  Warnings: $($script:Warned)  Total: $total  Time: $elapsedStr" -ForegroundColor Gray
    Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    if ($Json) {
        $report = @{
            timestamp = (Get-Date -Format "o")
            installDir = $InstallDir
            passed = $script:Passed
            failed = $script:Failed
            warned = $script:Warned
            total = $total
            elapsed = $elapsedStr
            status = if ($script:Failed -eq 0) { "pass" } else { "fail" }
            checks = $script:Results
        }
        $jsonOutput = $report | ConvertTo-Json -Depth 4
        Write-Host $jsonOutput
    }

    if ($script:Failed -gt 0) {
        exit 1
    }
    exit 0
}

# ─── Main ────────────────────────────────────────────────────

function Main {
    Write-Banner

    # Resolve install directory
    if (-not $InstallDir) {
        $InstallDir = Join-Path $env:USERPROFILE "openclaw-friend"
        if (-not (Test-Path $InstallDir)) {
            # Try alternate locations
            $alternates = @(
                (Join-Path $env:USERPROFILE "openclaw"),
                (Join-Path $env:USERPROFILE "openclaw-friends")
            )
            foreach ($alt in $alternates) {
                if (Test-Path $alt) {
                    $InstallDir = $alt
                    break
                }
            }
        }
    }

    Log-Info "Install directory: $InstallDir"
    Log-Info "Container: $ContainerName"
    Log-Info "Gateway port: $GatewayPort | Bridge port: $BridgePort"

    # Run all checks
    Test-DockerRunning
    Test-ContainerRunning
    Test-ContainerHealth
    Test-GatewayHTTP
    Test-BridgePort
    Test-GatewayToken
    Test-InstallDirectory
    Test-DockerCompose
    Test-WorkspaceFiles
    Test-ConfigValid
    Test-BackupCron
    Test-DiskSpace
    Test-NetworkConnectivity

    # Summary
    Write-Report
}

Main
