# OpenClaw Friends Uninstaller
# Usage: irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/uninstall.ps1 | iex; Uninstall-OpenClaw

function Uninstall-OpenClaw {
    $installDir = "$env:USERPROFILE\openclaw"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "   OpenClaw Uninstaller" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-Path $installDir)) {
        Write-Host "  OpenClaw not found at $installDir" -ForegroundColor Red
        return
    }

    # Step 1: Stop containers
    Write-Host "[1/3] Stopping OpenClaw..." -ForegroundColor Yellow
    try {
        Push-Location $installDir
        docker compose down 2>$null
        Pop-Location
        Write-Host "  Containers stopped" -ForegroundColor Green
    } catch {
        Write-Host "  No containers running (or Docker not available)" -ForegroundColor Yellow
    }

    # Step 2: Remove volumes
    Write-Host "[2/3] Removing data..." -ForegroundColor Yellow
    $confirm = Read-Host "  Delete all OpenClaw data? This cannot be undone. (yes/no)"
    if ($confirm -eq "yes") {
        docker volume rm openclaw-config openclaw-workspace 2>$null
        Remove-Item -Recurse -Force $installDir
        Write-Host "  All data removed" -ForegroundColor Green
    } else {
        Write-Host "  Keeping data. You can manually delete $installDir later." -ForegroundColor Yellow
    }

    # Step 3: Clean up
    Write-Host "[3/3] Cleaning up..." -ForegroundColor Yellow
    Remove-Item "$env:USERPROFILE\.openclaw-install-state.json" -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName "OpenClaw-Reminder" -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    Write-Host ""
    Write-Host "  OpenClaw has been removed." -ForegroundColor Green
    Write-Host "  Docker Desktop was NOT uninstalled (you may still need it)." -ForegroundColor Gray
    Write-Host ""
}
