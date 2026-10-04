import Foundation
@testable import OpenGlasses

/// In-memory transport. Never opens a socket.
final class FakeFleetSiriTransport: FleetSiriTransport {
    var statusCode: Int = 200
    var responseBody: Data = Data("{}".utf8)
    var error: FleetGatewayError?
    private(set) var requests: [URLRequest] = []

    var lastRequest: URLRequest? { requests.last }

    func reset() {
        statusCode = 200
        responseBody = Data("{}".utf8)
        error = nil
        requests.removeAll()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        let url = request.url ?? URL(string: "https://invalid.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseBody, response)
    }
}

enum FleetSiriFixtures {
    static let secret = "sk-test-fleet-secret-do-not-leak"
    static let bearer = "Bearer \(secret)"

    static func overseer(
        enabled: Bool = true,
        url: String = "https://bus.rochasilva.co.uk/mcp",
        headers: [String: String] = ["Authorization": bearer]
    ) -> FleetSavedServer {
        FleetSavedServer(
            id: "saved-overseer",
            label: "Home Overseer (M4)",
            url: url,
            headers: headers,
            enabled: enabled
        )
    }

    static func gateway(transport: FakeFleetSiriTransport, servers: [FleetSavedServer]) -> FleetIntentGateway {
        FleetIntentGateway(
            transport: transport,
            source: StaticFleetMCPServerSource(servers: servers)
        )
    }

    static func encodeJSON(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_787_000_000)

    static func job(
        id: String = "job-1",
        phase: FleetJobPhase = .queued,
        title: String = "Check WAN"
    ) -> FleetJobSnapshot {
        FleetJobSnapshot(
            id: id,
            title: title,
            phase: phase,
            domain: .os,
            createdAt: fixedDate,
            updatedAt: fixedDate,
            spokenSummary: "\(title) is \(phase.displayName).",
            detail: nil
        )
    }
}
