import Foundation

/// A user-configurable quick action button shown on the main screen.
struct QuickAction: Codable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var type: ActionType

    enum ActionType: String, Codable, CaseIterable, Identifiable {
        case prompt = "prompt"
        case photo = "photo"
        case photoThenPrompt = "photoThenPrompt"
        case homeAssistant = "homeAssistant"
        case siriShortcut = "siriShortcut"
        case openApp = "openApp"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .prompt: return "Text Prompt"
            case .photo: return "Take Photo"
            case .photoThenPrompt: return "Photo + Prompt"
            case .homeAssistant: return "Home Assistant"
            case .siriShortcut: return "Siri Shortcut"
            case .openApp: return "Open App"
            }
        }

        var description: String {
            switch self {
            case .prompt: return "Send a text prompt to the AI"
            case .photo: return "Capture and describe a photo"
            case .photoThenPrompt: return "Capture a photo with a custom prompt"
            case .homeAssistant: return "Call a Home Assistant service"
            case .siriShortcut: return "Run a Siri Shortcut by name"
            case .openApp: return "Open an app via URL scheme"
            }
        }
    }

    /// The prompt text (for .prompt and .photoThenPrompt types)
    var promptText: String?
    /// Home Assistant service call (e.g., "light.turn_off") for .homeAssistant type
    var haService: String?
    /// Home Assistant entity ID (e.g., "light.living_room") for .homeAssistant type
    var haEntityId: String?
    /// Extra data as JSON string for .homeAssistant type (e.g., {"brightness": 50})
    var haData: String?
    /// Siri Shortcut name for .siriShortcut type
    var shortcutName: String?
    /// URL scheme for .openApp type (e.g., "weixin://")
    var urlScheme: String?

    static let travelTemplates: [QuickAction] = [
        // Translate Sign lives in `smartDial` (always on the main row).
        QuickAction(
            id: "travel-ask-local-phrase",
            label: "Local Phrase",
            icon: "globe",
            type: .prompt,
            promptText: "Help me say this naturally in the local language where I am. If my intent is unclear, ask one short clarification first. Then provide local phrase, pronunciation, and a polite variant. Use the translate tool."
        ),
    ]

    /// Built-in Field Assist quick action. Injected at the front of `Config.quickActions`
    /// whenever Field Assist is active (see `withFieldAssistAction`) — it is never persisted,
    /// so it appears/disappears with the entitlement. A `.prompt` action so it routes through
    /// the existing pipeline and the AI starts the session via the `field_session` tool.
    static let fieldAssist = QuickAction(
        id: "field-assist",
        label: "Field Assist",
        icon: "wrench.and.screwdriver.fill",
        type: .prompt,
        promptText: "Start a Field Assist session on my default vault. Briefly confirm you're ready and what you can help me troubleshoot."
    )

    /// Core speed-dial buttons (vision + specialist modes Claudio uses daily).
    /// Kept separate from travel/HA extras so migrations can re-inject them after a bundle reset.
    static let smartDial: [QuickAction] = [
        QuickAction(id: "describe", label: "Describe", icon: "eye", type: .photoThenPrompt,
                    promptText: "Look through the glasses. Name the scene and the main objects or readable text in front of the wearer. Two or three spoken sentences. If it is too close, dark, or blurry, say that first."),
        QuickAction(id: "travel-translate-sign-menu", label: "Translate Sign", icon: "text.viewfinder", type: .photoThenPrompt,
                    promptText: "Read all visible text in this image. First provide exact original text, then translate to English. If helpful, use the translate tool to improve accuracy. Keep response concise for glasses."),
        QuickAction(id: "identify-plant", label: "Plant ID", icon: "leaf", type: .photoThenPrompt,
                    promptText: "Identify this plant. Include common name, scientific name, whether it's edible or toxic, and any interesting facts. Keep it brief for spoken TTS."),
        QuickAction(id: "wine-sommelier", label: "Sommelier", icon: "wineglass", type: .photoThenPrompt,
                    promptText: "You are a wine sommelier. Read any wine label or menu in this image: producer, region, vintage, grape. Give tasting notes, food pairings, and a value judgment. Keep it to 3–5 spoken sentences — no markdown."),
        // Special-cased in AppState.executeQuickAction → activates Meeting Assistant persona + audio rec.
        QuickAction(id: "meeting-record", label: "Meeting Mode", icon: "person.3", type: .prompt,
                    promptText: "Activate meeting mode"),
        QuickAction(id: "record-audio", label: "Rec Audio", icon: "waveform", type: .prompt,
                    promptText: "Start audio-only recording with live transcription now. Confirm when recording is on. Stay quiet unless I ask to stop recording or for a summary."),
        QuickAction(id: "record-video", label: "Rec Video", icon: "record.circle", type: .prompt,
                    promptText: "Start video recording from the glasses camera now. Confirm when recording is on, and tell me how to stop it."),
    ]

    static let defaults: [QuickAction] = smartDial + [
        QuickAction(id: "calendar", label: "Event", icon: "calendar", type: .photoThenPrompt,
                    promptText: "Extract any event details from this image (dates, times, locations, names) and create a calendar entry summary."),
        QuickAction(id: "task", label: "Task", icon: "checklist", type: .photoThenPrompt,
                    promptText: "Extract any action items or tasks from this image and list them."),
        QuickAction(id: "lights-off", label: "Lights Off", icon: "lightbulb.slash", type: .homeAssistant,
                    haService: "light.turn_off", haEntityId: "all"),
    ] + travelTemplates
}
