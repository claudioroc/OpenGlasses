# Glasses Intent-Router Bridge — Design & Status

**Built 2026-07-16. Status: LIVE and verified end-to-end.**

## What it is
One OpenAI-compatible endpoint that routes each glasses request to the cheapest
capable backend (the 2026 model-router pattern; validated by VisionClaw & others):

- **Image present** → Gemini 2.5 Flash (AI Studio key, free tier ~1500/day) — cheap, strong vision
- **Text only** → Claude Overseer (claude_proxy :9810, Claude Code subscription) — full personal context, memory, fleet tools

Deterministic routing on payload shape (not model discretion) — so the glasses can't
"forget" to consult the Overseer. Gemini = eyes, Claude Overseer = brain.

## Components (all on M4)
- `~/infrastructure/scripts/glasses_router_bridge.py` — the bridge (stdlib only)
- `~/Library/LaunchAgents/com.claudio.glasses-router.plist` — launchd service (GUI domain → keychain access), port 3459
- Cloudflare tunnel: `glasses-router.rochasilva.co.uk` → `127.0.0.1:3459` (ingress in `~/.cloudflared/m4-mcp.yml`, CNAME added)
- Auth token: keychain `glasses-router-token` (also saved `~/.config/glasses_router_token.env`)
- Keys used: keychain `gemini-api-key` (vision), claude_proxy :9810 (Overseer)

## Verified
- `GET /health` → `{"status":"ok","gemini_key":true}`
- Vision route (public HTTPS + auth): wine label → "CHATEAU MARGAUX 2015"
- Text route: "Who is Iryna?" → "Iryna is Claudio's wife." (via Overseer, full context)

## App config (OpenGlasses — the remaining step, needs the phone)
Settings → AI Models → the "Custom" (OpenAI-compatible) model:
- Base URL: `https://glasses-router.rochasilva.co.uk/v1`
- API key / token: the `glasses-router-token` value
- Model name: anything (e.g. `glasses-router`) — the bridge ignores it and routes by payload
Then point the glasses persona at that model. Vision + context both flow through it,
no Anthropic API credits burned for vision.

## Ops
- `curl https://glasses-router.rochasilva.co.uk/health`
- `launchctl kickstart -k gui/$(id -u)/com.claudio.glasses-router`  (restart)
- logs: `~/infrastructure/logs/glasses_router.out.log`

## Future (fresh-session upgrades)
- Gemini Live (continuous vision stream) instead of snapshot — smoother, what VisionClaw uses
- Explicit intent classifier for ambiguous text (some questions want vision context too)
- Per-request model choice header; streaming responses
