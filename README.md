# OpenClaw Friends Installer

One command to get your own AI assistant running.

## Requirements
- Windows 11
- Internet connection

## Install

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_TOKEN"
```

Replace `YOUR_TOKEN` with the token you were given.

## What it does
1. Checks for WSL2 and Docker Desktop (installs if needed)
2. Creates an OpenClaw configuration
3. Starts OpenClaw in Docker
4. Opens your browser to your personal AI assistant

## After install
Your AI lives at `http://localhost:18789`. Connection info is saved in `%USERPROFILE%\openclaw\CONNECTION-INFO.txt`.
