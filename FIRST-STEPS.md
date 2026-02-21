# First Steps with OpenClaw 🐾

Welcome! You just installed OpenClaw. Here's how to get started.

---

## 1. Open the Chat

Go to **http://localhost:18789** in your browser.

That's it. You're talking to your assistant.

## 2. Things to Try

- **Say hi.** Your assistant will introduce itself and ask who you are.
- **Give it a name.** Pick something fun — it's yours.
- **Ask it to do something.** Summarize a file, write a script, check the weather.
- **Ask what it can do.** It'll tell you about its available skills.

Don't overthink it. Just talk.

## 3. Send a Message via Webhook

You can message your assistant from scripts, automations, or the command line:

```bash
curl -X POST http://localhost:18789/webhook \
  -H "Content-Type: application/json" \
  -d '{"message": "Hey, what time is it?"}'
```

This is handy for cron jobs, alerts, or integrating with other tools.

## 4. Customize Your Assistant

Your assistant's personality lives in a file called `SOUL.md` in the workspace.

Open it and change whatever you want:
- Tone (casual, formal, snarky, warm)
- Boundaries (what it should/shouldn't do)
- Preferences (how it addresses you, what it prioritizes)

The assistant reads this file every session, so changes take effect immediately.

You'll find it at: `~/.openclaw/workspace/SOUL.md`

## 5. Get Help

Stuck? Have ideas? Just want to hang out?

- **Discord:** https://discord.com/invite/clawd
- **Docs:** https://docs.openclaw.ai
- **Source:** https://github.com/openclaw/openclaw
- **Skills marketplace:** https://clawhub.com

---

That's all you need. Go make something cool. 🚀
