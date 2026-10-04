import Foundation

/// Typed client for the M4 Siri↔Fleet gateway.
///
/// Origin + bearer come from the saved Home Overseer MCP server (`Config.mcpServers`
/// in Keychain). The wire protocol is `/siri/v1/*` JSON, not MCP JSON-RPC — Siri
/// must return inside the normal App Intent window, so every call is a single
/// short POST. Destructive work is queued as a job; this type never waits for
/// completion.
struct FleetIntentGateway {
    var transport: FleetSiriTransport
    var source: FleetMCPServerSource
    var timeout: TimeInterval

    init(
        transport: FleetSiriTransport,
        source: FleetMCPServerSource,
        timeout: TimeInterval = FleetSiriLimits.requestTimeout
    ) {
        self.transport = transport
        self.source = source
        self.timeout = timeout
    }

    static func live(session: URLSession = .shared) -> FleetIntentGateway {
        FleetIntentGateway(
            transport: URLSessionFleetSiriTransport(session: session),
            source: LiveFleetMCPServerSource()
        )
    }

    func fleetStatus(envelope: FleetContextEnvelope) async throws -> FleetStatusResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/status", body: FleetStatusRequest(envelope: envelope))
    }

    func dailyBriefing(envelope: FleetContextEnvelope) async throws -> FleetBriefingResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/briefing", body: FleetBriefingRequest(envelope: envelope))
    }

    func remember(_ request: FleetRememberRequest) async throws -> FleetRememberResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/remember", body: request)
    }

    func findDeal(_ request: FleetFindDealRequest) async throws -> FleetFindDealResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/deals/find", body: request)
    }

    func startTask(_ request: FleetStartTaskRequest) async throws -> FleetStartTaskResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/tasks", body: request)
    }

    func taskStatus(_ request: FleetTaskStatusRequest) async throws -> FleetJobSnapshot {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/tasks/status", body: request)
    }

    func cancelTask(_ request: FleetCancelTaskRequest) async throws -> FleetJobSnapshot {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/tasks/cancel", body: request)
    }

    func explainAlert(_ request: FleetExplainAlertRequest) async throws -> FleetExplainAlertResponse {
        try await post(path: "\(FleetSiriSchema.pathPrefix)/alerts/explain", body: request)
    }

    func pendingApprovals(envelope: FleetContextEnvelope) async throws -> FleetPendingApprovalsResponse {
        try await post(
            path: "\(FleetSiriSchema.pathPrefix)/approvals/pending",
            body: FleetPendingApprovalsRequest(envelope: envelope)
        )
    }

    // MARK: - Transport

    func resolved() throws -> FleetResolvedGateway {
        switch FleetGatewayResolver.resolve(servers: source.loadServers()) {
        case .success(let gateway): return gateway
        case .failure(let error): throw error
        }
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        let gateway = try resolved()
        let data = try FleetSiriJSON.encode(body)
        let requestId = extractRequestId(from: data) ?? UUID().uuidString
        let request = try gateway.makeRequest(
            path: path,
            body: data,
            requestId: requestId,
            timeout: timeout
        )
        let (responseData, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw FleetGatewayError.from(httpStatus: http.statusCode)
        }
        do {
            return try FleetSiriJSON.decode(Response.self, from: responseData)
        } catch {
            throw FleetGatewayError.decodingFailed
        }
    }

    /// Pull `request_id` out of the already-encoded envelope so the HTTP header
    /// matches the body without re-reflecting Encodable.
    private func extractRequestId(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let id = object["request_id"] as? String { return id }
        if let envelope = object["envelope"] as? [String: Any], let id = envelope["request_id"] as? String {
            return id
        }
        return nil
    }
}
