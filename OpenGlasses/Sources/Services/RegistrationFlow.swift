import Foundation

/// Pure policy for the Meta registration wait — the setup step that most often blocks users
/// (the DAT permission gate is *the* onboarding blocker).
///
/// `Wearables.startRegistration()` returns *before* the user has approved the app inside the Meta
/// AI companion app; `registrationState` only reaches the camera/mic-capable value once they do,
/// and that approval has been observed to take ~25 s. The old 10 s deadline gave up while the user
/// was still tapping through Meta AI, leaving a "connected but nothing works" state — and the
/// status shown was a raw internal state number, not something the user could act on.
///
/// A second trap: if the glasses were off during that first approval, the SDK can sit at a
/// non-zero registration state with **no device**. Later `startRegistration()` calls then no-op
/// and never reopen Meta, so Connect has to unregister first and always deep-link the companion.
enum RegistrationFlow {
    /// How long to keep polling for the Meta AI approval before giving up (still with guidance).
    static let approvalDeadlineSeconds: Int64 = 25
    /// `registrationState` raw value at which camera/mic capabilities become available.
    static let registeredStateRawValue = 3
    /// Meta View / Ray-Ban companion — `startRegistration()` should open this, but after a
    /// failed first flow it often does not, so Connect opens it explicitly.
    static let metaCompanionURLString = "fb-viewapp://"

    static func isRegistered(stateRaw: Int) -> Bool { stateRaw >= registeredStateRawValue }

    /// User-facing connection status — tells the user what to *do*, never an internal state number.
    static func status(stateRaw: Int) -> String {
        isRegistered(stateRaw: stateRaw)
            ? "Waiting for device…"
            : "Approve OpenGlasses in the Meta AI app to continue…"
    }

    /// First pairing started (or looks finished) but the glasses never appeared. Tapping Connect
    /// again has to unregister first, otherwise Meta never reopens the approval sheet.
    static func needsFreshMetaPairing(stateRaw: Int, hasDevice: Bool) -> Bool {
        !hasDevice && stateRaw > 0
    }

    static func retryHint(stateRaw: Int, hasDevice: Bool) -> String {
        if hasDevice { return "Connected" }
        if needsFreshMetaPairing(stateRaw: stateRaw, hasDevice: hasDevice) {
            return "Turn the glasses on, then tap Connect to open Meta AI again"
        }
        return "Turn the glasses on and tap Connect to approve OpenGlasses in Meta AI"
    }
}
