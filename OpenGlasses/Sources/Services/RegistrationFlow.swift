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
/// non-zero registration state with **no device**. Later `startRegistration()` calls then no-op.
/// Connect must unregister first so DAT can deep-link the **authorization sheet** again.
///
/// Do **not** open `fb-viewapp://` yourself. That launches Meta AI's home screen and replaces
/// the DAT approval URL, so the user sees the app with no confirmation — unlike onboarding.
enum RegistrationFlow {
    /// How long to keep polling for the Meta AI approval before giving up (still with guidance).
    static let approvalDeadlineSeconds: Int64 = 25
    /// `registrationState` raw value at which camera/mic capabilities become available.
    static let registeredStateRawValue = 3

    static func isRegistered(stateRaw: Int) -> Bool { stateRaw >= registeredStateRawValue }

    /// User-facing connection status — tells the user what to *do*, never an internal state number.
    static func status(stateRaw: Int) -> String {
        isRegistered(stateRaw: stateRaw)
            ? "Waiting for device…"
            : "Approve OpenGlasses in the Meta AI app to continue…"
    }

    /// Explicit Connect always starts a fresh DAT session so Meta shows the authorization request
    /// the same way onboarding does. A leftover non-zero state is enough to skip the sheet.
    static func needsFreshMetaPairing(stateRaw: Int, hasDevice: Bool) -> Bool {
        stateRaw > 0 || hasDevice
    }

    static func retryHint(stateRaw: Int, hasDevice: Bool) -> String {
        if hasDevice { return "Connected" }
        return "Approve OpenGlasses in the Meta AI app, then return here"
    }
}
