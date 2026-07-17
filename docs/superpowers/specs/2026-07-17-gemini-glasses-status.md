# Gemini-on-Glasses — Status & Remaining Bug (2026-07-17, ~02:00)

## Goal
Ray-Ban Meta glasses -> OpenGlasses -> free Gemini vision + fleet MCP tools, no metered Claude credits.

## FIXED tonight (all in the installed dev build, com.claudiorocha.openglasses)
1. **DAT connection** — approval callback landed in Safari. Fixed: AASA on g2-ai.rochasilva.co.uk now serves both app IDs; associated-domains (applinks:g2-ai...?mode=developer) added to entitlements + project.local.yml so xcodegen keeps it.
2. **Camera capture** — glasses camera fell back to iPhone. Fixed in CameraService.swift: warm-up tolerance (nudge start() on transient .stopped instead of resetting the warming stream), single 30s patient window, no reset mid-warmup, keep-warm teardown (120s), 8s photo timeout.
3. **Vision image size** — LLMImagePreparer maxLongEdge 1568 -> 2576.
4. **Context overflow (1M tokens)** — LLMService.sendMessage now calls HistoryHygiene.pruneImages(keepLast:1) before each send (stale base64 images were re-uploaded every turn).
5. **finalize crash** — tool-loop finalize hard-required message content; Gemini omits content on tool-call turns -> invalidResponse -> cascade to dead Anthropic. Now tolerates missing content (?? turn.text).
6. **Gemini 429/503** — free tier rate-limited the 42KB/116-tool agentic requests. FIXED by enabling billing on the AI Studio project (Tier 1). Verified 5/5 heavy requests -> 200.

## Model config (working)
Custom (OpenAI-compatible) model in app:
- URL: https://generativelanguage.googleapis.com/v1beta/openai
- key: gemini-api-key (AI Studio, billing ENABLED)
- model name: models/gemini-2.5-flash
Persona -> this model. Agentic Features -> Agent Model ALSO set to this model (separate lever; was still Anthropic and caused the credit errors).

## REMAINING BUG (fix next)
Voice agentic path (sendMessageCascading -> buffered runToolLoop) receives Gemini's correct tool_call but does NOT execute it — returns empty, speaks nothing, M4 [tool] count does not increment. Gemini proven correct server-side (finish_reason=tool_calls, tool_calls=[home_status], content=null, even with 116 tools). It executed ONCE earlier (ha_glasses_control fired) on the pre-finalize build, so routing is inconsistent, not fully broken.

Suspects (need runtime logging, not just reading):
- includeTools / tool parsing in sendOpenAICompatible buffered path (LLMService ~1600-1660).
- MCP-tool vs native-tool dispatch: home_status is an MCP tool (16 discovered). Does the custom-OpenAI tool loop route MCP tool_calls to the MCP client, or only native tools?
- Whether finalize is reached with an empty tool-call turn (toolCalls parsed empty).

### Exact next step
Add a log line where tool_calls are parsed AND where they are dispatched (LLMService buffered adapter + ToolLoopDriver.runToolLoop): print count + names + dispatch target. Rebuild, one "home status" test with console attached (xcrun devicectl ... process launch --console). Log shows where the call drops -> one-line fix.

## Infra built tonight (M4, live)
- glasses_router_bridge.py (:3459, launchd com.claudio.glasses-router) — OpenAI-compat intent router: image->Gemini, text->Overseer. HTTPS glasses-router.rochasilva.co.uk, token keychain glasses-router-token. Currently UNUSED (app talks to Gemini directly); keep as fallback / deterministic-routing option.
- claude_glasses_mcp.json + verified claude -p can drive the 16 fleet tools (slow ~60-90s cold start).
- MCP tool-call logging in glasses_tools.py ([tool] lines in mcp-stack-m4.log).

## Build/test loop (reference)
- Build: launchctl kickstart -k gui/$(id -u)/com.claudio.og-tmp-build (MBA; runs xcodebuild to /tmp/og-build, log /tmp/og-xcodebuild-gui.log). Requires the associated-domains entitlement + Apple ID signed in Xcode.
- Install: xcrun devicectl device install app --device 024F5A37-0CB1-5ECC-8BEC-5B074891211F /tmp/og-build/Build/Products/Debug-iphoneos/OpenGlasses.app
- Console: xcrun devicectl device process launch --console --terminate-existing --device 024F5A37... com.claudiorocha.openglasses
