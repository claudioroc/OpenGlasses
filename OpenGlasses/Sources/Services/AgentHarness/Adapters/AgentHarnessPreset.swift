import Foundation

/// Pre-filled `CustomHarnessConfig`s for the first-class remote-agent backends (Plan N, Phase 3):
/// **OpenAI Codex (cloud)** and **Claude Code (remote)**. Each preset encodes that backend's auth
/// scheme, request field names, and response field mapping, so the user only supplies a token (and,
/// if their deployment differs, a base URL) instead of hand-wiring every field like the generic
/// Custom harness.
///
/// Pure + headless-testable. These placeholder contracts are not verified upstream deployments;
/// the optional base URL is only an override for users who operate a compatible endpoint. A power
/// user can instead wire an explicitly verified contract through the Custom harness.
enum AgentHarnessPreset {

    /// OpenAI Codex cloud agent. Token is sent as `Authorization: Bearer …`; a run is started by
    /// POSTing `{prompt, project}` and polled at `…/{id}`.
    static func codexCloud(token: String, baseURL: String? = nil) -> CustomHarnessConfig {
        let root = normalizedRoot(baseURL, default: "https://api.openai.com/v1/agents")
        var config = CustomHarnessConfig()
        config.name = AgentHarnessKind.codexCloud.displayName
        config.startURL = "\(root)/runs"
        config.statusURLTemplate = "\(root)/runs/{id}"
        config.cancelURLTemplate = "\(root)/runs/{id}/cancel"
        config.authHeader = "Authorization"
        config.authValue = token.isEmpty ? "" : "Bearer \(token)"
        config.promptField = "prompt"
        config.projectField = "project"
        config.idPath = "id"
        config.statusPath = "status"
        return config
    }

    /// Claude Code remote (routines/web). Token is sent as `x-api-key`; same start/poll shape.
    static func claudeRemote(token: String, baseURL: String? = nil) -> CustomHarnessConfig {
        let root = normalizedRoot(baseURL, default: "https://api.anthropic.com/v1/code")
        var config = CustomHarnessConfig()
        config.name = AgentHarnessKind.claudeRemote.displayName
        config.startURL = "\(root)/sessions"
        config.statusURLTemplate = "\(root)/sessions/{id}"
        config.cancelURLTemplate = "\(root)/sessions/{id}/cancel"
        config.authHeader = "x-api-key"
        config.authValue = token
        config.promptField = "prompt"
        config.projectField = "project"
        config.idPath = "id"
        config.statusPath = "status"
        return config
    }

    /// The config for a preset kind, or `nil` for kinds that aren't preset-backed.
    static func config(for kind: AgentHarnessKind, token: String, baseURL: String?) -> CustomHarnessConfig? {
        switch kind {
        case .codexCloud:   return codexCloud(token: token, baseURL: baseURL)
        case .claudeRemote: return claudeRemote(token: token, baseURL: baseURL)
        case .openclaw, .custom: return nil
        }
    }

    /// Trim trailing slashes off a user-supplied base URL, falling back to the default when blank.
    private static func normalizedRoot(_ baseURL: String?, default fallback: String) -> String {
        let trimmed = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty ? fallback : trimmed
        return chosen.hasSuffix("/") ? String(chosen.dropLast()) : chosen
    }
}
