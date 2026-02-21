# Config Validation Script
# Validates OpenClaw environment before/after install.
# Checks ports, paths, permissions, and config consistency.
#
# Usage:
#   .\validate-config.ps1                     # validate default location
#   .\validate-config.ps1 -InstallDir "C:\custom"
#   .\validate-config.ps1 -Fix                # attempt auto-fix

param(
    [string]$InstallDir = "$env:USERPROFILE\openclaw",
    [int]$Port = 18789,
    [switch]$Fix
)

$ErrorActionPreference = "Continue"
$issues = @()
$fixed = @()

function Validate {
    param([string]$Name, [scriptblock]$Test, [scriptblock]$FixAction = $null)
    
    $result = & $Test
    if ($result) {
        Write-Host "  [OK]   $Name" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:issues += $Name
        if ($Fix -and $FixAction) {
            try {
                & $FixAction
                Write-Host "         → Auto-fixed!" -ForegroundColor Yellow
                $script:fixed += $Name
            } catch {
                Write-Host "         → Auto-fix failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

Write-Host ""
Write-Host "OpenClaw Config Validation" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host ""

# ── Paths ──
Write-Host "Paths:" -ForegroundColor White

Validate "Install directory exists" {
    Test-Path $InstallDir
} {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

Validate "Install directory is writable" {
    try {
        $testFile = "$InstallDir\.write-test"
        Set-Content -Path $testFile -Value "test" -ErrorAction Stop
        Remove-Item $testFile -Force
        $true
    } catch { $false }
}

Validate "Config directory exists" {
    Test-Path "$InstallDir\config"
} {
    New-Item -Path "$InstallDir\config" -ItemType Directory -Force | Out-Null
}

Validate "Path has no spaces or special chars" {
    $InstallDir -notmatch '[\[\]{}()&!@#$%^]'
}

Validate "Path is not too long (< 200 chars)" {
    $InstallDir.Length -lt 200
}

# ── Config Files ──
Write-Host ""
Write-Host "Config Files:" -ForegroundColor White

Validate "docker-compose.yml exists" {
    Test-Path "$InstallDir\docker-compose.yml"
}

if (Test-Path "$InstallDir\config\openclaw.json") {
    Validate "openclaw.json is valid JSON" {
        try {
            $json = Get-Content "$InstallDir\config\openclaw.json" -Raw | ConvertFrom-Json
            $true
        } catch { $false }
    }
    
    Validate "openclaw.json has channels config" {
        $json = Get-Content "$InstallDir\config\openclaw.json" -Raw | ConvertFrom-Json
        $null -ne $json.channels -or $null -ne $json.channel
    }
} else {
    Write-Host "  [SKIP] openclaw.json not found (pre-install?)" -ForegroundColor DarkGray
}

if (Test-Path "$InstallDir\.env") {
    Validate ".env has gateway token" {
        $env = Get-Content "$InstallDir\.env" -Raw
        $env -match "OPENCLAW_GATEWAY_TOKEN=.{10,}"
    }
    
    Validate ".env has no placeholder tokens" {
        $env = Get-Content "$InstallDir\.env" -Raw
        $env -notmatch "your-token-here|REPLACE_ME|xxx|TODO"
    }
} else {
    Write-Host "  [SKIP] .env not found" -ForegroundColor DarkGray
}

# ── Ports ──
Write-Host ""
Write-Host "Ports:" -ForegroundColor White

$requiredPorts = @(
    @{Port=$Port; Name="Gateway"},
    @{Port=4000; Name="LiteLLM"},
    @{Port=4242; Name="Relay Primary"},
    @{Port=4243; Name="Relay Backup"}
)

foreach ($p in $requiredPorts) {
    Validate "Port $($p.Port) ($($p.Name)) is available" {
        $listener = Get-NetTCPConnection -LocalPort $p.Port -ErrorAction SilentlyContinue
        if ($listener) {
            # Port in use — check if it is our container
            $proc = Get-Process -Id $listener[0].OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match "com.docker|vpnkit|wsl") {
                $true  # It is Docker (ours), OK
            } else {
                $false  # Something else is using it
            }
        } else {
            $true  # Port is free
        }
    }
}

# ── Permissions ──
Write-Host ""
Write-Host "Permissions:" -ForegroundColor White

Validate "Running as current user (not SYSTEM)" {
    [Environment]::UserName -ne "SYSTEM"
}

Validate "Docker accessible without admin" {
    try {
        $null = docker info 2>&1
        $LASTEXITCODE -eq 0
    } catch { $false }
}

Validate "WSL2 accessible" {
    try {
        $null = wsl --status 2>&1
        $LASTEXITCODE -eq 0
    } catch { $false }
}

# ── Disk Space ──
Write-Host ""
Write-Host "Resources:" -ForegroundColor White

Validate "At least 2GB free disk space" {
    $drive = (Get-Item $InstallDir -ErrorAction SilentlyContinue).PSDrive.Name
    if (-not $drive) { $drive = "C" }
    $free = (Get-PSDrive $drive).Free
    $free -gt 2GB
}

Validate "Docker has enough resources" {
    try {
        $info = docker system info 2>&1 | Out-String
        $info -match "Total Memory.*[4-9]\.|Total Memory.*[1-9]\d"
    } catch { $false }
}

# ── Summary ──
Write-Host ""
Write-Host "==========================" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "✅ All checks passed — config looks good!" -ForegroundColor Green
    exit 0
} else {
    $unfixed = $issues.Count - $fixed.Count
    Write-Host "Issues: $($issues.Count) found, $($fixed.Count) auto-fixed, $unfixed remaining" -ForegroundColor $(if ($unfixed -eq 0) { "Yellow" } else { "Red" })
    if ($unfixed -gt 0) {
        Write-Host "Run with -Fix to attempt auto-repair" -ForegroundColor Yellow
    }
    exit 1
}
