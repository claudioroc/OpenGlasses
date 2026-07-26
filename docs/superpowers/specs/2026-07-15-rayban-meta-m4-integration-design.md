# Ray-Ban Meta ↔ M4 Overseer Integration

**Date:** 2026-07-15
**Status:** Approved
**Scope:** Connect the OpenGlasses iOS app (Ray-Ban Meta glasses) to M4's cloud agents via MCP, so the glasses can query HA, media center, RE pipeline, messages, and lifelog memory through the existing Overseer infrastructure.

## Context

The Even Realities G2 glasses already have full M4 integration via Even Terminal (voice bridge), the glasses gateway CLI, and 7 domain-specific control scripts. The Ray-Ban Meta integration through the OpenGlasses iOS app currently only feeds lifelog indirectly via WhatsApp image proxying.

The OpenGlasses app has a complete MCP client infrastructure: catalog-based one-tap server install, HTTP transport (live), tool discovery, Plan R safety screening, and an LLM agent that can invoke tools. M4 has an MCP server (`server.py` on port 3001) behind Cloudflare tunnel at `m4-mcp.rochasilva.co.uk/mcp`, with bearer-token auth.

The gap: M4's MCP server exposes only generic tools (`run_bash`, `read_file`, `write_file`, `list_dir`) — too dangerous and unstructured for a mobile app. We need purpose-built, glasses-scoped tools.

## Architecture Decision

**Approach A (chosen): Glasses-scoped MCP tools on M4.**

Add purpose-built tools to M4's MCP server that wrap the existing `*_glasses_control.py` scripts. The iOS app connects via its existing MCP client and catalog. One integration path; both sides already exist.

Rejected alternatives:
- **B (REST API):** Fastest but bypasses the app's MCP architecture, adds a new service to maintain.
- **C (Hybrid MCP + REST):** Over-engineered for v1.

## 1. M4-Side: Glasses MCP Tools

New module `glasses_tools.py` in `~/repos/infra-scripts/mcp-server/` registers 12 tools on the existing FastMCP instance. Each tool is a fixed script invocation with validated parameters — no shell injection surface.

### Tool Inventory

| MCP Tool | Wraps Script | Parameters | Description |
|---|---|---|---|
| `home_status` | `ha_glasses_control.py status` | none | Temps, switches, media, entity overview |
| `home_control` | `ha_glasses_control.py <command> [args]` | `command: str, args: str = ""` | Lights, switches, scenes, media, audio control |
| `media_status` | `mc_glasses_control.py status` | none | Downloads, disk, library counts |
| `media_search` | `mc_glasses_control.py <type> <query>` | `type: "movies"\|"shows", query: str` | Search Radarr/Sonarr library |
| `deals_status` | `re_glasses_control.py <view>` | `view: "status"\|"hot"\|"pipeline"\|"top"` | RE pipeline overview |
| `deal_lookup` | `re_glasses_control.py deal <name>` | `name: str` | Specific deal details |
| `messages_recent` | `wa_glasses_control.py recent` | `count: int = 10` | Recent WhatsApp messages |
| `email_check` | `email_glasses_control.py unread` | none | Unread email count + priority items |
| `notifications` | `notify_glasses_control.py check` | none | Aggregated system notifications |
| `glasses_dashboard` | `glasses_gateway.py status` | none | Combined one-line dashboard (HA + MC + RE) |
| `memory_recall` | `glasses_memory.py recall <query>` | `query: str, days: int = 7` | Recall context from lifelog |
| `memory_log` | `glasses_memory.py log rayban <summary>` | `summary: str` | Log observation to lifelog |

### Implementation Pattern

Each tool function:
1. Validates parameters (enum checks, length limits, no shell metacharacters)
2. Invokes the script via `subprocess.run()` with an explicit argument list (no `shell=True`)
3. Returns the script's stdout (already HUD-formatted, ~48 chars x 14 lines)
4. Has a 10s timeout (scripts are <1s normally; timeout catches hangs)

```python
# Example — glasses_tools.py
SCRIPTS_DIR = os.path.expanduser("~/infrastructure/scripts")

@mcp.tool()
def home_status() -> str:
    """Get home status: temperatures, switches, media, entities."""
    return _run_glasses_script("ha_glasses_control.py", ["status"])

@mcp.tool()
def home_control(command: str, args: str = "") -> str:
    """Control home devices. Commands: lights, switch, scene, media, audio, temp, entity, rooms, scenes."""
    allowed = {"lights", "switch", "scene", "media", "audio", "temp", "entity", "rooms", "scenes"}
    if command not in allowed:
        return f"Unknown command: {command}. Use: {', '.join(sorted(allowed))}"
    cmd = [command] + (args.split() if args else [])
    return _run_glasses_script("ha_glasses_control.py", cmd)

def _run_glasses_script(script: str, args: list[str]) -> str:
    """Run a glasses control script with validated args. No shell=True."""
    result = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS_DIR, script)] + args,
        capture_output=True, text=True, timeout=10,
        env={**os.environ, "HOME": os.path.expanduser("~")}
    )
    output = result.stdout.strip()
    if result.returncode != 0:
        output += f"\n[error: {result.stderr.strip()[:200]}]"
    return output or "(no data)"
```

### Registration

`glasses_tools.py` imports the `mcp` FastMCP instance from `server.py` and registers tools on it. The tools are conditionally loaded based on which auth token was used (see Section 2).

## 2. Auth & Networking

### Separate Token for Glasses

A dedicated bearer token stored in M4 Keychain as `glasses-mcp-token`. Separate from the existing `~/.mcp_secret` used by Claude Code / Gemini CLI.

**Rationale:** Different blast radius. If the glasses token leaks (phone lost/stolen), revoke it without breaking Claude Code and Gemini sessions.

### Token-Scoped Tool Visibility

Extend `auth_middleware.py` to identify which token authenticated the request:

- `glasses-mcp-token` → request is tagged `scope=glasses` → only glasses tools visible
- `~/.mcp_secret` → request is tagged `scope=full` → all tools visible (generic + glasses)

Implementation: the middleware sets a request-scoped attribute (e.g., `request.state.mcp_scope`). The FastMCP tool registration uses a wrapper that checks scope before executing.

### Network Path

Same Cloudflare tunnel (`m4-mcp.yml`) already serving `m4-mcp.rochasilva.co.uk`. Same port 3001. No new tunnel or port config needed.

## 3. iOS App: MCP Catalog Entry

Add M4 to `mcp-catalog.json` (bundled in the app):

```json
{
  "id": "m4-overseer",
  "label": "Home Overseer (M4)",
  "transport": "http",
  "url_template": "https://m4-mcp.rochasilva.co.uk/mcp",
  "auth": { "kind": "bearer", "hint": "Token from M4 Keychain: glasses-mcp-token" },
  "fields": [],
  "scopes": ["home", "media", "deals", "messages", "memory"],
  "icon": "house.badge.wifi",
  "notes": "Home infrastructure via Mac Mini M4. Controls HA, media center, RE pipeline, messages, and lifelog memory."
}
```

### Install Flow

1. User opens Settings → MCP Servers → Catalog
2. Taps "Home Overseer (M4)"
3. Enters the bearer token (read once from M4 Keychain, entered on phone)
4. App runs `tools/list` → discovers 12 glasses tools
5. Plan R safety screen shows discovered tools → user confirms
6. Done — tools available to the LLM agent

No code changes to `MCPCatalog`, `MCPClient`, or `MCPTransport` — the existing infrastructure handles this end-to-end.

## 4. iOS App: Agent System Prompt Addition

Add context to the agent's system prompt so it knows when to use M4 tools:

```
When the user asks about home status, temperature, lights, or appliances, use the home_status or home_control tools.
When asking about movies, shows, downloads, or media, use media_status or media_search.
When asking about property deals or the pipeline, use deals_status or deal_lookup.
For recent messages, use messages_recent. For email, use email_check.
For a combined overview, use glasses_dashboard.
Use memory_recall before responding to contextual questions. Use memory_log to record notable observations.
```

This is additive — it doesn't change the agent's existing local capabilities (camera vision, local LLM, etc.).

## 5. Memory Integration

### Write Path (App → Lifelog)

When the Ray-Ban Meta takes a photo or the user asks a question through the app, the LLM agent calls `memory_log` with a summary. This posts to lifelog `:9825` tagged `[glasses:rayban]`.

This replaces the current indirect path (photo → WA self-chat → `whatsapp_watcher.py` → lifelog) with a direct MCP tool call. The WA path continues to work as a fallback for photos shared outside the app.

### Read Path (Lifelog → App)

The LLM agent calls `memory_recall` to pull recent context before responding. Provides session continuity: "what was I looking at earlier?"

### Cross-Device Coherence

Both G2 and Ray-Ban write to the same `agent_learning.db` via lifelog `:9825`. Device tags (`[glasses:g2]` vs `[glasses:rayban]`) enable per-device filtering. A G2 observation is recallable from Ray-Ban and vice versa.

## 6. Build Order

| Step | Side | What | Dependencies |
|------|------|------|-------------|
| 1 | M4 | `glasses_tools.py` — 12 tool functions wrapping existing scripts | Existing `*_glasses_control.py` scripts |
| 2 | M4 | Auth scoping — extend `auth_middleware.py` for two-token gating | Step 1 |
| 3 | M4 | Token setup — generate `glasses-mcp-token` in Keychain, test via curl | Step 2 |
| 4 | iOS | Catalog entry — add `m4-overseer` to `mcp-catalog.json` | Step 3 (token exists) |
| 5 | iOS | Agent prompt — add M4 tool routing context | Step 4 |
| 6 | E2E | Test — install server in app, verify discovery, call `glasses_dashboard`, confirm HUD | All above |

## 7. What's NOT in Scope

- Display backend abstraction (`GlassesDisplayBackend` protocol / EVEN renderer) — separate effort
- Meta DAT developer approval — orthogonal; this integration works with the app's existing LLM + HUD path
- `home_control` write actions (switching lights, etc.) — included in the tool set but gated by HA's own auth; no additional safety concern beyond what the G2 fast-path already does
- SSE transport in the app's MCP client — HTTP is live and sufficient; SSE streaming is a future enhancement

## Files Changed

**M4 (`~/repos/infra-scripts/mcp-server/`):**
- `glasses_tools.py` — NEW: 12 MCP tool functions
- `auth_middleware.py` — MODIFIED: two-token support + scope tagging
- `server.py` — MODIFIED: import and register `glasses_tools`

**iOS (`~/repos/OpenGlasses/`):**
- `OpenGlasses/Sources/Resources/mcp-catalog.json` — MODIFIED: add `m4-overseer` entry
- `OpenGlasses/Sources/Utils/Config.swift` — MODIFIED: add M4 tool routing context to `Config.systemPrompt` (line ~548, the active preset's prompt fallback)

**M4 Keychain:**
- `glasses-mcp-token` — NEW: bearer token for glasses MCP access
