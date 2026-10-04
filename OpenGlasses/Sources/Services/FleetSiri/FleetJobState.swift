import Foundation

/// Stable job phases for the pre-iOS-27 fleet. Terminal states are `succeeded`,
/// `failed`, and `cancelled`. `awaitingApproval` is the stand-in for work the
/// M4 policy gate will not run unattended — there is no `LongRunningIntent`.
enum FleetJobPhase: String, Codable, CaseIterable, Equatable {
    case queued
    case running
    case awaitingApproval
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .running, .awaitingApproval: return false
        }
    }

    var isCancellable: Bool { !isTerminal }

    var displayName: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .awaitingApproval: return "waiting for approval"
        case .succeeded: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// Sanitized, speakable snapshot of a fleet job. Identifiers are stable strings
/// issued by M4; the client never invents a new id after start returns.
struct FleetJobSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var phase: FleetJobPhase
    var domain: FleetAgentDomain
    var createdAt: Date
    var updatedAt: Date
    var spokenSummary: String
    var detail: String?
}

enum FleetJobTransitionError: Error, Equatable {
    case illegal(from: FleetJobPhase, to: FleetJobPhase)
}

/// Pure transition table. The gateway treats M4 as source of truth; this exists
/// so the client can reject locally-observed illegal hops and unit-test the
/// model without the network.
enum FleetJobTransition {
    static func allowedMoves(from phase: FleetJobPhase) -> Set<FleetJobPhase> {
        switch phase {
        case .queued:
            return [.running, .cancelled, .failed]
        case .running:
            return [.succeeded, .failed, .cancelled, .awaitingApproval]
        case .awaitingApproval:
            return [.running, .cancelled, .failed]
        case .succeeded, .failed, .cancelled:
            return []
        }
    }

    static func canMove(from: FleetJobPhase, to: FleetJobPhase) -> Bool {
        from == to || allowedMoves(from: from).contains(to)
    }

    static func apply(
        _ job: FleetJobSnapshot,
        to phase: FleetJobPhase,
        at date: Date = Date(),
        spokenSummary: String? = nil,
        detail: String? = nil
    ) throws -> FleetJobSnapshot {
        guard canMove(from: job.phase, to: phase) else {
            throw FleetJobTransitionError.illegal(from: job.phase, to: phase)
        }
        var next = job
        next.phase = phase
        next.updatedAt = date
        if let spokenSummary { next.spokenSummary = spokenSummary }
        if let detail { next.detail = detail }
        return next
    }
}
