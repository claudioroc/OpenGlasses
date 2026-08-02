import Foundation

/// Generic HTTP agent harness (Plan N, Phase 2): drives any user-supplied endpoint described by a
/// `CustomHarnessConfig` — POST to start, GET to poll status, optional POST to cancel — mapping the
/// responses through `JSONPath`. Same opt-in spirit as a custom MCP server: supported, never
/// required, and entirely phone-only (we connect to a URL the user already runs).
///
/// The request building + response parsing live in `CustomHarnessConfig`/`JSONPath` (pure, tested);
/// this adapter is the thin async layer. `session` is injectable so tests exercise the HTTP shape
/// through a `URLProtocol` stub.
struct CustomAgentHarness: AgentHarness {
    let kind: AgentHarnessKind
    let config: CustomHarnessConfig
    var session: URLSession = .shared
    private let displayNameOverride: String?
    private let isConfiguredOverride: Bool?

    /// - Parameters:
    ///   - kind: the harness identity. Defaults to `.custom`; the Codex / Claude Code presets pass
    ///     `.codexCloud` / `.claudeRemote` so dispatched runs are tagged correctly.
    ///   - displayName / isConfigured: optional overrides for the preset-backed harnesses (whose
    ///     readiness is gated on a token, not just the start URL).
    init(kind: AgentHarnessKind = .custom,
         config: CustomHarnessConfig,
         displayName: String? = nil,
         isConfigured: Bool? = nil,
         session: URLSession = .shared) {
        self.kind = kind
        self.config = config
        self.displayNameOverride = displayName
        self.isConfiguredOverride = isConfigured
        self.session = session
    }

    var displayName: String {
        if let displayNameOverride { return displayNameOverride }
        return config.name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : config.name
    }
    var isConfigured: Bool { isConfiguredOverride ?? config.isConfigured }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        guard let request = config.startRequest(prompt: prompt, project: project) else {
            throw AgentHarnessError.notConfigured(kind)
        }
        let json = try await sendJSON(request)
        guard let id = JSONPath.string(at: config.idPath, in: json) else {
            throw AgentHarnessError.transport("Response had no run id at '\(config.idPath)'.")
        }
        let status = AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
        return AgentRun(id: id, harness: kind, prompt: prompt, project: project,
                        status: status, startedAt: Date())
    }

    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        guard let json = try await statusJSON(run) else { return .running }
        return parseStatus(json)
    }

    func cancel(_ run: AgentRun) async throws {
        guard let request = config.cancelRequest(runID: run.id) else {
            throw AgentHarnessError.unsupported("Cancel")
        }
        _ = try await sendJSON(request)
    }

    /// Status-poll event stream (no assumed push channel for an arbitrary endpoint). Emits
    /// `.started`, then polls until terminal and emits `.completed`/`.error`.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                while !Task.isCancelled {
                    guard let json = try? await self.statusJSON(run) else {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        continue
                    }

                    let status = self.parseStatus(json)
                    if status.isTerminal {
                        if status == .failed {
                            let message = JSONPath.string(at: self.config.errorPath, in: json)
                                ?? "The agent run failed."
                            continuation.yield(.error(message))
                        } else {
                            if let text = JSONPath.string(at: self.config.finalTextPath, in: json),
                               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                continuation.yield(.assistantText(text))
                            }
                            continuation.yield(.completed(AgentRunResult()))
                        }
                        break
                    }

                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP

    private func statusJSON(_ run: AgentRun) async throws -> [String: Any]? {
        guard let request = config.statusRequest(runID: run.id) else { return nil }
        return try await sendJSON(request)
    }

    private func parseStatus(_ json: [String: Any]) -> AgentRunStatus {
        AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
    }

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentHarnessError.transport("HTTP \(http.statusCode): \(String(body.prefix(160)))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
