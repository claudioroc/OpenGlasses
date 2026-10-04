# Codex Cloud Harness Sign-Off (2026-08-05)

**Status:** SIGN OFF WITH CHANGES
**Author:** Codex
**Scope:** `codexCloud` harness path in OpenGlasses
**Validation Date:** 2026-08-05

---

## Executive Verdict

I am signing off the `codexCloud` harness path for merge/use with one remaining caveat.

What is now validated:

- the preset wiring for `codexCloud` is coherent in app code;
- the package resource collision that blocked the harness tests has been fixed in `Package.swift`;
- the iOS XCTest host bootstrap no longer crashes on Wearables during harness tests;
- the targeted harness suite passes on the MBA simulator.

What is still not validated:

- live end-to-end verification against the real Codex Cloud endpoint or a known-compatible bridge.

So the correct claim as of **2026-08-05** is:

> `codexCloud` is signed off at the app integration and targeted test level, but the live remote contract is still a pending runtime verification item.

---

## Evidence

### Code paths reviewed

- Preset contract: [OpenGlasses/Sources/Services/AgentHarness/Adapters/AgentHarnessPreset.swift](../../OpenGlasses/Sources/Services/AgentHarness/Adapters/AgentHarnessPreset.swift)
- Harness kind model: [OpenGlasses/Sources/Services/AgentHarness/AgentModels.swift](../../OpenGlasses/Sources/Services/AgentHarness/AgentModels.swift)
- Tool routing: [OpenGlasses/Sources/Services/NativeTools/AgentControlTool.swift](../../OpenGlasses/Sources/Services/NativeTools/AgentControlTool.swift)
- App/runtime wiring: [OpenGlasses/Sources/App/OpenGlassesApp.swift](../../OpenGlasses/Sources/App/OpenGlassesApp.swift)

### Fixes required to complete validation

- `Package.swift`
  - replaced broad `.process("Resources")` with explicit resource entries and `.copy("Resources/Vaults")` to stop duplicate-resource failures.
- [OpenGlasses/Sources/App/OpenGlassesApp.swift](../../OpenGlasses/Sources/App/OpenGlassesApp.swift)
  - test runtime now forces Wearables skip during XCTest bootstrap.
- [OpenGlasses/Sources/Services/GlassesConnectionService.swift](../../OpenGlasses/Sources/Services/GlassesConnectionService.swift)
  - removed eager device observation from `init()`; Wearables observers now attach only after successful SDK configure.

### MBA simulator validation

Validated on **2026-08-05** via `mba-ts` with:

```bash
xcodebuild test \
  -project OpenGlasses.xcodeproj \
  -scheme OpenGlasses \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:OpenGlassesTests/AgentHarnessPresetTests \
  -only-testing:OpenGlassesTests/AgentCustomHarnessTests \
  -only-testing:OpenGlassesTests/AgentSessionTests \
  CODE_SIGNING_ALLOWED=NO
```

Result:

- `AgentCustomHarnessTests`: **24 passed**
- `AgentHarnessPresetTests`: **9 passed**
- `AgentSessionTests`: **18 passed**
- Total: **51 passed, 0 failed**
- Final runner status: `** TEST SUCCEEDED **`

---

## Residual Caveat

This is still a **sign-off with changes**, not an unconditional production sign-off, because the
remote API contract has not yet been proven against a live Codex Cloud endpoint in this validation
cycle.

That caveat is operational, not structural:

- the local app wiring is good;
- the targeted harness behavior is tested and passing;
- the remaining gap is a real-network compatibility check.

---

## Final Decision

**SIGN OFF WITH CHANGES**

Approved for the current app integration and harness test scope on **2026-08-05**.
