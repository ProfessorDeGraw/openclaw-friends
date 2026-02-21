# OpenClaw Fresh Install Test Script — Windows 11
# Run this on a clean Windows 11 VM with NO Docker pre-installed.
# It validates the full installer flow end-to-end.
#
# Usage:
#   1. Open PowerShell as Administrator
#   2. Set-ExecutionPolicy Bypass -Scope Process
#   3. .\win11-fresh-test.ps1 -CopilotToken "YOUR_TOKEN"
#
# Optional:
#   -SkipInstall    Skip running the installer (test existing install)
#   -Verbose        Show all output, not just pass/fail
#   -ReportPath     Where to save the test report (default: .\test-report.md)

param(
    [Parameter(Mandatory=$true)]
    [string]$CopilotToken,
    [switch]$SkipInstall,
    [switch]$Verbose,
    [string]$ReportPath = ".\test-report.md"
)

$ErrorActionPreference = "Continue"
$testResults = @()
$startTime = Get-Date
$installDir = "$env:USERPROFILE\openclaw"

# ============================================
# Test helpers
# ============================================

function Test-Step {
    param(
        [string]$Name,
        [string]$Category,
        [scriptblock]$Test
    )

    Write-Host "`n--- $Category / $Name ---" -ForegroundColor Cyan
    $result = @{
        Name = $Name
        Category = $Category
        Status = "FAIL"
        Message = ""
        Duration = 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $output = & $Test
        $result.Status = "PASS"
        $result.Message = if ($output) { "$output" } else { "OK" }
        Write-Host "  PASS: $($result.Message)" -ForegroundColor Green
    } catch {
        $result.Message = $_.Exception.Message
        Write-Host "  FAIL: $($result.Message)" -ForegroundColor Red
    }
    $sw.Stop()
    $result.Duration = $sw.ElapsedMilliseconds

    $script:testResults += [PSCustomObject]$result
}

# ============================================
# Phase 1: Pre-install environment checks
# ============================================

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Phase 1: Pre-Install Environment" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

Test-Step -Name "Windows version" -Category "Environment" -Test {
    $ver = [System.Environment]::OSVersion.Version
    $build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
    if ([int]$build -lt 22000) { throw "Windows 11 required (build 22000+), got build $build" }
    "Windows 11 build $build (v$ver)"
}

Test-Step -Name "PowerShell version" -Category "Environment" -Test {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 5) { throw "PowerShell 5+ required, got $v" }
    "PowerShell $v"
}

Test-Step -Name "Internet connectivity" -Category "Environment" -Test {
    $r = Invoke-WebRequest -Uri "https://registry.hub.docker.com/" -UseBasicParsing -TimeoutSec 10
    if ($r.StatusCode -ne 200) { throw "Cannot reach Docker Hub (HTTP $($r.StatusCode))" }
    "Docker Hub reachable"
}

Test-Step -Name "Disk space" -Category "Environment" -Test {
    $drive = (Get-PSDrive C)
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -lt 5) { throw "Need at least 5GB free, only ${freeGB}GB available" }
    "${freeGB}GB free on C:"
}

Test-Step -Name "No existing Docker" -Category "Environment" -Test {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker -and -not $SkipInstall) {
        "WARNING: Docker already present at $($docker.Source) — not a fully fresh test"
    } else {
        "No Docker found (clean slate)"
    }
}

Test-Step -Name "No existing OpenClaw dir" -Category "Environment" -Test {
    if ((Test-Path $installDir) -and -not $SkipInstall) {
        "WARNING: $installDir already exists — remove for true fresh test"
    } else {
        "Clean: $installDir does not exist"
    }
}

# ============================================
# Phase 2: Run the installer
# ============================================

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Phase 2: Installation" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

if (-not $SkipInstall) {
    Test-Step -Name "Run installer" -Category "Install" -Test {
        # Source the installer function
        . "$PSScriptRoot\..\install.ps1"

        # Run it
        Install-OpenClaw $CopilotToken

        if (-not (Test-Path $installDir)) {
            throw "Install directory was not created"
        }
        "Installer completed, directory exists"
    }
} else {
    Write-Host "  Skipping install (--SkipInstall flag)" -ForegroundColor Gray
}

# ============================================
# Phase 3: Post-install validation
# ============================================

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Phase 3: Post-Install Validation" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

# --- 3a: File checks ---

Test-Step -Name "docker-compose.yml exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\docker-compose.yml")) {
        throw "docker-compose.yml not found"
    }
    $size = (Get-Item "$installDir\docker-compose.yml").Length
    "Found ($size bytes)"
}

Test-Step -Name "openclaw.json exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\config\openclaw.json")) {
        throw "config/openclaw.json not found"
    }
    # Validate it's valid JSON
    $null = Get-Content "$installDir\config\openclaw.json" | ConvertFrom-Json
    "Found and valid JSON"
}

Test-Step -Name "auth-profiles.json exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\config\auth-profiles.json")) {
        throw "config/auth-profiles.json not found"
    }
    $json = Get-Content "$installDir\config\auth-profiles.json" | ConvertFrom-Json
    $profiles = $json.profiles.PSObject.Properties.Name
    if ($profiles.Count -eq 0) { throw "No auth profiles configured" }
    "Found with profiles: $($profiles -join ', ')"
}

Test-Step -Name "github-copilot.token.json exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\config\github-copilot.token.json")) {
        throw "config/github-copilot.token.json not found"
    }
    $json = Get-Content "$installDir\config\github-copilot.token.json" | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($json.token)) { throw "Token is empty" }
    "Found with token (length: $($json.token.Length))"
}

Test-Step -Name "SOUL.md exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\config\SOUL.md")) {
        throw "config/SOUL.md not found"
    }
    $lines = (Get-Content "$installDir\config\SOUL.md").Count
    "Found ($lines lines)"
}

Test-Step -Name "CONNECTION-INFO.txt exists" -Category "Files" -Test {
    if (-not (Test-Path "$installDir\CONNECTION-INFO.txt")) {
        throw "CONNECTION-INFO.txt not found"
    }
    $content = Get-Content "$installDir\CONNECTION-INFO.txt" -Raw
    if ($content -notmatch "localhost:18789") { throw "Missing URL in connection info" }
    "Found with connection URL"
}

Test-Step -Name "Token not placeholder" -Category "Files" -Test {
    $json = Get-Content "$installDir\config\openclaw.json" -Raw
    if ($json -match "YOUR_TOKEN|YOUR_COPILOT_TOKEN") {
        throw "Config still contains placeholder token"
    }
    "No placeholder tokens found"
}

# --- 3b: Docker checks ---

Test-Step -Name "Docker is running" -Category "Docker" -Test {
    $v = docker version --format '{{.Server.Version}}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker not responding: $v" }
    "Docker $v"
}

Test-Step -Name "Container exists" -Category "Docker" -Test {
    $containers = docker ps -a --filter "name=openclaw-gateway" --format "{{.Names}}" 2>&1
    if ($containers -notmatch "openclaw-gateway") { throw "Container not found" }
    "openclaw-gateway container exists"
}

Test-Step -Name "Container is running" -Category "Docker" -Test {
    $status = docker inspect --format '{{.State.Status}}' openclaw-gateway 2>&1
    if ($status -ne "running") { throw "Container status: $status (expected: running)" }
    "Status: running"
}

Test-Step -Name "Container not restart-looping" -Category "Docker" -Test {
    $restarts = docker inspect --format '{{.RestartCount}}' openclaw-gateway 2>&1
    if ([int]$restarts -gt 3) { throw "Container has restarted $restarts times — likely crash-looping" }
    "Restart count: $restarts"
}

Test-Step -Name "Port 18789 is mapped" -Category "Docker" -Test {
    $ports = docker port openclaw-gateway 2>&1
    if ($ports -notmatch "18789") { throw "Port 18789 not mapped: $ports" }
    "Port mapping: $ports"
}

# --- 3c: Gateway checks ---

Test-Step -Name "Gateway responds on localhost" -Category "Gateway" -Test {
    # Give it a moment if just started
    Start-Sleep -Seconds 2
    $r = Invoke-WebRequest -Uri "http://localhost:18789/" -UseBasicParsing -TimeoutSec 15 2>&1
    if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
    "HTTP 200 OK"
}

Test-Step -Name "Gateway responds on 127.0.0.1" -Category "Gateway" -Test {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:18789/" -UseBasicParsing -TimeoutSec 10 2>&1
    if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
    "HTTP 200 OK"
}

Test-Step -Name "Token authentication works" -Category "Gateway" -Test {
    $token = (Get-Content "$installDir\CONNECTION-INFO.txt" -Raw) -replace '(?s).*Token:\s*(\S+).*', '$1'
    $r = Invoke-WebRequest -Uri "http://localhost:18789/?token=$token" -UseBasicParsing -TimeoutSec 10 2>&1
    if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode) with token" }
    "Authenticated OK"
}

Test-Step -Name "API endpoint responds" -Category "Gateway" -Test {
    $token = (Get-Content "$installDir\CONNECTION-INFO.txt" -Raw) -replace '(?s).*Token:\s*(\S+).*', '$1'
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    $body = '{"model":"openclaw:main","input":"ping"}'
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:18789/v1/responses" -Method POST `
            -Headers $headers -Body $body -UseBasicParsing -TimeoutSec 30
        "API responded (HTTP $($r.StatusCode))"
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) { throw "Auth failed — token mismatch" }
        throw "API call failed: $_"
    }
}

# --- 3d: Container health ---

Test-Step -Name "Container logs have no fatal errors" -Category "Health" -Test {
    $logs = docker logs openclaw-gateway --tail 100 2>&1 | Out-String
    $fatals = ($logs | Select-String -Pattern "FATAL|panic|segfault|EACCES|ENOSPC" -AllMatches).Matches.Count
    if ($fatals -gt 0) { throw "Found $fatals fatal-level messages in logs" }
    "No fatal errors in last 100 log lines"
}

Test-Step -Name "Container memory usage" -Category "Health" -Test {
    $stats = docker stats openclaw-gateway --no-stream --format "{{.MemUsage}}" 2>&1
    "Memory: $stats"
}

# ============================================
# Phase 4: Discord integration (if configured)
# ============================================

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Phase 4: Discord (if configured)" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

Test-Step -Name "Discord config present" -Category "Discord" -Test {
    $config = Get-Content "$installDir\config\openclaw.json" -Raw | ConvertFrom-Json
    if ($config.channels.discord -and $config.channels.discord.enabled) {
        "Discord enabled with channel(s) configured"
    } else {
        "Discord not configured (optional — skipping)"
    }
}

# ============================================
# Generate report
# ============================================

$endTime = Get-Date
$totalDuration = ($endTime - $startTime).TotalSeconds
$passed = ($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
$total = $testResults.Count

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Test Results: $passed/$total passed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "  Duration: $([math]::Round($totalDuration, 1))s" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "`n  Failed tests:" -ForegroundColor Red
    $testResults | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "    ✗ $($_.Category) / $($_.Name): $($_.Message)" -ForegroundColor Red
    }
}

# Write markdown report
$report = @"
# OpenClaw Install Test Report

| Field | Value |
|-------|-------|
| **Date** | $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") |
| **Machine** | $env:COMPUTERNAME |
| **OS** | $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption) |
| **Build** | $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild) |
| **Result** | **$passed / $total passed** $(if ($failed -eq 0) { '✅' } else { '❌' }) |
| **Duration** | $([math]::Round($totalDuration, 1))s |

## Results

| # | Category | Test | Status | Duration | Notes |
|---|----------|------|--------|----------|-------|
$($testResults | ForEach-Object { $i++; "| $i | $($_.Category) | $($_.Name) | $(if ($_.Status -eq 'PASS') { '✅' } else { '❌' }) | $($_.Duration)ms | $($_.Message) |" } | Out-String)

## Failed Tests

$(if ($failed -eq 0) {
    "_None — all tests passed!_"
} else {
    ($testResults | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        "### ❌ $($_.Category) / $($_.Name)`n`n**Error:** $($_.Message)`n"
    }) -join "`n"
})

## Container Logs (last 30 lines)

``````
$(docker logs openclaw-gateway --tail 30 2>&1 | Out-String)
``````

---
_Generated by win11-fresh-test.ps1_
"@

$report | Set-Content $ReportPath -Encoding UTF8
Write-Host "`n  Report saved to: $ReportPath" -ForegroundColor Gray

# Exit with failure code if any tests failed
if ($failed -gt 0) { exit 1 }
