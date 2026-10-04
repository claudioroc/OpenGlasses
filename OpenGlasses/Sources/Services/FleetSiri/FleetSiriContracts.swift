import Foundation

/// Schema version for the typed Siri↔Fleet envelope. Bump when the M4 `/siri/v1`
/// contract changes in a breaking way.
enum FleetSiriSchema {
    static let version = 1
    static let pathPrefix = "/siri/v1"
    static let clientName = "openglasses-pre27"
    static let source = "siri"
}

/// Agent domains the pre-iOS-27 fleet intents may target. Matches the standing
/// Overseer roster (OS / RE / PA / MC / HA) plus the router itself.
enum FleetAgentDomain: String, Codable, CaseIterable, Equatable {
    case overseer
    case os
    case re
    case pa
    case mc
    case ha

    var displayName: String {
        switch self {
        case .overseer: return "Overseer"
        case .os: return "OS"
        case .re: return "Real Estate"
        case .pa: return "Personal Assistant"
        case .mc: return "Media Center"
        case .ha: return "Home Assistant"
        }
    }
}

/// Provenance sent with every typed request. Cortex / Overseer persist only what
/// this envelope plus the explicit payload contain — never inferred Siri history.
struct FleetContextEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var source: String
    var client: String
    var requestId: String
    var spokenText: String?
    var locale: String?
    var createdAt: Date

    static func siri(spokenText: String? = nil, locale: String? = Locale.current.identifier, now: Date = Date()) -> FleetContextEnvelope {
        FleetContextEnvelope(
            schemaVersion: FleetSiriSchema.version,
            source: FleetSiriSchema.source,
            client: FleetSiriSchema.clientName,
            requestId: UUID().uuidString,
            spokenText: spokenText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            locale: locale,
            createdAt: now
        )
    }
}

// MARK: - Status

struct FleetStatusRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
}

enum FleetHealth: String, Codable, Equatable {
    case healthy
    case degraded
    case down
}

struct FleetStatusResponse: Codable, Equatable {
    var spokenSummary: String
    var health: FleetHealth
    var jobs: [FleetJobSnapshot]
    var alerts: [FleetAlert]
}

// MARK: - Briefing

struct FleetBriefingRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
}

struct FleetBriefingSection: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
}

struct FleetBriefingResponse: Codable, Equatable {
    var spokenSummary: String
    var sections: [FleetBriefingSection]
}

// MARK: - Remember (Cortex)

struct FleetRememberRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var text: String
    var confidence: Double?
}

struct FleetRememberResponse: Codable, Equatable {
    var accepted: Bool
    var memoryId: String?
    var spokenSummary: String
}

// MARK: - Deals

struct FleetFindDealRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var query: String
    var limit: Int
}

struct FleetDeal: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var status: String?
    var location: String?
}

struct FleetFindDealResponse: Codable, Equatable {
    var spokenSummary: String
    var deals: [FleetDeal]
}

// MARK: - Tasks / jobs

struct FleetStartTaskRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var title: String
    var details: String?
    var domain: FleetAgentDomain
    var idempotencyKey: String?
}

struct FleetStartTaskResponse: Codable, Equatable {
    var spokenSummary: String
    var job: FleetJobSnapshot
}

struct FleetTaskStatusRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var jobId: String
}

struct FleetCancelTaskRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var jobId: String
}

// MARK: - Alerts

enum FleetAlertSeverity: String, Codable, Equatable {
    case info
    case warning
    case critical
}

struct FleetAlert: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var severity: FleetAlertSeverity
    var createdAt: Date?
}

struct FleetExplainAlertRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
    var alertId: String
}

struct FleetExplainAlertResponse: Codable, Equatable {
    var spokenSummary: String
    var alert: FleetAlert
}

// MARK: - Approvals

struct FleetApproval: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var targetAgent: String?
    var actionType: String?
}

struct FleetPendingApprovalsRequest: Codable, Equatable {
    var envelope: FleetContextEnvelope
}

struct FleetPendingApprovalsResponse: Codable, Equatable {
    var spokenSummary: String
    var approvals: [FleetApproval]
}

// MARK: - Input bounds

enum FleetSiriLimits {
    static let rememberText = 2_000
    static let taskTitle = 200
    static let taskDetails = 2_000
    static let dealQuery = 200
    static let dealLimit = 5
    static let spokenChars = 240
    static let snapshotCap = 20
    static let requestTimeout: TimeInterval = 8
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func clipped(to maxChars: Int) -> String {
        guard maxChars > 0, count > maxChars else { return self }
        let end = index(startIndex, offsetBy: maxChars)
        return String(self[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
