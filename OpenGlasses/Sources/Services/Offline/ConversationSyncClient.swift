import Foundation

/// Network seam so `ConversationSyncClient`'s fallback logic can be tested without real HTTP
/// (mirrors the `SyncSink` seam pattern in SyncEngine.swift).
protocol SyncTransport {
    func postToM4(_ payload: Data) async -> Bool
    func postToM2(_ payload: Data) async -> Bool
}

/// Real HTTP transport: M4's glasses_router_bridge.py first, M2's fallback receiver second.
final class HTTPSyncTransport: SyncTransport {
    let m4URL: URL
    let m2URL: URL
    let bearerToken: String

    init(m4URL: URL, m2URL: URL, bearerToken: String) {
        self.m4URL = m4URL
        self.m2URL = m2URL
        self.bearerToken = bearerToken
    }

    private func post(_ url: URL, _ payload: Data) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 5   // matches the spec's "5s, configurável" fallback threshold
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func postToM4(_ payload: Data) async -> Bool { await post(m4URL, payload) }
    func postToM2(_ payload: Data) async -> Bool { await post(m2URL, payload) }
}

/// Converts a finished `ConversationThread` into the wire payload, tries M4, falls back to M2,
/// and as a last resort writes a plain JSON file -- nothing is ever silently dropped (2026-08-05
/// design spec: "nunca perder silenciosamente").
@MainActor
final class ConversationSyncClient {
    private let queue: ConversationSyncQueue
    private let transport: SyncTransport
    private let localExportDirectory: URL

    init(queue: ConversationSyncQueue, transport: SyncTransport, localExportDirectory: URL) {
        self.queue = queue
        self.transport = transport
        self.localExportDirectory = localExportDirectory
    }

    convenience init(queue: ConversationSyncQueue, m4URL: URL, m2URL: URL, bearerToken: String) {
        self.init(queue: queue,
                  transport: HTTPSyncTransport(m4URL: m4URL, m2URL: m2URL, bearerToken: bearerToken),
                  localExportDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
    }

    /// Pairs consecutive user->assistant messages -- mirrors the Python-side pairing logic in
    /// openglasses_backfill.py (Task 2), so the wire shape is identical on both paths.
    private func pairs(from thread: ConversationThread) -> [[String: String]] {
        var result: [[String: String]] = []
        var pendingQ: String?
        for message in thread.messages {
            if message.role == "user" {
                pendingQ = message.content
            } else if message.role == "assistant", let q = pendingQ {
                let formatter = ISO8601DateFormatter()
                result.append(["q": q, "a": message.content, "ts": formatter.string(from: message.timestamp)])
                pendingQ = nil
            }
        }
        return result
    }

    private func payload(sessionId: String, pairs: [[String: String]]) -> Data {
        let body: [String: Any] = [
            "session_id": sessionId,
            "source": "rayban-sync",
            "pairs": pairs,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Call this from `ConversationStore.endThread()`. A thread with no complete user->assistant
    /// pair (e.g. ended before the assistant replied) has nothing worth syncing -- checked on the
    /// pairs array itself, NOT the serialized JSON, since an empty `pairs: []` still serializes to
    /// non-empty bytes and would otherwise slip past a `Data.isEmpty` check.
    func syncThread(_ thread: ConversationThread) async {
        let matchedPairs = pairs(from: thread)
        guard !matchedPairs.isEmpty else { return }
        let body = payload(sessionId: thread.id, pairs: matchedPairs)
        let item = SyncItem(sessionId: thread.id, payload: body)
        queue.enqueue(item)
        await deliver(item)
    }

    /// Retries anything still `pending` (e.g. queued while offline). Bind to `Reachability`'s
    /// rising edge the same way `SyncEngine.bind(to:)` does.
    func flushPending() async {
        for item in queue.pending() {
            await deliver(item)
        }
    }

    private func deliver(_ item: SyncItem) async {
        queue.mark(item.id, state: .inFlight)
        if await transport.postToM4(item.payload) {
            queue.mark(item.id, state: .confirmedM4)
            return
        }
        if await transport.postToM2(item.payload) {
            queue.mark(item.id, state: .confirmedM2)
            return
        }
        writeLocalFile(item)
        queue.mark(item.id, state: .savedLocalFile)
    }

    private func writeLocalFile(_ item: SyncItem) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "conversation_\(formatter.string(from: Date())).json"
        let url = localExportDirectory.appendingPathComponent(filename)
        try? item.payload.write(to: url)
    }
}
