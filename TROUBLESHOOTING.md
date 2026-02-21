# Troubleshooting 🔧

Something not working? Don't panic. Most issues have simple fixes. Find your problem below.

---

## 1. "WSL2 is not installed" or Windows asks you to restart

**What you see:** An error mentioning WSL2, or Windows says it needs to restart to finish setup.

**Why:** Docker on Windows needs WSL2 (Windows Subsystem for Linux) to run. It's either not installed or not finished setting up.

**Fix:**
1. Open PowerShell as Administrator
2. Run: `wsl --install`
3. Restart your computer (yes, actually restart — not just close the lid)
4. After restart, try again

---

## 2. Docker Desktop not running

**What you see:** Errors like "docker: command not found" or "Cannot connect to the Docker daemon."

**Why:** Docker Desktop isn't open. It needs to be running in the background.

**Fix:**
1. Search for "Docker Desktop" in your Start menu (Windows) or Applications (Mac)
2. Open it
3. Wait for the whale icon in your taskbar/menu bar to stop animating — that means it's ready
4. Try again

---

## 3. Docker Desktop installed but engine not started

**What you see:** Docker Desktop is open but you get errors about the engine not running, or the Docker icon shows a yellow/orange dot.

**Why:** Docker Desktop is open but the engine inside it hasn't fully started yet.

**Fix:**
1. Look at Docker Desktop — if it says "Docker Desktop starting...", just wait
2. If it's stuck, close Docker Desktop completely and reopen it
3. On Windows: make sure WSL2 is enabled (see problem #1)
4. If it keeps failing, try: Settings → General → check "Use the WSL 2 based engine" → Apply & Restart

---

## 4. Port 18789 already in use

**What you see:** Error like "port is already allocated" or "address already in use" when starting the container.

**Why:** Something else on your computer is already using port 18789. Could be a previous OpenClaw that didn't shut down cleanly.

**Fix:**
1. Stop any running OpenClaw containers: `docker compose down`
2. If that doesn't work, find what's using the port:
   - **Windows:** `netstat -ano | findstr 18789`
   - **Mac/Linux:** `lsof -i :18789`
3. Stop whatever is using it, or change the port in your `.env` file to something else (like 18790)

---

## 5. Container starts but gateway never becomes ready

**What you see:** The container is running (you can see it in Docker Desktop) but when you open the browser, nothing loads. Logs might show "waiting for gateway" or similar.

**Why:** The gateway process inside the container is still starting up, crashed, or can't reach an AI provider.

**Fix:**
1. Give it a minute — first startup can be slow while it downloads what it needs
2. Check the logs: `docker compose logs -f`
3. Look for error messages — common ones:
   - **API key issues:** Make sure your AI provider key in `.env` is correct
   - **Network issues:** Make sure your internet connection is working
4. If stuck, restart: `docker compose restart`

---

## 6. Token invalid or expired

**What you see:** You can open the browser page but get "unauthorized" or "invalid token" errors. Or the assistant doesn't respond.

**Why:** The gateway token in your setup doesn't match what the container expects.

**Fix:**
1. Check your `.env` file — look for `OPENCLAW_GATEWAY_TOKEN`
2. Make sure the token in your browser URL matches the one in `.env`
3. If you changed the token, restart the container: `docker compose restart`
4. When in doubt, set a new simple token in `.env` and restart

---

## 7. Cannot connect from browser

**What you see:** Browser shows "can't reach this page" or "connection refused" when going to `localhost:18789`.

**Why:** The container isn't running, the port is wrong, or a firewall is blocking it.

**Fix:**
1. Make sure the container is running: `docker compose ps`
2. Double-check you're going to the right address: `http://localhost:18789`
3. Try `http://127.0.0.1:18789` instead (sometimes "localhost" doesn't resolve correctly)
4. Check that your firewall or antivirus isn't blocking port 18789
5. If using a VPN, try disconnecting it temporarily

---

## 8. Container keeps restarting

**What you see:** Docker Desktop shows the container stopping and starting over and over. Status flips between "running" and "restarting."

**Why:** Something inside the container is crashing on startup — usually a bad config or missing environment variable.

**Fix:**
1. Check the logs for the crash reason: `docker compose logs --tail 50`
2. Look for the error message right before each restart
3. Common causes:
   - **Missing `.env` file:** Make sure it exists and has the required variables
   - **Bad YAML:** Check `docker-compose.yml` for typos (YAML is picky about spaces)
   - **Out of memory:** Docker Desktop might need more RAM — go to Settings → Resources → increase memory to at least 4GB
4. Fix the issue, then: `docker compose down && docker compose up -d`

---



---

## Frequently Asked Questions

### Q: How long does the first install take?
**A:** 2-5 minutes on a decent internet connection. The installer downloads Docker (~500MB if not installed), then pulls the Node.js container image (~350MB), and finally installs OpenClaw via npm. Subsequent starts are much faster (~10 seconds).

### Q: Do I need admin/elevated permissions?
**A:** Only if WSL2 or Docker Desktop aren't already installed. The installer will tell you if it needs admin rights. Once Docker is set up, no admin required.

### Q: Can I install on a machine without internet?
**A:** No — the installer needs to download Docker, container images, and the OpenClaw npm package. You need internet for the initial install and for AI responses (they go through GitHub Copilot or Azure OpenAI).

### Q: What if my Copilot token starts with `ghu_` vs `gho_`?
**A:** Both work. `ghu_` is a user token, `gho_` is an organization token. The installer accepts either. If your token doesn't start with `ghu_` or `gho_`, double-check you copied the right one.

### Q: Can I change the port from 18789?
**A:** Yes. Edit `docker-compose.yml` in your install folder (`%USERPROFILE%\openclaw\`) and change `"18789:18789"` to `"YOUR_PORT:18789"`. Then restart: `docker compose restart`.

### Q: Where is my data stored?
**A:** In Docker named volumes (`openclaw-config` and `openclaw-workspace`). These survive container restarts and updates. They're only deleted if you explicitly run `docker compose down -v`. Your config files are also in `%USERPROFILE%\openclaw\config\`.

### Q: How do I update OpenClaw?
**A:** Run these commands in your install directory:
```
docker compose down
docker compose up -d
```
The container reinstalls the latest OpenClaw on every start.

### Q: Can I run multiple OpenClaw instances?
**A:** Yes, but each needs different ports. Copy the install directory, change the ports in `docker-compose.yml`, and use a different container name.

### Q: The installer said "Token looks too short"
**A:** Your token needs to be at least 10 characters. Make sure you copied the entire token — they're usually 40+ characters starting with `ghu_`.

### Q: PowerShell says "running scripts is disabled on this system"
**A:** Windows blocks scripts by default. Run this first (as Administrator):
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
Then try the install command again.

### Q: How do I completely uninstall?
**A:** Run in PowerShell:
```powershell
cd $env:USERPROFILE\openclaw
docker compose down -v
cd ..
Remove-Item -Recurse -Force openclaw
```
This stops containers, removes volumes (all data), and deletes the install directory.

### Q: My antivirus flagged the installer
**A:** The installer is a PowerShell script that downloads software from official sources (Docker, npm). Some antivirus tools flag PowerShell downloads. You can review the script source on [GitHub](https://github.com/ProfessorDeGraw/openclaw-friends/blob/main/install.ps1) — it's fully open source.
## Still stuck?

Come ask for help — real humans who've been through it:

👉 **[Join us on Discord](https://discord.com/invite/clawd)**

Tell us what you see and we'll help you sort it out. No question is too basic.
