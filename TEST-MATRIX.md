# Installer Test Matrix

Checklist for validating `install.ps1` across environments before release.

## Test Environments

| # | OS | Docker Pre-installed | WSL2 Pre-installed | Status |
|---|-----|---------------------|-------------------|--------|
| 1 | Windows 11 23H2 (clean) | ❌ | ❌ | ⬜ |
| 2 | Windows 11 23H2 | ✅ running | ✅ | ⬜ |
| 3 | Windows 11 23H2 | ✅ installed, not running | ✅ | ⬜ |
| 4 | Windows 10 22H2 (clean) | ❌ | ❌ | ⬜ |
| 5 | Windows 10 22H2 | ✅ running | ✅ | ⬜ |
| 6 | Windows 11 ARM64 (Surface) | ❌ | ❌ | ⬜ |

Status: ⬜ untested | ✅ pass | ❌ fail | ⚠️ partial

## Test Steps (per environment)

### Pre-install checks
- [ ] Note OS version: `winver`
- [ ] Note PowerShell version: `$PSVersionTable.PSVersion`
- [ ] Note if Docker installed: `docker --version`
- [ ] Note if WSL2 installed: `wsl --status`
- [ ] Note execution policy: `Get-ExecutionPolicy`

### Install run
- [ ] Run: `irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "TEST_TOKEN"`
- [ ] Token validation works (try empty, short, placeholder tokens first)
- [ ] WSL2 detection correct
- [ ] Docker detection correct
- [ ] If WSL2 missing: installs and asks for reboot
- [ ] If Docker missing: installs via winget or direct download
- [ ] Docker retry loop works (waits for daemon)
- [ ] Config files created in `%USERPROFILE%\openclaw\config\`
- [ ] docker-compose.yml created
- [ ] Container starts successfully
- [ ] Readiness polling works (shows progress)
- [ ] Browser opens with correct URL + token
- [ ] CONNECTION-INFO.txt created with correct values
- [ ] Getting started checklist displays

### Post-install validation
- [ ] Web UI loads at `http://localhost:18789/?token=TOKEN`
- [ ] Container survives `docker compose restart`
- [ ] Container auto-starts after Docker Desktop restart
- [ ] Logs show no errors: `docker compose logs --tail 20`
- [ ] OpenClaw version visible in logs

### Edge cases
- [ ] Re-run installer when already installed (doesn't break existing install)
- [ ] Run without admin rights (should work if Docker+WSL2 already present)
- [ ] Run with antivirus active (no false positives)
- [ ] Run with VPN active
- [ ] Run with restricted execution policy (should show helpful error)
- [ ] Port 18789 already in use (should show clear error)
- [ ] Invalid/expired Copilot token (container starts but AI doesn't respond)
- [ ] No internet connection (should fail gracefully)
- [ ] Disk nearly full (<1GB free)

### Uninstall
- [ ] Run uninstall commands from README
- [ ] Containers removed
- [ ] Volumes removed
- [ ] Install directory removed
- [ ] No orphaned processes

## Automated Checks

These can be validated programmatically after install:

```powershell
# Quick smoke test
$tests = @(
    @{ Name="Container running"; Test={ (docker ps --filter name=openclaw-gateway --format '{{.Status}}') -match 'Up' } },
    @{ Name="Port 18789 open"; Test={ (Test-NetConnection localhost -Port 18789).TcpTestSucceeded } },
    @{ Name="Config exists"; Test={ Test-Path "$env:USERPROFILE\openclaw\config\openclaw.json" } },
    @{ Name="Compose exists"; Test={ Test-Path "$env:USERPROFILE\openclaw\docker-compose.yml" } },
    @{ Name="Connection info"; Test={ Test-Path "$env:USERPROFILE\openclaw\CONNECTION-INFO.txt" } }
)

foreach ($t in $tests) {
    $result = if (& $t.Test) { "PASS" } else { "FAIL" }
    Write-Host "[$result] $($t.Name)"
}
```

## Results Log

| Date | Env# | Tester | Result | Notes |
|------|------|--------|--------|-------|
| 2026-02-21 | Docker sim | Kate | ✅ | npm install + openclaw doctor pass on clean node:22 |
| | | | | |

## Notes
- Always test with a real Copilot token for full validation
- Windows VM snapshots are ideal: snapshot clean state, test, revert
- ARM64 testing needs a Surface or ARM VM
- First-time WSL2 install requires a real reboot (can't be simulated)
