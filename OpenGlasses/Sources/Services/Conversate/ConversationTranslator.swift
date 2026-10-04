import Foundation
import Translation

/// Translates ambient caption text for Conversate mode.
/// Primary: Apple Translation framework. Falls back to original text on failure.
@MainActor
final class ConversationTranslator {
    static let shared = ConversationTranslator()

    private init() {}

    func translate(_ text: String, from source: Locale = SpeechLocaleResolver.current) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let target = Config.conversateTargetLocale
        let sourceCode = source.language.languageCode?.identifier
        let targetCode = target.language.languageCode?.identifier
        guard let sourceCode, let targetCode, sourceCode != targetCode else { return trimmed }

        do {
            let session = TranslationSession(
                installedSource: source.language,
                target: target.language
            )
            let response = try await session.translate(trimmed)
            return response.targetText
        } catch {
            NSLog("[Conversate] Translation failed: %@", error.localizedDescription)
            return trimmed
        }
    }
}
