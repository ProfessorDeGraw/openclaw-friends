# OpenClaw Friends Edition 🐾

> One command to get your own AI assistant.

## Quick Start (Windows)

```powershell
irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_COPILOT_TOKEN"
```

### What you need:
- Windows 10/11
- A GitHub Copilot token (ask whoever invited you)

### What it does:
1. Installs WSL2 if needed (may require restart)
2. Installs Docker Desktop if needed
3. Sets up OpenClaw in `%USERPROFILE%\openclaw`
4. Opens your AI assistant in the browser

## After Install

Open http://localhost:18789 and start chatting! Your assistant can:
- Answer questions
- Remember things you tell it
- Check the weather
- Help you think through problems

See [WELCOME.md](WELCOME.md) for more ideas.

## Uninstall

```powershell
irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/uninstall.ps1 | iex; Uninstall-OpenClaw
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.

## About

Built with [OpenClaw](https://docs.openclaw.ai) | [Community Discord](https://discord.com/invite/clawd)
