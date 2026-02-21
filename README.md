# OpenClaw Friends Installer

One command to get your own AI assistant running on Windows.

> **What is OpenClaw?** A personal AI assistant that runs locally in Docker. It uses Claude via GitHub Copilot and can chat with you through a web interface, Discord, and more.

## Quick Start

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/ProfessorDeGraw/openclaw-friends/main/install.ps1 | iex; Install-OpenClaw "YOUR_TOKEN"
```

Replace `YOUR_TOKEN` with the GitHub Copilot token you were given.

That's it! Your browser will open when it's ready.

## Requirements

- **Windows 10/11** (64-bit)
- **Internet connection**
- **A GitHub Copilot token** (ask the person who invited you)

The installer handles everything else automatically:
- WSL2 (installed if missing — requires a reboot, then re-run)
- Docker Desktop (installed if missing via winget or direct download)

## What the Installer Does

| Step | What happens |
|------|-------------|
| 1 | Checks for WSL2 and Docker Desktop, installs if needed |
| 2 | Creates `%USERPROFILE%\openclaw\` with config files |
| 3 | Generates a random security token for your instance |
| 4 | Creates OpenClaw configuration (openclaw.json, auth profiles) |
| 5 | Writes a docker-compose.yml for the gateway service |
| 6 | Runs `docker compose up -d` to start OpenClaw |
| 7 | Opens your browser to your personal AI |

## After Installation

### Access Your AI

- **Web UI:** `http://localhost:18789/?token=YOUR_TOKEN`
- Your token and URL are saved in `%USERPROFILE%\openclaw\CONNECTION-INFO.txt`

### Manage Your Instance

```powershell
cd $env:USERPROFILE\openclaw

# Stop
docker compose down

# Start
docker compose up -d

# View logs
docker compose logs -f

# Update to latest OpenClaw
docker compose down
docker compose pull
docker compose up -d
```

### Add Discord

To connect your AI to a Discord server, edit `%USERPROFILE%\openclaw\config\openclaw.json` and add a Discord channel configuration under `"channels"`. You'll need a Discord bot token — see the [OpenClaw docs](https://github.com/openclaw/openclaw) for setup details.

## Architecture

```
┌─────────────────────────────────────┐
│  Docker                            │
│  ┌───────────────────────────────┐  │
│  │  openclaw-gateway             │  │
│  │  node:22 + openclaw@latest    │  │
│  │  Ports: 18789 (API/WebSocket) │  │
│  │         18790 (Bridge/WebChat)│  │
│  └───────────────────────────────┘  │
│  Volumes:                           │
│    openclaw-config → ~/.openclaw    │
│    openclaw-workspace → workspace   │
└─────────────────────────────────────┘
```

## Data & Persistence

Your AI's memory and configuration live in Docker volumes:
- **openclaw-config** — settings, credentials, session data
- **openclaw-workspace** — workspace files, memory, notes

These survive container restarts. To fully reset, run `docker compose down -v` (⚠️ this deletes all data).

## Troubleshooting

### "WSL2 not found" — installer asks for reboot
This is normal on first install. Reboot, then run the install command again.

### "Docker not found" after Docker Desktop install
Make sure Docker Desktop is running (look for the whale icon in your system tray). Wait for it to say "Docker Desktop is running" before re-running the installer.

### Container starts but web UI doesn't load
OpenClaw takes 1-2 minutes to install on first start (it runs `npm install -g openclaw@latest`). Check progress with:
```powershell
cd $env:USERPROFILE\openclaw
docker compose logs -f
```

### "Port 18789 already in use"
Something else is using that port. Either stop the other service or edit `docker-compose.yml` to change the port mapping.

### Lost your token?
Check `%USERPROFILE%\openclaw\CONNECTION-INFO.txt`

## Uninstall

```powershell
cd $env:USERPROFILE\openclaw
docker compose down -v
cd ..
Remove-Item -Recurse -Force openclaw
```

## Security Notes

- Your gateway token is randomly generated and stored locally
- The Copilot token is stored in Docker volumes (not in plain text on disk after install)
- The web UI is only accessible on localhost by default
- No data is sent anywhere except to GitHub Copilot's API for AI responses

## License

MIT
