import Foundation

/// Diarization settings, co-located with the feature. Cloud diarization sends raw audio to
/// Deepgram, so it is **off by default**, requires an explicit opt-in plus a key, and is
/// **hard-disabled under HIPAA mode** — clinical audio must never leave the device implicitly.
extension Config {
    /// Deepgram API key. Stored in the Keychain (see `KeychainService`), like the Anthropic key.
    static var deepgramAPIKey: String {
        if let key = KeychainService.string(for: "deepgramAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setDeepgramAPIKey(_ key: String) {
        KeychainService.setString(key, for: "deepgramAPIKey")
    }

    /// User opt-in for cloud diarization. Off by default (cloud egress of raw audio).
    /// When on + keyed, applies to **all** ambient listening — not only Meeting Mode
    /// (captions, recordings, summaries, and LLM room context).
    static var diarizationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "diarizationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationEnabled") }
    }

    /// When diarization is configured, auto-start ambient captions on glasses connect
    /// so general mode always hears the room with speaker labels (no extra toggle).
    static var diarizationAutoStartCaptions: Bool {
        get {
            if UserDefaults.standard.object(forKey: "diarizationAutoStartCaptions") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "diarizationAutoStartCaptions")
        }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationAutoStartCaptions") }
    }

    /// Deepgram model used for diarization. `nova-3` has the strongest diarization.
    static var diarizationModel: String {
        get { UserDefaults.standard.string(forKey: "diarizationModel") ?? "nova-3" }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationModel") }
    }

    /// True only when diarization is opted-in, keyed, and **not** suppressed by HIPAA mode.
    /// Every diarization path must gate on this — when false, callers fall back to the existing
    /// on-device `SFSpeechRecognizer` (single, unlabeled stream) so nothing regresses.
    static var isDiarizationConfigured: Bool {
        diarizationEnabled && !deepgramAPIKey.isEmpty && !hipaaMode
    }

    // MARK: - Deepgram endpoints

    /// Streaming WebSocket URL for live diarized transcription at the given input sample rate.
    static func deepgramStreamingURL(sampleRate: Int) -> URL? {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")
        components?.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "model", value: diarizationModel)
        ]
        return components?.url
    }

    /// Prerecorded/batch URL for diarizing a saved recording.
    static var deepgramBatchURL: URL? {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")
        components?.queryItems = [
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "model", value: diarizationModel)
        ]
        return components?.url
    }
}
