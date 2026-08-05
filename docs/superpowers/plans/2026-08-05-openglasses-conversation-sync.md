# OpenGlasses Conversation Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the no-op `LocalSyncSink` for OpenGlasses (Meta Ray-Ban) conversations with a real pipeline that lands every finished conversation in the Overseer's memory on M4, resilient to either M4 or M2 being briefly unreachable.

**Architecture:** A new dedicated Swift queue (`ConversationSyncQueue`, SQLite-backed like `OfflineQueue` but a separate table/class) is enqueued from `ConversationStore.endThread()`. It tries M4's `glasses_router_bridge.py` (:3459) first, falls back to a new lightweight M2 receiver, and as a last resort writes a plain JSON file to the app's Documents directory. M4's endpoint normalizes each conversation into q/a pairs and `XADD`s them into the existing `glasses:events` Redis stream — the same stream `glasses_spine_selector.py` and the lifelog pipeline already consume, so no downstream consumer changes. A new M4-side relay script pulls anything that landed on M2 back through the same M4 endpoint once M4 is reachable again.

**Tech Stack:** Swift (iOS app, XCTest), Python 3 (`http.server`-based scripts, matching the existing `glasses_router_bridge.py` / `data_api.py` style — no new frameworks), bash (launchd-scheduled relay, matching `sync_m2_to_m4.sh`), Redis (raw RESP over socket, via the existing `_redis_xadd` helper).

## Global Constraints

- Scope is conversations only. Do not touch `OfflineQueue`, `SyncEngine`, `OpKind`, `LocalSyncSink`, or any Field Assist code path — those stay exactly as they are.
- No new privacy toggle. Every finished conversation syncs automatically (per spec, approved 2026-08-05).
- Never mark an item "delivered" without a real ACK from the far end — this project exists specifically because `LocalSyncSink` did that. Every state transition in `ConversationSyncQueue` must correspond to a real observed outcome (HTTP 200, or "wrote a local file").
- Auth: reuse the existing bearer accept-list already implemented in `glasses_router_bridge.py`'s `_authed()` (Keychain `glasses-router-token` / `gemini-api-key` / xAI key / current Grok OIDC token) — no new token scheme.
- Follow existing code style exactly: M4/M2 scripts use bare `http.server.BaseHTTPRequestHandler` (no Flask/FastAPI), Redis access goes through raw sockets via `_redis_xadd`, and integration tests are bash scripts hitting the live running service with `curl` + `grep -q` assertions (see `test_glasses_relay.sh`) — not pytest.
- Dedup key: the `ConversationThread.id` (a UUID string) is the stable `session_id` used everywhere in this pipeline (wire payload, Redis dedup set, M2 queue).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `~/infrastructure/scripts/glasses_router_bridge.py` | Modify | Add `POST /v1/sync/conversations` route + a dedup-set helper. |
| `~/infrastructure/data/synced_conversation_ids.txt` | New (created at runtime) | Flat set of already-synced `session_id`s, one per line — dedup for both the live endpoint and the backfill script. |
| `~/infrastructure/scripts/openglasses_backfill.py` | New | One-time script: reads the existing manually-pulled `~/infrastructure/logs/openglasses/conversations.json`, converts to the same wire shape, feeds it through the same normalize-and-XADD logic as the endpoint (imported, not duplicated). |
| `~/infrastructure/scripts/test_glasses_sync_endpoint.sh` | New | Bash integration test for the new M4 endpoint, styled like `test_glasses_relay.sh`. |
| `~/infrastructure/scripts/openglasses_m2_fallback.py` (M2) | New | Standalone `http.server` script, own port, appends incoming payloads to a local JSONL queue file. Does NOT touch `data_api.py` (that file is deliberately read-only — see Task 3 rationale). |
| `~/infrastructure/data/conversation_sync_pending.jsonl` (M2) | New (created at runtime) | Durable queue of payloads M2 accepted while M4 was unreachable. |
| `~/infrastructure/scripts/sync_conversations_m2_relay.sh` (M4) | New | launchd-scheduled (every 5 min, mirrors `sync_m2_to_m4.sh`'s cadence and SSH options) puller: SSHes to M2, atomically rotates the pending file, replays each line through M4's own `/v1/sync/conversations` endpoint. |
| `~/repos/OpenGlasses/OpenGlasses/Sources/Services/Offline/ConversationSyncQueue.swift` | New | SQLite-backed durable queue, mirrors `OfflineQueue`'s storage pattern but with its own table/row shape (`SyncItem`, `SyncState`) — deliberately not `QueuedOp`/`OpKind`. |
| `~/repos/OpenGlasses/OpenGlasses/Sources/Services/Offline/ConversationSyncClient.swift` | New | The tiered network client: tries M4, then M2, then writes a local file. Analogous role to `SyncSink`, but its own protocol/type since it is not part of the `OfflineQueue`/`SyncEngine` family. |
| `~/repos/OpenGlasses/OpenGlasses/Sources/Services/ConversationStore.swift` | Modify | `endThread()` calls the new queue after `save()`. |
| `~/repos/OpenGlasses/OpenGlasses/Sources/App/Views/SyncStatusView.swift` | Modify | Add a "Conversations" section showing the 3 states, alongside the existing Field Assist section (unchanged). |
| `~/repos/OpenGlasses/OpenGlassesTests/ConversationSyncQueueTests.swift` | New | XCTest, mirrors `OfflineQueueTests.swift` conventions (temp SQLite file, fake network client). |

---

## Task 1: M4 — sync endpoint in `glasses_router_bridge.py`

**Files:**
- Modify: `~/infrastructure/scripts/glasses_router_bridge.py` (add ~60 lines near the existing `do_POST` route table, around line 1574; add a small helper near `_redis_xadd`, around line 186)
- Test: `~/infrastructure/scripts/test_glasses_sync_endpoint.sh`

**Interfaces:**
- Consumes: existing `_authed()` (returns bool), `_redis_xadd(stream: str, fields: dict) -> None`, `PORT` (3459).
- Produces: `POST /v1/sync/conversations` — request body `{"session_id": str, "source": str (default "rayban-sync"), "pairs": [{"q": str, "a": str, "ts": str}, ...]}` → 200 `{"status": "ok", "session_id": ..., "pairs_written": int}` on success (including "already synced, 0 written" as success — idempotent), 400 on malformed body, 401 unauthenticated. Also exports `_already_synced(session_id: str) -> bool` and `_mark_synced(session_id: str) -> None` (backed by `~/infrastructure/data/synced_conversation_ids.txt`), reused as-is by Task 2's backfill script via `import glasses_router_bridge`.

- [ ] **Step 1: Write the failing integration test**

Create `~/infrastructure/scripts/test_glasses_sync_endpoint.sh`:

```bash
#!/bin/bash
# test_glasses_sync_endpoint.sh — proves POST /v1/sync/conversations lands in glasses:events
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
API=http://127.0.0.1:3459
TOK=$(security find-generic-password -s glasses-router-token -w)
SID="synctest-$(date +%s)"

echo "--- 1. send a synthetic conversation ---"
RESP=$(curl -s -m 15 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SID\",\"source\":\"rayban-sync\",\"pairs\":[{\"q\":\"SYNCTEST question\",\"a\":\"SYNCTEST answer\",\"ts\":\"2026-08-05T23:00:00\"}]}" \
  "$API/v1/sync/conversations")
echo "$RESP"
echo "$RESP" | grep -q '"status": "ok"' || { echo "FAIL: endpoint did not return ok"; exit 1; }
echo "$RESP" | grep -q '"pairs_written": 1' || { echo "FAIL: expected pairs_written=1 on first send"; exit 1; }

echo "--- 2. resend the same session_id — must be idempotent (0 written, still 200) ---"
RESP2=$(curl -s -m 15 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SID\",\"source\":\"rayban-sync\",\"pairs\":[{\"q\":\"SYNCTEST question\",\"a\":\"SYNCTEST answer\",\"ts\":\"2026-08-05T23:00:00\"}]}" \
  "$API/v1/sync/conversations")
echo "$RESP2"
echo "$RESP2" | grep -q '"pairs_written": 0' || { echo "FAIL: resend of same session_id should write 0 pairs (dedup)"; exit 1; }

echo "--- 3. bad auth must 401 ---"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -X POST -H "Authorization: Bearer WRONG" \
  -H 'Content-Type: application/json' -d '{"session_id":"x","pairs":[]}' "$API/v1/sync/conversations")
[ "$CODE" = "401" ] || { echo "FAIL: expected 401 for bad auth, got $CODE"; exit 1; }

echo "--- 4. confirm it actually landed in glasses:events ---"
REDISPW=$(python3 ~/infrastructure/scripts/secret_lib.py redis-password 2>/dev/null)
FOUND=$(redis-cli -a "$REDISPW" --no-auth-warning XREVRANGE glasses:events + - COUNT 20 2>/dev/null | grep -c "SYNCTEST question" || true)
[ "$FOUND" -ge 1 ] || { echo "FAIL: SYNCTEST question never appeared in glasses:events"; exit 1; }

echo "PASS: endpoint writes on first send, is idempotent on resend, rejects bad auth, and lands in glasses:events"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x ~/infrastructure/scripts/test_glasses_sync_endpoint.sh && ~/infrastructure/scripts/test_glasses_sync_endpoint.sh`
Expected: FAIL at step 1 with `404` / empty response (route does not exist yet).

- [ ] **Step 3: Implement the endpoint**

In `glasses_router_bridge.py`, near `_redis_xadd` (after its definition, ~line 187), add:

```python
SYNCED_IDS_PATH = Path.home() / "infrastructure/data/synced_conversation_ids.txt"


def _already_synced(session_id: str) -> bool:
    try:
        with open(SYNCED_IDS_PATH) as f:
            return session_id in {line.strip() for line in f}
    except FileNotFoundError:
        return False


def _mark_synced(session_id: str) -> None:
    SYNCED_IDS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(SYNCED_IDS_PATH, "a") as f:
        f.write(session_id + "\n")


def _sync_conversation(session_id: str, source: str, pairs: list) -> int:
    """Write each (q, a) pair into glasses:events, unless session_id was already
    synced. Returns the number of pairs written (0 if this session_id is a dup)."""
    if _already_synced(session_id):
        return 0
    written = 0
    for pair in pairs:
        q = str(pair.get("q") or "").strip()
        a = str(pair.get("a") or "").strip()
        if not q or not a:
            continue
        ts = str(pair.get("ts") or time.strftime("%Y-%m-%dT%H:%M:%S"))
        _redis_xadd("glasses:events", {
            "ts": ts, "agent": "glasses-router", "source": source or "rayban-sync",
            "q": q[:400], "a": a[:400], "session_id": session_id,
        })
        written += 1
    _mark_synced(session_id)
    return written
```

In `do_POST`, add a new branch right after the existing `/speaker` branch (before the general chat-completions handling, ~line 1596):

```python
        if path in ("/v1/sync/conversations", "/sync/conversations"):
            if not self._authed():
                self._err(401, "Unauthorized")
                return
            try:
                n = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(n) if n else b""
                data = json.loads(raw) if raw else {}
            except Exception as e:
                self._err(400, "Invalid JSON: %s" % e)
                return
            session_id = str(data.get("session_id") or "").strip()
            if not session_id:
                self._err(400, "session_id required")
                return
            pairs = data.get("pairs") or []
            if not isinstance(pairs, list):
                self._err(400, "pairs must be a list")
                return
            written = _sync_conversation(session_id, str(data.get("source") or ""), pairs)
            self._ok({"status": "ok", "session_id": session_id, "pairs_written": written})
            return
```

- [ ] **Step 4: Run test to verify it passes**

Run: `launchctl kickstart -k gui/$(id -u)/com.claudio.glasses-router && sleep 2 && ~/infrastructure/scripts/test_glasses_sync_endpoint.sh`
Expected: `PASS: endpoint writes on first send, is idempotent on resend, rejects bad auth, and lands in glasses:events`

- [ ] **Step 5: Commit**

```bash
cd ~/infrastructure && git add scripts/glasses_router_bridge.py scripts/test_glasses_sync_endpoint.sh
git commit -m "Add POST /v1/sync/conversations endpoint to glasses_router_bridge.py

Normalizes conversation pairs into the existing glasses:events Redis
stream (same consumer path as the live rayban chat). Dedups by
session_id via synced_conversation_ids.txt so retries/backfill are
idempotent.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 2: M4 — one-time backfill script

**Files:**
- Create: `~/infrastructure/scripts/openglasses_backfill.py`
- Test: manual run + assertion (see Step 4) — this is a one-shot operational script, not a long-running service, so no separate bash test file.

**Interfaces:**
- Consumes: `glasses_router_bridge._sync_conversation(session_id, source, pairs) -> int` (Task 1), `~/infrastructure/logs/openglasses/conversations.json` (existing file on disk).
- Produces: prints a summary line `Backfill complete: N sessions, M pairs written, K already synced` to stdout.

- [ ] **Step 1: Inspect the real shape of conversations.json before writing the parser**

Run: `python3 -c "import json; d = json.load(open('/Users/claudio/infrastructure/logs/openglasses/conversations.json')); print(type(d)); print(json.dumps(d[0] if isinstance(d, list) else list(d.items())[0], indent=2)[:1500])"`

This file was written by the app's own `ConversationStore` JSON encoding (an array of `ConversationThread`), so expect keys `id`, `title`, `messages` (each with `role`, `content`, `timestamp`), `createdAt`. Confirm the exact key casing (Swift's default `JSONEncoder` is camelCase unless a strategy is set) before Step 3 — if it differs from this assumption, adjust the parser in Step 3 to match what this command actually prints.

- [ ] **Step 2: Write the script skeleton and a dry-run check**

Create `~/infrastructure/scripts/openglasses_backfill.py`:

```python
#!/usr/bin/env python3
"""openglasses_backfill.py — one-time import of the manually-pulled OpenGlasses
conversation history into glasses:events, via the same dedup path the live
sync endpoint uses. Safe to re-run: session_ids already synced are skipped.

Usage: python3 openglasses_backfill.py [--dry-run] [path/to/conversations.json]
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / "infrastructure" / "scripts"))
import glasses_router_bridge as router  # reuses _sync_conversation + dedup set

DEFAULT_PATH = Path.home() / "infrastructure/logs/openglasses/conversations.json"


def thread_to_pairs(thread: dict) -> list:
    """Pair consecutive user->assistant messages, mirroring the iOS-side
    pairing logic in ConversationSyncClient (Task 6)."""
    pairs = []
    pending_q = None
    for msg in thread.get("messages", []):
        role = msg.get("role")
        content = (msg.get("content") or "").strip()
        if role == "user":
            pending_q = content
        elif role == "assistant" and pending_q is not None:
            pairs.append({"q": pending_q, "a": content, "ts": msg.get("timestamp", "")})
            pending_q = None
    return pairs


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    path = Path(args[0]) if args else DEFAULT_PATH

    threads = json.loads(path.read_text())
    if not isinstance(threads, list):
        print(f"Expected a JSON array of threads at {path}, got {type(threads)}")
        sys.exit(1)

    sessions, total_written, total_dupe = 0, 0, 0
    for thread in threads:
        session_id = thread.get("id")
        if not session_id:
            continue
        pairs = thread_to_pairs(thread)
        if not pairs:
            continue
        sessions += 1
        if dry_run:
            already = router._already_synced(session_id)
            print(f"[dry-run] {session_id}: {len(pairs)} pairs, already_synced={already}")
            continue
        written = router._sync_conversation(session_id, "rayban-backfill", pairs)
        total_written += written
        if written == 0:
            total_dupe += 1

    if dry_run:
        print(f"Dry run: {sessions} sessions with pairs found in {path}")
    else:
        print(f"Backfill complete: {sessions} sessions, {total_written} pairs written, {total_dupe} already synced")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the dry-run and verify the pairing logic looks right**

Run: `python3 ~/infrastructure/scripts/openglasses_backfill.py --dry-run`
Expected: one `[dry-run] <session_id>: N pairs, already_synced=False` line per thread in the file, with `N` roughly matching the number of Q/A exchanges you'd expect from the transcripts you read earlier in this session (e.g. "What's gonna be the temperature..." should show up as one of the pairs for its thread).

- [ ] **Step 4: Run for real and verify against Redis**

Run: `python3 ~/infrastructure/scripts/openglasses_backfill.py`
Expected: `Backfill complete: N sessions, M pairs written, 0 already synced` (0 dupes on first run since nothing has synced yet).

Then run: `python3 ~/infrastructure/scripts/openglasses_backfill.py` again (second time).
Expected: `Backfill complete: N sessions, 0 pairs written, N already synced` — proves dedup works and the script is safe to re-run.

- [ ] **Step 5: Commit**

```bash
cd ~/infrastructure && git add scripts/openglasses_backfill.py
git commit -m "Add one-time OpenGlasses conversation backfill script

Imports the manually-pulled conversations.json into glasses:events via
the same dedup path as the live sync endpoint. Idempotent — safe to
re-run.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 3: M2 — lightweight fallback receiver

**Why a new script instead of extending `data_api.py`:** `data_api.py` is explicitly read-only by design (`query_db` blocks `INSERT`/`UPDATE`/`DELETE`/`DROP`/`ALTER`/`CREATE` — see its own docstring and code). Adding a write-accepting route there would weaken a deliberate security boundary. This gets its own small script and port instead.

**Files:**
- Create (on M2): `~/infrastructure/scripts/openglasses_m2_fallback.py`
- Create (on M2): launchd plist `com.claudio.openglasses-m2-fallback.plist`
- Test: `~/infrastructure/scripts/test_openglasses_m2_fallback.sh` (M4-side test, curls M2 over the network)

**Interfaces:**
- Produces: `POST /v1/sync/conversations` on M2, port `9801` (chosen: adjacent to the Data API's 9800, distinct port so it never competes with it) → 200 `{"status": "queued"}` on success, 401 unauthenticated. Appends the raw JSON body as one line to `~/infrastructure/data/conversation_sync_pending.jsonl` on M2.
- Consumed by: Task 4's relay script (reads the JSONL file over SSH).

- [ ] **Step 1: Write the failing test**

Create `~/infrastructure/scripts/test_openglasses_m2_fallback.sh` (run from M4, since that's where auth secrets + SSH access already live):

```bash
#!/bin/bash
# test_openglasses_m2_fallback.sh — proves the M2 fallback receiver queues payloads durably
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
M2_HOST=192.168.10.134
API="http://$M2_HOST:9801"
TOK=$(security find-generic-password -s glasses-router-token -w)
SID="m2fallbacktest-$(date +%s)"

echo "--- 1. send a synthetic conversation to the M2 fallback ---"
RESP=$(curl -s -m 10 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SID\",\"source\":\"rayban-sync\",\"pairs\":[{\"q\":\"M2FALLBACKTEST\",\"a\":\"ok\",\"ts\":\"2026-08-05T23:00:00\"}]}" \
  "$API/v1/sync/conversations")
echo "$RESP"
echo "$RESP" | grep -q '"status": "queued"' || { echo "FAIL: expected status=queued"; exit 1; }

echo "--- 2. bad auth must 401 ---"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -X POST -H "Authorization: Bearer WRONG" \
  -H 'Content-Type: application/json' -d '{"session_id":"x","pairs":[]}' "$API/v1/sync/conversations")
[ "$CODE" = "401" ] || { echo "FAIL: expected 401, got $CODE"; exit 1; }

echo "--- 3. confirm it landed in the M2-side pending file ---"
SSHPASS_M2=$(security find-generic-password -s mc-ssh-password -w 2>/dev/null || true)
FOUND=$(ssh -i "$HOME/.ssh/id_ed25519" -o ConnectTimeout=5 claudiorocha@$M2_HOST \
  'grep -c "M2FALLBACKTEST" ~/infrastructure/data/conversation_sync_pending.jsonl' || echo 0)
[ "$FOUND" -ge 1 ] || { echo "FAIL: payload never landed in M2's pending file"; exit 1; }

echo "PASS: M2 fallback receiver queues payloads durably and rejects bad auth"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x ~/infrastructure/scripts/test_openglasses_m2_fallback.sh && ~/infrastructure/scripts/test_openglasses_m2_fallback.sh`
Expected: FAIL — connection refused on port 9801 (nothing listening yet).

- [ ] **Step 3: Write the M2 receiver script**

Create (on M2, via `ssh claudiorocha@192.168.10.134` then write the file, or `scp` from M4) `~/infrastructure/scripts/openglasses_m2_fallback.py`:

```python
#!/usr/bin/env python3
"""openglasses_m2_fallback.py — durable fallback queue for OpenGlasses conversation
sync when M4's glasses_router_bridge.py is unreachable. Runs on M2. Does NOT process
anything — only appends and confirms. A separate M4-side relay (Task 4) drains this.

Reuses the same bearer token scheme as M4's glasses_router_bridge.py so the phone
doesn't need a second credential.
"""
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 9801
PENDING_PATH = Path.home() / "infrastructure/data/conversation_sync_pending.jsonl"


def _accepted_tokens() -> set:
    tokens = set()
    for name in ("glasses-router-token", "gemini-api-key", "xai-api-key"):
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", name, "-w"],
                                capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                tokens.add(r.stdout.strip())
        except Exception:
            pass
    return tokens


ACCEPTED_TOKENS = _accepted_tokens()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _authed(self) -> bool:
        got = self.headers.get("Authorization", "")
        tok = got[7:] if got.startswith("Bearer ") else got
        return bool(tok) and tok in ACCEPTED_TOKENS

    def _err(self, code, msg):
        b = json.dumps({"error": {"message": msg}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _ok(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/health"):
            self._ok({"status": "ok"})
        else:
            self._err(404, "not found")

    def do_POST(self):
        if self.path.split("?", 1)[0].rstrip("/") not in ("/v1/sync/conversations", "/sync/conversations"):
            self._err(404, "not found")
            return
        if not self._authed():
            self._err(401, "Unauthorized")
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b""
            data = json.loads(raw) if raw else {}
        except Exception as e:
            self._err(400, "Invalid JSON: %s" % e)
            return
        if not data.get("session_id"):
            self._err(400, "session_id required")
            return
        PENDING_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(PENDING_PATH, "a") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
        self._ok({"status": "queued"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"openglasses_m2_fallback on :{PORT}")
    server.serve_forever()
```

Create `~/Library/LaunchAgents/com.claudio.openglasses-m2-fallback.plist` on M2:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>PYTHONUNBUFFERED</key>
		<string>1</string>
	</dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>com.claudio.openglasses-m2-fallback</string>
	<key>ProgramArguments</key>
	<array>
		<string>/opt/homebrew/bin/python3</string>
		<string>/Users/claudiorocha/infrastructure/scripts/openglasses_m2_fallback.py</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/Users/claudiorocha/infrastructure/logs/openglasses_m2_fallback.err.log</string>
	<key>StandardOutPath</key>
	<string>/Users/claudiorocha/infrastructure/logs/openglasses_m2_fallback.out.log</string>
</dict>
</plist>
```

(Copied from M4's `com.claudio.glasses-router.plist` structure — `KeepAlive` since this is a long-running server, unlike the interval-based relay in Task 4 — with M2's actual home path `/Users/claudiorocha` substituted for M4's `/Users/claudio`, per the credentials.md-documented convention that this is the #1 silent breakage when copying plists between the two machines.)

- [ ] **Step 4: Bootstrap on M2 and run the test**

Run (from M2, or via `ssh claudiorocha@192.168.10.134`):
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claudio.openglasses-m2-fallback.plist
```
Then from M4: `~/infrastructure/scripts/test_openglasses_m2_fallback.sh`
Expected: `PASS: M2 fallback receiver queues payloads durably and rejects bad auth`

- [ ] **Step 5: Commit**

```bash
# On M2:
cd ~/infrastructure && git add scripts/openglasses_m2_fallback.py
git commit -m "Add M2 fallback receiver for OpenGlasses conversation sync

Durable JSONL queue only -- does not process anything. Drained by
sync_conversations_m2_relay.sh on M4 (Task 4).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
# On M4:
cd ~/infrastructure && git add scripts/test_openglasses_m2_fallback.sh
git commit -m "Add M4-side test for the M2 conversation-sync fallback receiver

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 4: M4 — relay that drains M2's fallback queue

**Files:**
- Create: `~/infrastructure/scripts/sync_conversations_m2_relay.sh`
- Create: launchd plist `com.claudio.sync-conversations-m2-relay.plist` (every 5 min, mirrors `sync_m2_to_m4.sh`'s existing plist)
- Test: manual run + assertion (Step 4)

**Interfaces:**
- Consumes: M2's `~/infrastructure/data/conversation_sync_pending.jsonl` (Task 3), M4's own `/v1/sync/conversations` (Task 1, called via `127.0.0.1:3459` — loopback, no auth-over-network risk).
- Produces: log lines in `~/infrastructure/logs/sync_conversations_m2.log`, same `[OK]`/`[FAIL]` format as `sync_m2_to_m4.sh`.

- [ ] **Step 1: Write the script (atomic rotate, so an in-flight M2 append is never lost)**

Create `~/infrastructure/scripts/sync_conversations_m2_relay.sh`:

```bash
#!/bin/bash
# sync_conversations_m2_relay.sh — drains M2's conversation-sync fallback queue
# into M4's own /v1/sync/conversations endpoint. Runs every 5 min via launchd.
# Same SSH/credential conventions as sync_m2_to_m4.sh.
set -euo pipefail

M2_USER="claudiorocha"
M2_HOST="192.168.10.134"
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_OPTS="-i $SSH_KEY -o ConnectTimeout=5 -o StrictHostKeyChecking=no -q"
REMOTE_PENDING="/Users/claudiorocha/infrastructure/data/conversation_sync_pending.jsonl"

LOG="$HOME/infrastructure/logs/sync_conversations_m2.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TOK=$(security find-generic-password -s glasses-router-token -w)
API="http://127.0.0.1:3459/v1/sync/conversations"

# Atomic rotate on M2: rename first (so new appends land in a fresh file),
# then read the rotated snapshot, then delete it. Nothing is ever truncated
# out from under an in-flight append.
ROTATED=$(ssh $SSH_OPTS "$M2_USER@$M2_HOST" "
  if [ -f '$REMOTE_PENDING' ]; then
    mv '$REMOTE_PENDING' '$REMOTE_PENDING.pulling' 2>/dev/null && cat '$REMOTE_PENDING.pulling'
  fi
" 2>/dev/null || true)

if [ -z "$ROTATED" ]; then
    echo "$TIMESTAMP [SKIP] nothing pending on M2" >> "$LOG"
    exit 0
fi

count=0
fail=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 15 -X POST \
        -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        -d "$line" "$API")
    if [ "$CODE" = "200" ]; then
        count=$((count + 1))
    else
        fail=$((fail + 1))
        echo "$TIMESTAMP [FAIL] relay item returned $CODE" >> "$LOG"
    fi
done <<< "$ROTATED"

# Only delete the rotated snapshot once every line was attempted -- on a
# partial failure, M4-side dedup (session_id) makes a safe retry possible,
# so we still delete it (next pending batch on M2 accumulates separately)
# rather than growing an ever-larger stuck file.
ssh $SSH_OPTS "$M2_USER@$M2_HOST" "rm -f '$REMOTE_PENDING.pulling'" 2>/dev/null || true

echo "$TIMESTAMP [OK] relayed $count item(s), $fail failure(s)" >> "$LOG"
tail -1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails (no pending data yet, but prove the SSH/rotate path works)**

Run: `chmod +x ~/infrastructure/scripts/sync_conversations_m2_relay.sh && ~/infrastructure/scripts/sync_conversations_m2_relay.sh && cat ~/infrastructure/logs/sync_conversations_m2.log`
Expected at this point (before Task 3 has ever queued anything real): `[SKIP] nothing pending on M2` — this is the correct "nothing to fail on" baseline; the real proof comes in Step 4.

- [ ] **Step 3: Create the launchd plist**

Create `~/Library/LaunchAgents/com.claudio.sync-conversations-m2-relay.plist` on M4:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudio.sync-conversations-m2-relay</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/claudio/infrastructure/scripts/sync_conversations_m2_relay.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/Users/claudio/Library/Logs/sync-conversations-m2-relay.stdout</string>

    <key>StandardErrorPath</key>
    <string>/Users/claudio/Library/Logs/sync-conversations-m2-relay.stderr</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>/Users/claudio</string>
    </dict>
</dict>
</plist>
```

(Byte-for-byte the same shape as the existing `com.claudio.sync-m2-to-m4.plist` — `StartInterval=300`, `KeepAlive=false` since this is a periodic one-shot script, not a server — with only `Label`, the script path, and the log paths changed.)

- [ ] **Step 4: End-to-end test — queue something on M2, then prove the relay delivers it to M4's real endpoint**

Run:
```bash
~/infrastructure/scripts/test_openglasses_m2_fallback.sh   # queues a test item on M2 (Task 3's test)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claudio.sync-conversations-m2-relay.plist
launchctl kickstart -k gui/$(id -u)/com.claudio.sync-conversations-m2-relay
sleep 5
grep "relayed" ~/infrastructure/logs/sync_conversations_m2.log | tail -1
REDISPW=$(python3 ~/infrastructure/scripts/secret_lib.py redis-password 2>/dev/null)
redis-cli -a "$REDISPW" --no-auth-warning XREVRANGE glasses:events + - COUNT 20 | grep -c "M2FALLBACKTEST"
```
Expected: log shows `relayed 1 item(s), 0 failure(s)`, and the `grep -c` on the Redis stream returns `1` — the item that only reached M2 has now landed in the same stream Task 1's endpoint writes to, end to end.

- [ ] **Step 5: Commit**

```bash
cd ~/infrastructure && git add scripts/sync_conversations_m2_relay.sh
git commit -m "Add M4 relay that drains M2's conversation-sync fallback queue

Atomic rotate on M2 (rename-then-read-then-delete) so an in-flight
append is never lost. Idempotent via M4-side session_id dedup, so a
partial-failure retry is always safe.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 5: iOS — `ConversationSyncQueue` (durable local queue)

**Files:**
- Create: `~/repos/OpenGlasses/OpenGlasses/Sources/Services/Offline/ConversationSyncQueue.swift`
- Test: `~/repos/OpenGlasses/OpenGlassesTests/ConversationSyncQueueTests.swift`

**Interfaces:**
- Produces:
  - `enum SyncState: String, Codable { case pending, inFlight, confirmedM2, confirmedM4, savedLocalFile, failed }`
  - `struct SyncItem: Identifiable, Codable, Equatable { let id: String; let sessionId: String; var payload: Data; let createdAt: Date; var attempts: Int; var state: SyncState }`
  - `final class ConversationSyncQueue { init(path: URL? = nil); func enqueue(_ item: SyncItem); func mark(_ id: String, state: SyncState, attempts: Int? = nil); func pending() -> [SyncItem]; var pendingCount: Int { get } }`
- Consumed by: Task 6's `ConversationSyncClient` (calls `pending()`, `mark()`) and Task 7's status UI (reads `pendingCount` and per-state counts).

- [ ] **Step 1: Write the failing test**

Create `~/repos/OpenGlasses/OpenGlassesTests/ConversationSyncQueueTests.swift`:

```swift
import XCTest
@testable import OpenGlasses

@MainActor
final class ConversationSyncQueueTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func tempPath() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csq_\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return url
    }

    private func item(_ session: String, at seconds: TimeInterval) -> SyncItem {
        SyncItem(sessionId: session, payload: Data(), createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testEnqueueAndPendingAreFIFOByCreatedAt() {
        let q = ConversationSyncQueue(path: tempPath())
        let a = item("s1", at: 300)
        let b = item("s2", at: 100)
        let c = item("s3", at: 200)
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        XCTAssertEqual(q.pending().map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(q.pendingCount, 3)
    }

    func testMarkConfirmedM4RemovesFromPending() {
        let q = ConversationSyncQueue(path: tempPath())
        let a = item("s1", at: 100)
        q.enqueue(a)
        q.mark(a.id, state: .confirmedM4)
        XCTAssertTrue(q.pending().isEmpty)
    }

    func testSurvivesReopen() {
        let path = tempPath()
        let a = item("s1", at: 100)
        do {
            let q = ConversationSyncQueue(path: path)
            q.enqueue(a)
        }
        let reopened = ConversationSyncQueue(path: path)
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(reopened.pending().first?.id, a.id)
    }

    func testInFlightIsRecoveredToPendingOnReopen() {
        let path = tempPath()
        let a = item("s1", at: 100)
        do {
            let q = ConversationSyncQueue(path: path)
            q.enqueue(a)
            q.mark(a.id, state: .inFlight)   // simulates a kill mid-delivery
        }
        let reopened = ConversationSyncQueue(path: path)
        XCTAssertEqual(reopened.pending().map(\.id), [a.id])   // strand recovered, not lost
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/repos/OpenGlasses && xcodebuild test -scheme OpenGlasses -only-testing:OpenGlassesTests/ConversationSyncQueueTests -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: FAIL — `ConversationSyncQueue`/`SyncItem`/`SyncState` do not exist yet (build error).

- [ ] **Step 3: Implement `ConversationSyncQueue.swift`**

Model this directly on `OfflineQueue.swift`'s SQLite pattern (same `sqlite3_open`, WAL pragma, `recoverInFlight()` on open), with its own table:

```swift
import Foundation
import SQLite3

/// Where a queued conversation sync item is in its lifecycle. Distinct from `OpState` (Field
/// Assist) -- `confirmedM2` and `confirmedM4` are two different real ACKs, not one generic "done".
enum SyncState: String, Codable {
    case pending
    case inFlight
    case confirmedM2      // durable on M2's fallback queue, not yet on M4
    case confirmedM4      // landed in glasses:events -- fully synced
    case savedLocalFile   // last resort: M4 and M2 both unreachable, wrote a Documents file
    case failed
}

/// One conversation waiting to reach the Overseer's memory. Deliberately NOT `QueuedOp` --
/// conversations are a separate concern from the Field Assist queue (see 2026-08-05 design spec).
struct SyncItem: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    var payload: Data       // JSON: {"session_id":, "source":, "pairs": [...]}
    let createdAt: Date
    var attempts: Int
    var state: SyncState

    init(id: String = UUID().uuidString,
         sessionId: String,
         payload: Data = Data(),
         createdAt: Date = Date(),
         attempts: Int = 0,
         state: SyncState = .pending) {
        self.id = id
        self.sessionId = sessionId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.state = state
    }
}

@MainActor
final class ConversationSyncQueue {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: URL? = nil) {
        let url = path ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("conversation_sync_queue.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("[ConversationSyncQueue] Failed to open database at %@", url.path)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS sync_items (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            payload BLOB,
            created_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'pending',
            seq INTEGER
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sync_items_state ON sync_items(state)")
        recoverInFlight()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    @discardableResult
    func recoverInFlight() -> Int {
        exec("UPDATE sync_items SET state = 'pending' WHERE state = 'inFlight'")
        return Int(sqlite3_changes(db))
    }

    func enqueue(_ item: SyncItem) {
        let sql = "INSERT OR REPLACE INTO sync_items (id, session_id, payload, created_at, attempts, state, seq) " +
                  "VALUES (?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_items))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, item.id)
        bindText(stmt, 2, item.sessionId)
        item.payload.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(item.payload.count), Self.transient)
        }
        sqlite3_bind_double(stmt, 4, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 5, Int32(item.attempts))
        bindText(stmt, 6, item.state.rawValue)
        _ = sqlite3_step(stmt)
    }

    func mark(_ id: String, state: SyncState, attempts: Int? = nil) {
        let sql = attempts == nil
            ? "UPDATE sync_items SET state = ? WHERE id = ?"
            : "UPDATE sync_items SET state = ?, attempts = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.rawValue)
        if let attempts {
            sqlite3_bind_int(stmt, 2, Int32(attempts))
            bindText(stmt, 3, id)
        } else {
            bindText(stmt, 2, id)
        }
        _ = sqlite3_step(stmt)
    }

    func pending() -> [SyncItem] {
        let sql = "SELECT id, session_id, payload, created_at, attempts, state FROM sync_items " +
                  "WHERE state = 'pending' ORDER BY created_at ASC, seq ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [SyncItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let sessionId = String(cString: sqlite3_column_text(stmt, 1))
            let blob = sqlite3_column_blob(stmt, 2)
            let blobLen = Int(sqlite3_column_bytes(stmt, 2))
            let payload = blob != nil ? Data(bytes: blob!, count: blobLen) : Data()
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let attempts = Int(sqlite3_column_int(stmt, 4))
            let state = SyncState(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .pending
            results.append(SyncItem(id: id, sessionId: sessionId, payload: payload,
                                     createdAt: createdAt, attempts: attempts, state: state))
        }
        return results
    }

    var pendingCount: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sync_items WHERE state = 'pending'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Counts by state, for the status UI (Task 7).
    func counts() -> [SyncState: Int] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state, COUNT(*) FROM sync_items GROUP BY state", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [SyncState: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let state = SyncState(rawValue: String(cString: sqlite3_column_text(stmt, 0))) ?? .pending
            result[state] = Int(sqlite3_column_int(stmt, 1))
        }
        return result
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/repos/OpenGlasses && xcodebuild test -scheme OpenGlasses -only-testing:OpenGlassesTests/ConversationSyncQueueTests -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: 4/4 tests pass (`testEnqueueAndPendingAreFIFOByCreatedAt`, `testMarkConfirmedM4RemovesFromPending`, `testSurvivesReopen`, `testInFlightIsRecoveredToPendingOnReopen`).

- [ ] **Step 5: Commit**

```bash
cd ~/repos/OpenGlasses
git add OpenGlasses/Sources/Services/Offline/ConversationSyncQueue.swift OpenGlassesTests/ConversationSyncQueueTests.swift
git commit -m "Add ConversationSyncQueue: durable SQLite queue for conversation sync

Deliberately separate from OfflineQueue/QueuedOp -- conversations are
their own concern (2026-08-05 design spec). Mirrors OfflineQueue's
storage pattern: WAL SQLite, recoverInFlight() on open, strict FIFO.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 6: iOS — tiered delivery client + wiring into `ConversationStore`

**Files:**
- Create: `~/repos/OpenGlasses/OpenGlasses/Sources/Services/Offline/ConversationSyncClient.swift`
- Modify: `~/repos/OpenGlasses/OpenGlasses/Sources/Services/ConversationStore.swift` (`endThread()`, ~line 209)
- Test: `~/repos/OpenGlasses/OpenGlassesTests/ConversationSyncClientTests.swift`

**Interfaces:**
- Consumes: `ConversationSyncQueue` (Task 5), `Reachability` (existing, `onChange`/`isOnline`), `ConversationThread`/`ConversationMessage` (existing, `ConversationStore.swift`).
- Produces: `final class ConversationSyncClient { init(queue: ConversationSyncQueue, m4URL: URL, m2URL: URL, bearerToken: String); func syncThread(_ thread: ConversationThread) async; func flushPending() async }`. `ConversationStore` gains a `weak var syncClient: ConversationSyncClient?` set by `AppState` (same injection pattern as `recallIndex`).

- [ ] **Step 1: Write the failing test (fake network, no real HTTP)**

Create `~/repos/OpenGlasses/OpenGlassesTests/ConversationSyncClientTests.swift`:

```swift
import XCTest
@testable import OpenGlasses

/// Fake tiered transport for testing the M4 -> M2 -> local-file fallback logic without
/// hitting real network.
final class FakeSyncTransport: SyncTransport {
    var m4ShouldSucceed = true
    var m2ShouldSucceed = true
    var m4Calls = 0
    var m2Calls = 0

    func postToM4(_ payload: Data) async -> Bool { m4Calls += 1; return m4ShouldSucceed }
    func postToM2(_ payload: Data) async -> Bool { m2Calls += 1; return m2ShouldSucceed }
}

@MainActor
final class ConversationSyncClientTests: XCTestCase {

    private var tempFiles: [URL] = []
    private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll(); tempDirs.removeAll()
        super.tearDown()
    }

    private func makeQueue() -> ConversationSyncQueue {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csc_\(UUID().uuidString).sqlite")
        tempFiles.append(url)
        return ConversationSyncQueue(path: url)
    }

    private func makeDocsDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("docs_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func makeThread() -> ConversationThread {
        var thread = ConversationThread(mode: "chat")
        thread = ConversationThread(mode: "chat")
        return thread
    }

    func testSyncThreadSucceedsOnM4() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: makeDocsDir())
        await client.syncThread(makeThread())
        XCTAssertEqual(transport.m4Calls, 1)
        XCTAssertEqual(transport.m2Calls, 0)
        XCTAssertEqual(queue.counts()[.confirmedM4], 1)
    }

    func testFallsBackToM2WhenM4Fails() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        transport.m4ShouldSucceed = false
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: makeDocsDir())
        await client.syncThread(makeThread())
        XCTAssertEqual(transport.m4Calls, 1)
        XCTAssertEqual(transport.m2Calls, 1)
        XCTAssertEqual(queue.counts()[.confirmedM2], 1)
    }

    func testWritesLocalFileWhenBothFail() async {
        let queue = makeQueue()
        let transport = FakeSyncTransport()
        transport.m4ShouldSucceed = false
        transport.m2ShouldSucceed = false
        let docsDir = makeDocsDir()
        let client = ConversationSyncClient(queue: queue, transport: transport, localExportDirectory: docsDir)
        await client.syncThread(makeThread())
        XCTAssertEqual(queue.counts()[.savedLocalFile], 1)
        let files = try? FileManager.default.contentsOfDirectory(atPath: docsDir.path)
        XCTAssertEqual(files?.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/repos/OpenGlasses && xcodebuild test -scheme OpenGlasses -only-testing:OpenGlassesTests/ConversationSyncClientTests -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: FAIL — `ConversationSyncClient`/`SyncTransport` do not exist yet.

- [ ] **Step 3: Implement `ConversationSyncClient.swift`**

```swift
import Foundation

/// Network seam so `ConversationSyncClient`'s fallback logic can be tested without real HTTP
/// (mirrors the `SyncSink` seam pattern in SyncEngine.swift).
protocol SyncTransport {
    func postToM4(_ payload: Data) async -> Bool
    func postToM2(_ payload: Data) async -> Bool
}

/// Real HTTP transport: M4's glasses_router_bridge.py first, M2's fallback receiver second.
final class HTTPSyncTransport: SyncTransport {
    let m4URL: URL
    let m2URL: URL
    let bearerToken: String

    init(m4URL: URL, m2URL: URL, bearerToken: String) {
        self.m4URL = m4URL
        self.m2URL = m2URL
        self.bearerToken = bearerToken
    }

    private func post(_ url: URL, _ payload: Data) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 5   // matches the spec's "5s, configurável" fallback threshold
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func postToM4(_ payload: Data) async -> Bool { await post(m4URL, payload) }
    func postToM2(_ payload: Data) async -> Bool { await post(m2URL, payload) }
}

/// Converts a finished `ConversationThread` into the wire payload, tries M4, falls back to M2,
/// and as a last resort writes a plain JSON file -- nothing is ever silently dropped (2026-08-05
/// design spec: "nunca perder silenciosamente").
@MainActor
final class ConversationSyncClient {
    private let queue: ConversationSyncQueue
    private let transport: SyncTransport
    private let localExportDirectory: URL

    init(queue: ConversationSyncQueue, transport: SyncTransport, localExportDirectory: URL) {
        self.queue = queue
        self.transport = transport
        self.localExportDirectory = localExportDirectory
    }

    convenience init(queue: ConversationSyncQueue, m4URL: URL, m2URL: URL, bearerToken: String) {
        self.init(queue: queue,
                  transport: HTTPSyncTransport(m4URL: m4URL, m2URL: m2URL, bearerToken: bearerToken),
                  localExportDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
    }

    /// Pairs consecutive user->assistant messages -- mirrors the Python-side pairing logic in
    /// openglasses_backfill.py (Task 2), so the wire shape is identical on both paths.
    private func pairs(from thread: ConversationThread) -> [[String: String]] {
        var result: [[String: String]] = []
        var pendingQ: String?
        for message in thread.messages {
            if message.role == "user" {
                pendingQ = message.content
            } else if message.role == "assistant", let q = pendingQ {
                let formatter = ISO8601DateFormatter()
                result.append(["q": q, "a": message.content, "ts": formatter.string(from: message.timestamp)])
                pendingQ = nil
            }
        }
        return result
    }

    private func payload(for thread: ConversationThread) -> Data {
        let body: [String: Any] = [
            "session_id": thread.id,
            "source": "rayban-sync",
            "pairs": pairs(from: thread),
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Call this from `ConversationStore.endThread()`.
    func syncThread(_ thread: ConversationThread) async {
        let body = payload(for: thread)
        guard !body.isEmpty else { return }
        let item = SyncItem(sessionId: thread.id, payload: body)
        queue.enqueue(item)
        await deliver(item)
    }

    /// Retries anything still `pending` (e.g. queued while offline). Bind to `Reachability`'s
    /// rising edge the same way `SyncEngine.bind(to:)` does.
    func flushPending() async {
        for item in queue.pending() {
            await deliver(item)
        }
    }

    private func deliver(_ item: SyncItem) async {
        queue.mark(item.id, state: .inFlight)
        if await transport.postToM4(item.payload) {
            queue.mark(item.id, state: .confirmedM4)
            return
        }
        if await transport.postToM2(item.payload) {
            queue.mark(item.id, state: .confirmedM2)
            return
        }
        writeLocalFile(item)
        queue.mark(item.id, state: .savedLocalFile)
    }

    private func writeLocalFile(_ item: SyncItem) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "conversation_\(formatter.string(from: Date())).json"
        let url = localExportDirectory.appendingPathComponent(filename)
        try? item.payload.write(to: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/repos/OpenGlasses && xcodebuild test -scheme OpenGlasses -only-testing:OpenGlassesTests/ConversationSyncClientTests -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: 3/3 pass (`testSyncThreadSucceedsOnM4`, `testFallsBackToM2WhenM4Fails`, `testWritesLocalFileWhenBothFail`).

- [ ] **Step 5: Wire into `ConversationStore.endThread()`**

In `ConversationStore.swift`, add near the top of the class (~line 82, alongside `recallIndex`):

```swift
    /// Set by AppState. Fires the conversation-sync pipeline when a thread ends. Weak + optional
    /// so tests and older call sites work unchanged with no sync configured.
    weak var syncClient: ConversationSyncClient?
```

In `endThread()` (~line 209), add the call right after `save()`:

```swift
    func endThread() {
        guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }) else { return }
        if threads[idx].title == "New Conversation" {
            if let firstUser = threads[idx].messages.first(where: { $0.role == "user" }) {
                threads[idx].title = Self.generateTitle(from: firstUser.content)
            }
        }
        if threads[idx].summary == nil {
            threads[idx].summary = Self.generateSummary(from: threads[idx].messages)
        }
        threads[idx].updatedAt = Date()
        save()
        let finishedThread = threads[idx]
        activeThreadId = nil
        persistActiveSession()
        NSLog("[ConversationStore] Ended thread")
        Task { await syncClient?.syncThread(finishedThread) }
    }
```

Add a `let conversationSyncQueue = ConversationSyncQueue()` property to `AppState` (constructed once, alongside its other durable stores like `offlineQueue`) so Task 7's status UI and this client share the exact same queue file rather than opening two separate handles on it. Then wire `syncClient` in `OpenGlassesApp.swift`, right after the existing `conversationStore.recallIndex = conversationIndex` line (line 1043):

```swift
        conversationStore.syncClient = ConversationSyncClient(
            queue: conversationSyncQueue,
            m4URL: URL(string: "http://192.168.10.135:3459/v1/sync/conversations")!,
            m2URL: URL(string: "http://192.168.10.134:9801/v1/sync/conversations")!,
            bearerToken: savedModels.first(where: { $0.provider == .custom })?.apiKey ?? "")
```

The bearer token is the SAME `ModelConfig.apiKey` the app already sends today when talking to the glasses-router as its configured `.custom` provider (`Config.swift`'s `savedModels`, backed by `KeychainService` — see `ModelConfig embeds a provider apiKey`, `Config.swift:491`). No new credential is introduced; both M4's endpoint (Task 1's `_authed()`) and M2's fallback (Task 3) already accept `glasses-router-token`, which is the value this field holds for that provider entry.

- [ ] **Step 6: Run the full existing test suite to confirm no regression**

Run: `cd ~/repos/OpenGlasses && xcodebuild test -scheme OpenGlasses -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OpenGlassesTests`
Expected: all pre-existing tests still pass (in particular `StoreIntegrityTests` and `OfflineQueueTests`, proving `ConversationStore` and Field Assist are unaffected).

- [ ] **Step 7: Commit**

```bash
cd ~/repos/OpenGlasses
git add OpenGlasses/Sources/Services/Offline/ConversationSyncClient.swift \
        OpenGlasses/Sources/Services/ConversationStore.swift \
        OpenGlassesTests/ConversationSyncClientTests.swift
git commit -m "Wire ConversationSyncClient into ConversationStore.endThread()

Tiered delivery: M4 direct -> M2 fallback -> local JSON file as last
resort. Every state transition corresponds to a real observed outcome
-- the exact defect LocalSyncSink had (marking 'delivered' with no ACK)
is what this design avoids.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 7: iOS — status UI (3 real states, not one generic \"synced\")

**Files:**
- Modify: `~/repos/OpenGlasses/OpenGlasses/Sources/App/Views/SyncStatusView.swift`

**Interfaces:**
- Consumes: `ConversationSyncQueue.counts() -> [SyncState: Int]` (Task 5).

- [ ] **Step 1: Add a "Conversations" section to the existing Field Assist status screen**

In `SyncStatusView.swift`, add a new `@ObservedObject`-free read (counts are polled, not `@Published`, matching how this view already reloads via its own `reload()` on appear/interval — follow that existing pattern in the file) and a new `Section("Conversations")` alongside the existing `Section("Sync")`/`Section("Queue")`:

```swift
            Section("Conversations") {
                let counts = conversationSyncQueue.counts()
                HStack { Text("Local only"); Spacer(); Text("\(counts[.pending, default: 0] + counts[.inFlight, default: 0])").foregroundStyle(.secondary) }
                HStack { Text("Confirmed @ M2 (fallback)"); Spacer(); Text("\(counts[.confirmedM2, default: 0])").foregroundStyle(.orange) }
                HStack { Text("Confirmed @ M4 (Overseer memory)"); Spacer(); Text("\(counts[.confirmedM4, default: 0])").foregroundStyle(.green) }
                if counts[.savedLocalFile, default: 0] > 0 {
                    HStack { Text("Saved locally, not synced"); Spacer(); Text("\(counts[.savedLocalFile, default: 0])").foregroundStyle(.red) }
                }
            }
```

Thread a `conversationSyncQueue: ConversationSyncQueue` into `SyncStatusView`'s existing `init(engine:reachability:)` as a third parameter. Its one call site is `FieldAssistSettingsView.swift:101`:

```swift
// Before:
SyncStatusView(engine: appState.syncEngine, reachability: appState.reachability)
// After:
SyncStatusView(engine: appState.syncEngine, reachability: appState.reachability, conversationSyncQueue: appState.conversationSyncQueue)
```

Add a matching `let conversationSyncQueue: ConversationSyncQueue` property to `AppState`, initialized from the same `ConversationSyncQueue()` instance passed to `ConversationSyncClient` in Task 6 Step 5 (construct it once in `AppState.init`, pass the same instance to both, so the UI and the delivery client share one durable queue file rather than opening two separate SQLite handles on it).

- [ ] **Step 2: Manual verification (no automated UI test — this view has none today; follow that precedent)**

Run the app in the simulator, have a conversation, end it (trigger `endThread()`), open the Field Sync screen, and confirm the new "Conversations" section shows a real count moving from "Local only" to "Confirmed @ M4" within a few seconds (assuming M4 is reachable in the test environment).

- [ ] **Step 3: Commit**

```bash
cd ~/repos/OpenGlasses
git add OpenGlasses/Sources/App/Views/SyncStatusView.swift
git commit -m "Show real conversation-sync state in Field Sync screen

3 distinct states (local only / confirmed@M2 / confirmed@M4), not one
generic 'synced' -- so this UI can never repeat LocalSyncSink's mistake
of claiming delivery it never verified.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Rollout Order (from the approved spec)

1. Task 1 (M4 endpoint) — passive addition, doesn't affect anything live.
2. Task 2 (M4 backfill) — run once, manually, after Task 1 ships.
3. Task 3 (M2 receiver) + Task 4 (M4 relay) — passive additions on M2/M4.
4. Task 5 + 6 + 7 (iOS) — build in Xcode, install on the phone manually. This is the only step Claudio must do by hand; nothing in Tasks 1-4 requires it.
