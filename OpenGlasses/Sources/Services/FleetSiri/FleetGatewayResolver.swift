import Foundation

/// Saved MCP server fields the fleet resolver needs. Mapped from
/// `MCPServerConfig` at the live edge so the matcher stays independent of
/// egress/transport metadata and never writes Keychain itself.
struct FleetSavedServer: Equatable {
    var id: String
    var label: String
    var url: String
    var headers: [String: String]
    var enabled: Bool

    init(id: String, label: String, url: String, headers: [String: String], enabled: Bool) {
        self.id = id
        self.label = label
        self.url = url
        self.headers = headers
        self.enabled = enabled
    }

    init(_ server: MCPServerConfig) {
        self.init(
            id: server.id,
            label: server.label,
            url: server.url,
            headers: server.headers,
            enabled: server.enabled
        )
    }
}

protocol FleetMCPServerSource {
    func loadServers() -> [FleetSavedServer]
}

/// Reads the Keychain-backed `Config.mcpServers` blob. Token values stay inside
/// that blob; this type never logs them.
struct LiveFleetMCPServerSource: FleetMCPServerSource {
    func loadServers() -> [FleetSavedServer] {
        Config.mcpServers.map(FleetSavedServer.init)
    }
}

struct StaticFleetMCPServerSource: FleetMCPServerSource {
    var servers: [FleetSavedServer]
    func loadServers() -> [FleetSavedServer] { servers }
}

/// Resolved M4/Overseer origin + auth headers copied from the saved MCP config.
/// `CustomStringConvertible` is redacted on purpose.
struct FleetResolvedGateway: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let origin: URL
    let serverID: String
    let serverLabel: String
    let authHeaders: [String: String]

    var description: String {
        let names = authHeaders.keys.sorted().joined(separator: ",")
        return "FleetResolvedGateway(origin=\(origin.host ?? "?"), server=\(serverLabel), headers=[\(names)])"
    }

    var debugDescription: String { description }

    func url(forPath path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw FleetGatewayError.invalidURL }
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw FleetGatewayError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw FleetGatewayError.invalidURL }
        return url
    }

    func makeRequest(path: String, body: Data, requestId: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try url(forPath: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(FleetSiriSchema.clientName, forHTTPHeaderField: "X-OpenGlasses-Client")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        for (name, value) in authHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Picks the saved Home Overseer (M4) MCP server and derives the typed `/siri/v1`
/// origin from it. Does not invent tokens; missing credentials fail closed.
enum FleetGatewayResolver {
    static let catalogId = "m4-overseer"
    static let knownHosts: Set<String> = [
        "bus.rochasilva.co.uk",
        "glasses-router.rochasilva.co.uk",
        "m4-mcp.rochasilva.co.uk",
    ]

    private static let allowedAuthHeaders: Set<String> = [
        "authorization",
        "x-fleet-token",
        "x-api-key",
    ]

    static func resolve(servers: [FleetSavedServer]) -> Result<FleetResolvedGateway, FleetGatewayError> {
        let matches = servers.filter(isOverseerCandidate)
        guard let chosen = matches.first(where: { $0.enabled }) ?? matches.first else {
            return .failure(.notConfigured)
        }
        guard chosen.enabled else { return .failure(.disabled) }
        guard let origin = origin(from: chosen.url) else { return .failure(.invalidURL) }
        let headers = authHeaders(from: chosen.headers)
        guard !headers.isEmpty else { return .failure(.missingCredential) }
        return .success(FleetResolvedGateway(
            origin: origin,
            serverID: chosen.id,
            serverLabel: chosen.label,
            authHeaders: headers
        ))
    }

    static func isOverseerCandidate(_ server: FleetSavedServer) -> Bool {
        if let host = URL(string: server.url)?.host?.lowercased(), knownHosts.contains(host) {
            return true
        }
        let url = server.url.lowercased()
        if knownHosts.contains(where: { url.contains($0) }) { return true }
        let label = server.label.lowercased()
        if label.contains("overseer") { return true }
        if label.contains("m4") { return true }
        return false
    }

    /// Public fleet hosts are origin-only: their saved MCP URL may contain an
    /// unguessable MCP path which must never be reused as the typed Siri base.
    /// For a labelled LAN Overseer, drop only a conventional trailing `/mcp`.
    /// Userinfo/query/fragment are always discarded.
    static func origin(from serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if let host = components.host?.lowercased(), knownHosts.contains(host) {
            path = ""
        } else {
            while path.hasSuffix("/") { path.removeLast() }
            if path.lowercased().hasSuffix("/mcp") {
                path.removeLast(4)
            }
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func authHeaders(from headers: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (name, value) in headers {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, allowedAuthHeaders.contains(name.lowercased()) else { continue }
            kept[name] = trimmed
        }
        return kept
    }
}
