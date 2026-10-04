import Foundation

/// Failures the Siri layer can speak. Descriptions are intentionally short and
/// never include URLs, header values, or response bodies — those can carry the
/// glasses MCP bearer.
enum FleetGatewayError: Error, Equatable {
    case notConfigured
    case disabled
    case missingCredential
    case invalidURL
    case invalidRequest
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case timedOut
    case decodingFailed
    case transportFailed
    case httpStatus(Int)
    case notCancellable
}

extension FleetGatewayError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Home Overseer isn’t set up. Add it in OpenGlasses Settings → MCP Servers."
        case .disabled:
            return "Home Overseer is turned off in MCP Servers."
        case .missingCredential:
            return "Home Overseer has no saved token."
        case .invalidURL:
            return "Home Overseer URL is invalid."
        case .invalidRequest:
            return "I need a bit more detail."
        case .unauthorized:
            return "Home Overseer rejected the saved token."
        case .forbidden:
            return "That fleet action isn’t allowed."
        case .notFound:
            return "I couldn’t find that."
        case .conflict:
            return "That job can’t change state right now."
        case .timedOut:
            return "The fleet didn’t answer in time."
        case .decodingFailed:
            return "The fleet reply wasn’t readable."
        case .transportFailed:
            return "I couldn’t reach Home Overseer."
        case .httpStatus:
            return "Home Overseer returned an error."
        case .notCancellable:
            return "That job has already finished."
        }
    }
}

enum FleetSiriRedaction {
    static let mask = "***"

    /// Header value safe to print. Keeps a `Bearer` prefix so logs show the scheme.
    static func headerValue(_ name: String, _ value: String) -> String {
        let key = name.lowercased()
        if key == "authorization", value.lowercased().hasPrefix("bearer ") {
            return "Bearer \(mask)"
        }
        if isSensitiveHeader(name) { return mask }
        return value
    }

    static func isSensitiveHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "authorization", "x-fleet-token", "x-api-key", "proxy-authorization":
            return true
        default:
            return false
        }
    }

    /// True when `text` contains any of the supplied secret values. Used by tests
    /// and by error construction to refuse leaking a token.
    static func containsSecret(_ text: String, secrets: [String]) -> Bool {
        secrets.contains { secret in
            !secret.isEmpty && text.contains(secret)
        }
    }
}

extension FleetGatewayError {
    static func from(httpStatus status: Int) -> FleetGatewayError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 408, 504: return .timedOut
        case 409: return .conflict
        default: return .httpStatus(status)
        }
    }
}
