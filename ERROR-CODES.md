# Installer Error Code Reference

Exit codes and troubleshooting for `install.ps1`.

## Exit Codes

| Code | Name | Description | Fix |
|------|------|-------------|-----|
| 0 | Success | Installation completed successfully | — |
| 1 | General Error | Unhandled PowerShell exception | Check the error message; re-run with `-Verbose` |
| 2 | Invalid Token | Token is empty, too short, or a placeholder | Get a valid token from your admin or GitHub Copilot |
| 3 | WSL2 Missing | WSL2 not installed and auto-install failed | Run `wsl --install` manually as admin, reboot, then re-run |
| 4 | Docker Missing | Docker Desktop not found and install failed | Download Docker Desktop from docker.com, install, reboot |
| 5 | Docker Not Running | Docker daemon not responding after retries | Open Docker Desktop, wait for it to start, then re-run |
| 6 | Network Error | Cannot download required files | Check internet connection; try again |
| 7 | Port Conflict | Port 18789 already in use | Run `netstat -ano | findstr 18789` to find the process; stop it or change port |
| 8 | Permission Denied | Insufficient permissions for operation | Run PowerShell as Administrator |
| 9 | Compose Failed | `docker compose up` failed | Check `docker compose logs`; see Docker Troubleshooting below |
| 10 | Timeout | Container didn't become healthy in time | Check logs: `docker compose logs openclaw-gateway`; may need more time |

## Common Error Messages

### "Token cannot be empty"
**Code:** 2
```
Install-OpenClaw: Token cannot be empty
```
**Fix:** Pass a valid token:
```powershell
Install-OpenClaw "your-actual-token-here"
```

### "Docker is not running"
**Code:** 5
```
Docker Desktop is not running. Starting...
ERROR: Docker did not start within 60 seconds
```
**Fix:**
1. Open Docker Desktop from Start Menu
2. Wait for the whale icon to stop animating
3. Run the installer again

### "WSL2 is required"
**Code:** 3
```
WSL2 is required but not installed
```
**Fix:**
```powershell
# Run as Administrator:
wsl --install
# Reboot, then re-run the installer
```

### "Port 18789 is already in use"
**Code:** 7
```
Port 18789 is already in use by another process
```
**Fix:**
```powershell
# Find what's using the port:
netstat -ano | findstr 18789

# Kill the process (replace PID):
taskkill /PID <PID> /F

# Or use a different port:
# Edit docker-compose.yml: change "18789:18789" to "18800:18789"
```

### "Execution policy restriction"
**Code:** 1
```
install.ps1 cannot be loaded because running scripts is disabled
```
**Fix:**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
# Then re-run the installer
```

### "Compose failed to start"
**Code:** 9
```
ERROR: docker compose up failed
```
**Fix:**
```powershell
cd $env:USERPROFILE\openclaw
docker compose logs --tail 30
# Common causes:
# - Invalid config JSON (check config/openclaw.json syntax)
# - Image pull failed (check internet)
# - Volume mount error (check paths)
```

## Diagnostic Commands

Run these to gather info for troubleshooting:

```powershell
# System info
$PSVersionTable.PSVersion
winver
wsl --status
docker --version
docker compose version

# Container status
docker ps -a
docker compose logs --tail 50

# Network
Test-NetConnection localhost -Port 18789
netstat -ano | findstr 18789

# Disk space
Get-PSDrive C | Select-Object Used, Free

# OpenClaw files
Test-Path "$env:USERPROFILE\openclaw"
Get-ChildItem "$env:USERPROFILE\openclaw" -Recurse | Measure-Object
```

## Getting Help

If the error isn't listed here:
1. Run the smoke test: `.\smoke-test.ps1 -Verbose`
2. Check TROUBLESHOOTING.md in the openclaw-friends repo
3. Gather diagnostic output (see above)
4. Open an issue on GitHub with the error message + diagnostics
