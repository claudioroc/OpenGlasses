import AppIntents

/// AppIntent for the iPhone Action Button — starts listening for a voice command.
/// User configures: Settings → Action Button → Shortcut → "Ask OpenGlasses".
/// Skips wake word detection entirely — just starts transcribing immediately.
struct AskOpenGlassesIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask OpenGlasses"
    static var description = IntentDescription("Start listening for a voice command without the wake word")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Switch to direct mode if not already
        if appState.currentMode != .direct {
            appState.switchMode(to: .direct)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Skip wake word — go straight to transcription
        appState.wakeWordService.stopListening()
        appState.startDirectTranscription()

        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}

/// AppIntent to take a photo and analyze it.
struct TakePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "OpenGlasses Photo"
    static var description = IntentDescription("Take a photo with the glasses and describe what you see")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("take_photo")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        await appState.captureAndAnalyzePhoto()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}

/// Register shortcuts so they appear in the Shortcuts app and Action Button picker.
struct OpenGlassesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // App Shortcut phrases may only interpolate parameters whose type is an
        // AppEntity or AppEnum — Siri needs a finite, resolvable set to predict
        // against. A free-form String (the question) is rejected by the AppIntents
        // metadata processor with a *halting* error that wipes ALL exported intent
        // metadata, so it's resolved two-step via `requestValueDialog`. The persona,
        // however, IS an AppEntity, so it can ride inside the phrase ("Ask Claude on
        // OpenGlasses…"). Persona is optional — the generic phrase falls back to the
        // active/first persona, so this one intent covers both the generic and the
        // persona-targeted ask (and keeps us at iOS's 10-shortcut cap).
        AppShortcut(
            intent: AskPersonaIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask \(\.$persona) on \(.applicationName)",
                "Ask \(\.$persona) \(.applicationName)"
            ],
            shortTitle: "Ask a Question",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: AskOpenGlassesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) listen"
            ],
            shortTitle: "Ask OpenGlasses",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: TakePhotoIntent(),
            phrases: [
                "\(.applicationName) take a photo",
                "Photo with \(.applicationName)"
            ],
            shortTitle: "Take Photo",
            systemImageName: "camera.fill"
        )
        // Plan BQ: the parameterized action shortcut — one phrase covers every action the
        // user has exposed (built-in toggles, harvested capabilities, hand-made actions),
        // because the AppEntity's query is runtime data. Took AnalyzeFood's slot under the
        // 10-shortcut cap (the intent survives; food analysis stays reachable via this
        // shortcut's catalog and the glasses loop). Call
        // `OpenGlassesShortcuts.updateAppShortcutParameters()` after any catalog mutation.
        AppShortcut(
            intent: RunGlassesActionIntent(),
            phrases: [
                "Run \(\.$action) on \(.applicationName)",
                "\(\.$action) with \(.applicationName)"
            ],
            shortTitle: "Run Action",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: DisableListeningIntent(),
            phrases: [
                "Turn off \(.applicationName)",
                "Stop \(.applicationName) listening",
                "\(.applicationName) stop listening"
            ],
            shortTitle: "Stop Listening",
            systemImageName: "mic.slash"
        )
        // Five promoted fleet phrases fit inside iOS's ten-App-Shortcut cap.
        // Every other fleet intent remains discoverable in the Shortcuts app.
        AppShortcut(
            intent: FleetStatusIntent(),
            phrases: [
                "Fleet status with \(.applicationName)",
                "Check my fleet with \(.applicationName)"
            ],
            shortTitle: "Fleet Status",
            systemImageName: "point.3.connected.trianglepath.dotted"
        )
        AppShortcut(
            intent: FleetDailyBriefingIntent(),
            phrases: [
                "Fleet briefing with \(.applicationName)",
                "My fleet briefing on \(.applicationName)"
            ],
            shortTitle: "Fleet Briefing",
            systemImageName: "text.page.badge.magnifyingglass"
        )
        AppShortcut(
            intent: RememberInCortexIntent(),
            phrases: [
                "Remember in Cortex with \(.applicationName)",
                "Save to Cortex with \(.applicationName)"
            ],
            shortTitle: "Remember in Cortex",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: FindFleetDealIntent(),
            phrases: [
                "Find a fleet deal with \(.applicationName)",
                "Look up a deal on \(.applicationName)"
            ],
            shortTitle: "Find Fleet Deal",
            systemImageName: "house.and.flag"
        )
        AppShortcut(
            intent: StartFleetTaskIntent(),
            phrases: [
                "Start a fleet task with \(.applicationName)",
                "Queue fleet work on \(.applicationName)"
            ],
            shortTitle: "Start Fleet Task",
            systemImageName: "bolt.horizontal.circle"
        )
    }
}
