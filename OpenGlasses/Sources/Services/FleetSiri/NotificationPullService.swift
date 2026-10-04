import Foundation

/// Pulls queued glasses notifications from the M4 glasses-router.
/// The phone reaches M4 even when M4 cannot push into iOS NAT/Tailscale-offline.
@MainActor
final class NotificationPullService {
    static let shared = NotificationPullService()

    private var task: Task<Void, Never>?
    private var lastIds: Set<String> = []

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pullOnce()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        NSLog("[NotifPull] started")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func pullOnce() async {
        guard let (url, token) = Self.resolvePendingURL() else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["notifications"] as? [[String: Any]] else { return }
            for item in items {
                let key = (item["dedup_key"] as? String) ?? UUID().uuidString
                if lastIds.contains(key) { continue }
                lastIds.insert(key)
                let title = (item["title"] as? String) ?? "Alert"
                let body = (item["body"] as? String) ?? ""
                let level = (item["level"] as? String) ?? "important"
                let text = body.isEmpty ? title : "\(title). \(body)"
                MCPGlassesServer.shared.deliverPulledNotification(text: text, level: level)
            }
            if lastIds.count > 40 { lastIds = Set(lastIds.suffix(20)) }
        } catch {
            NSLog("[NotifPull] %@", error.localizedDescription)
        }
    }

    static func resolvePendingURL() -> (URL, String)? {
        let models: [ModelConfig] = {
            var list: [ModelConfig] = []
            if let active = Config.activeModel { list.append(active) }
            list.append(contentsOf: Config.savedModels)
            return list
        }()
        for model in models {
            let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            var root = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !root.isEmpty else { continue }
            if let range = root.range(of: "/chat/completions", options: [.backwards, .caseInsensitive]) {
                root = String(root[..<range.lowerBound])
            }
            if let range = root.range(of: "/v1", options: [.backwards, .caseInsensitive]) {
                root = String(root[..<range.lowerBound])
            }
            while root.hasSuffix("/") { root.removeLast() }
            let lower = root.lowercased()
            guard lower.contains("3459") || lower.contains("glasses-router") || lower.contains("192.168.10.135") else {
                continue
            }
            if let url = URL(string: root + "/v1/notifications/pending") {
                return (url, key)
            }
        }
        // Hard fallback used by conversation sync.
        if let url = URL(string: "http://192.168.10.135:3459/v1/notifications/pending"),
           let key = Config.savedModels.first(where: { $0.llmProvider == .custom })?.apiKey,
           !key.isEmpty {
            return (url, key)
        }
        return nil
    }
}
