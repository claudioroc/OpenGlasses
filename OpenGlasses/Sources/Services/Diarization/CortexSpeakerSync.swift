import Foundation

/// Pushes named speakers to the glasses-router `/speaker` endpoint so they land in the
/// central cortex (`voice_profiles/speakers` + Qdrant memory).
///
/// Resolves the router base URL + Bearer token from the active OpenAI-compatible model
/// (the same Custom endpoint OpenGlasses already uses for chat).
enum CortexSpeakerSync {

    /// Fire-and-forget registration. Safe to call from the main actor; work runs off-main.
    static func push(name: String, speakerId: Int, context: String = "named via chip on glasses") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task.detached(priority: .utility) {
            await performPush(name: trimmed, speakerId: speakerId, context: context)
        }
    }

    private static func performPush(name: String, speakerId: Int, context: String) async {
        guard let (url, token) = resolveRouter() else {
            NSLog("[CortexSpeakerSync] no router baseURL/apiKey on active model — skip")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let body: [String: Any] = [
            "name": name,
            "id": speakerId,
            "context": context,
            "source": "glasses-chip",
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            if (200..<300).contains(code) {
                NSLog("[CortexSpeakerSync] registered %@: %d %@", name, code, String(snippet))
            } else {
                NSLog("[CortexSpeakerSync] failed %@: %d %@", name, code, String(snippet))
            }
        } catch {
            NSLog("[CortexSpeakerSync] error: %@", error.localizedDescription)
        }
    }

    /// Prefer the active model if it points at a local/custom router; otherwise first saved
    /// OpenAI-compatible model whose baseURL looks like a router (contains a port or local host).
    private static func resolveRouter() -> (URL, String)? {
        let candidates: [ModelConfig] = {
            var list: [ModelConfig] = []
            if let active = Config.activeModel { list.append(active) }
            list.append(contentsOf: Config.savedModels)
            return list
        }()

        for model in candidates {
            let base = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, !key.isEmpty else { continue }

            // Strip trailing /chat/completions if present
            var root = base
            if let range = root.range(of: "/chat/completions", options: [.backwards, .caseInsensitive]) {
                root = String(root[..<range.lowerBound])
            }
            while root.hasSuffix("/") { root.removeLast() }

            // Only push to endpoints that look like our bridge (local/tailscale/custom port),
            // not public OpenAI/xAI/Gemini hosts.
            let lower = root.lowercased()
            let isPublicCloud = lower.contains("api.openai.com")
                || lower.contains("api.x.ai")
                || lower.contains("generativelanguage.googleapis.com")
                || lower.contains("api.anthropic.com")
            if isPublicCloud { continue }

            guard let speakerURL = URL(string: root + "/speaker") else { continue }
            return (speakerURL, key)
        }
        return nil
    }
}
