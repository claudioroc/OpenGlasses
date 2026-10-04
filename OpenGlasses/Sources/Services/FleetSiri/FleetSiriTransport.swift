import Foundation

/// Injected URLSession seam. Production uses `URLSessionFleetSiriTransport`;
/// tests supply a fake that never opens a socket.
protocol FleetSiriTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionFleetSiriTransport: FleetSiriTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FleetGatewayError.timedOut
        } catch {
            throw FleetGatewayError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw FleetGatewayError.transportFailed
        }
        return (data, http)
    }
}
