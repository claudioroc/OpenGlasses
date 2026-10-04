import Foundation
import AVFoundation

/// Speaks Conversate translations through the glasses route with hard mic mute (R1).
@MainActor
final class ConversateReadbackService: NSObject, ObservableObject {
    static let shared = ConversateReadbackService()

    @Published private(set) var isSpeaking = false

    weak var wakeWordService: WakeWordService?

    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Never>?
    private var queue: [String] = []
    private var draining = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Config.conversateReadbackEnabled else { return }
        queue.append(trimmed)
        Task { await drain() }
    }

    func stop() {
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        finishSpeak()
        wakeWordService?.resumeHotwordDetection()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await speak(next)
            // Tail guard against speaker→mic bleed.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func speak(_ text: String) async {
        wakeWordService?.pauseHotwordDetection()
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Config.conversateTargetLocaleIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            speakContinuation = cont
            synthesizer.speak(utterance)
        }
        isSpeaking = false
        wakeWordService?.resumeHotwordDetection()
    }

    private func finishSpeak() {
        speakContinuation?.resume()
        speakContinuation = nil
        isSpeaking = false
    }
}

extension ConversateReadbackService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeak() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeak() }
    }
}
