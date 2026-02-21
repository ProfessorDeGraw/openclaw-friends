# Install Smoke Test
# Validates a fresh OpenClaw install programmatically.
# Run after install.ps1 completes.
#
# Usage:
#   .\smoke-test.ps1                    # run all tests
#   .\smoke-test.ps1 -Verbose           # detailed output
#   .\smoke-test.ps1 -InstallDir "C:\custom\path"

param(
    [string]$InstallDir = "$env:USERPROFILE\openclaw",
    [int]$Port = 18789,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"
$passed = 0
$failed = 0
$warnings = 0

function Test-Check {
    param([string]$Name, [scriptblock]$Test, [bool]$Critical = $true)
    
    try {
        $result = & $Test
        if ($result) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
            $script:passed++
            return $true
        } else {
            if ($Critical) {
                Write-Host "  [FAIL] $Name" -ForegroundColor Red
                $script:failed++
            } else {
                Write-Host "  [WARN] $Name" -ForegroundColor Yellow
                $script:warnings++
            }
            return $false
        }
    } catch {
        Write-Host "  [FAIL] $Name — $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
        return $false
    }
}

Write-Host ""
Write-Host "OpenClaw Install Smoke Test" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host "Install dir: $InstallDir"
Write-Host "Port: $Port"
Write-Host ""

# ── File System Checks ──
Write-Host "File System:" -ForegroundColor White

Test-Check "Install directory exists" {
    Test-Path $InstallDir
}

Test-Check "docker-compose.yml exists" {
    Test-Path "$InstallDir\docker-compose.yml"
}

Test-Check "Config directory exists" {
    Test-Path "$InstallDir\config"
}

Test-Check "openclaw.json exists" {
    Test-Path "$InstallDir\config\openclaw.json"
}

Test-Check "CONNECTION-INFO.txt exists" {
    Test-Path "$InstallDir\CONNECTION-INFO.txt"
} -Critical $false

Test-Check ".env file exists" {
    Test-Path "$InstallDir\.env"
} -Critical $false

# ── Docker Checks ──
Write-Host ""
Write-Host "Docker:" -ForegroundColor White

Test-Check "Docker is running" {
    $null = docker info 2>&1
    $LASTEXITCODE -eq 0
}

Test-Check "Container openclaw-gateway exists" {
    $containers = docker ps -a --filter "name=openclaw-gateway" --format "{{.Names}}" 2>&1
    $containers -match "openclaw-gateway"
}

Test-Check "Container openclaw-gateway is running" {
    $status = docker ps --filter "name=openclaw-gateway" --format "{{.Status}}" 2>&1
    $status -match "Up"
}

Test-Check "Container healthy (no restart loop)" {
    $restarts = docker inspect --format="{{.RestartCount}}" openclaw-gateway 2>&1
    [int]$restarts -lt 3
}

Test-Check "OpenClaw version in logs" {
    $logs = docker logs openclaw-gateway --tail 50 2>&1 | Out-String
    $logs -match "openclaw v"
} -Critical $false

# ── Network Checks ──
Write-Host ""
Write-Host "Network:" -ForegroundColor White

Test-Check "Port $Port is listening" {
    (Test-NetConnection -ComputerName localhost -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded
}

Test-Check "Web UI responds (HTTP 200)" {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port" -UseBasicParsing -TimeoutSec 10
        $response.StatusCode -eq 200
    } catch {
        $false
    }
}

Test-Check "API endpoint responds" {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        $response.StatusCode -lt 500
    } catch {
        # Even a 401/404 means the server is responding
        $_.Exception.Response.StatusCode.value__ -lt 500
    }
} -Critical $false

# ── Config Validation ──
Write-Host ""
Write-Host "Config:" -ForegroundColor White

Test-Check "openclaw.json is valid JSON" {
    $content = Get-Content "$InstallDir\config\openclaw.json" -Raw -ErrorAction Stop
    $null = $content | ConvertFrom-Json
    $true
}

Test-Check "Gateway token is set" {
    if (Test-Path "$InstallDir\.env") {
        $env = Get-Content "$InstallDir\.env" -Raw
        $env -match "OPENCLAW_GATEWAY_TOKEN=.+"
    } else {
        $false
    }
} -Critical $false

# ── Volume Checks ──
Write-Host ""
Write-Host "Volumes:" -ForegroundColor White

Test-Check "Workspace volume exists" {
    $volumes = docker volume ls --format "{{.Name}}" 2>&1 | Out-String
    $volumes -match "workspace"
} -Critical $false

Test-Check "Config volume exists" {
    $volumes = docker volume ls --format "{{.Name}}" 2>&1 | Out-String
    $volumes -match "config"
} -Critical $false

# ── Summary ──
Write-Host ""
Write-Host "==========================" -ForegroundColor Cyan
$total = $passed + $failed + $warnings
Write-Host "Results: $passed passed, $failed failed, $warnings warnings (of $total)" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

if ($failed -eq 0) {
    Write-Host "✅ Install looks good!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ $failed check(s) failed — see above" -ForegroundColor Red
    exit 1
}
