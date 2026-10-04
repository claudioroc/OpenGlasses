import AppIntents
import Foundation

/// Process-wide seams for fleet intents. Tests replace `gatewayOverride` /
/// `storeOverride`; production reads Keychain MCP config and the local snapshot.
/// Never touches `AppStateProvider`.
@MainActor
enum FleetSiriRuntime {
    static var gatewayOverride: FleetIntentGateway?
    static var storeOverride: FleetSnapshotStore?

    static func gateway() -> FleetIntentGateway {
        gatewayOverride ?? .live()
    }

    static func store() -> FleetSnapshotStore {
        storeOverride ?? UserDefaultsFleetSnapshotStore.shared
    }

    /// Unit tests replace the gateway/store and should not start ActivityKit,
    /// notifications or WidgetKit side effects.
    static var publishesSystemSurfaces: Bool {
        gatewayOverride == nil && storeOverride == nil
    }

    static func resetOverrides() {
        gatewayOverride = nil
        storeOverride = nil
    }
}

enum FleetSiriSpeech {
    static func clipped(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.clipped(to: FleetSiriLimits.spokenChars)
    }
}

/// Testable actions the App Intents wrap. Each call is one short gateway POST
/// and a snapshot update — no long-running wait, no app scene required.
@MainActor
enum FleetSiriActions {
    static func status(spokenText: String? = nil) async throws -> String {
        let envelope = FleetContextEnvelope.siri(spokenText: spokenText)
        let response = try await FleetSiriRuntime.gateway().fleetStatus(envelope: envelope)
        let store = FleetSiriRuntime.store()
        store.replaceJobs(response.jobs)
        store.replaceAlerts(response.alerts)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didReceiveStatus(response)
        }
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func briefing(spokenText: String? = nil) async throws -> String {
        let envelope = FleetContextEnvelope.siri(spokenText: spokenText)
        let response = try await FleetSiriRuntime.gateway().dailyBriefing(envelope: envelope)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didReceiveBriefing(response)
        }
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func remember(text: String) async throws -> String {
        let trimmed = try Self.requireText(text, max: FleetSiriLimits.rememberText)
        let request = FleetRememberRequest(
            envelope: FleetContextEnvelope.siri(spokenText: trimmed),
            text: trimmed,
            confidence: nil
        )
        let response = try await FleetSiriRuntime.gateway().remember(request)
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func findDeal(query: String) async throws -> String {
        let trimmed = try Self.requireText(query, max: FleetSiriLimits.dealQuery)
        let request = FleetFindDealRequest(
            envelope: FleetContextEnvelope.siri(spokenText: trimmed),
            query: trimmed,
            limit: FleetSiriLimits.dealLimit
        )
        let response = try await FleetSiriRuntime.gateway().findDeal(request)
        FleetSiriRuntime.store().replaceDeals(response.deals)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didFindDeals()
        }
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func startTask(title: String, details: String?, domain: FleetAgentDomain) async throws -> String {
        let trimmedTitle = try Self.requireText(title, max: FleetSiriLimits.taskTitle)
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let trimmedDetails, trimmedDetails.count > FleetSiriLimits.taskDetails {
            throw FleetGatewayError.invalidRequest
        }
        let request = FleetStartTaskRequest(
            envelope: FleetContextEnvelope.siri(spokenText: trimmedTitle),
            title: trimmedTitle,
            details: trimmedDetails,
            domain: domain,
            idempotencyKey: UUID().uuidString
        )
        let response = try await FleetSiriRuntime.gateway().startTask(request)
        FleetSiriRuntime.store().upsert(job: response.job)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didStartJob(response.job)
        }
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func taskStatus(jobId: String) async throws -> String {
        let id = try Self.requireIdentifier(jobId)
        let request = FleetTaskStatusRequest(
            envelope: FleetContextEnvelope.siri(spokenText: id),
            jobId: id
        )
        let previous = FleetSiriRuntime.store().load().jobs.first(where: { $0.id == id })?.phase
        let job = try await FleetSiriRuntime.gateway().taskStatus(request)
        FleetSiriRuntime.store().upsert(job: job)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didUpdateJob(job, previousPhase: previous)
        }
        return FleetSiriSpeech.clipped(job.spokenSummary)
    }

    static func cancelTask(jobId: String) async throws -> String {
        let id = try Self.requireIdentifier(jobId)
        let snapshot = FleetSiriRuntime.store().load()
        if let existing = snapshot.jobs.first(where: { $0.id == id }), !existing.phase.isCancellable {
            throw FleetGatewayError.notCancellable
        }
        let request = FleetCancelTaskRequest(
            envelope: FleetContextEnvelope.siri(spokenText: id),
            jobId: id
        )
        let job = try await FleetSiriRuntime.gateway().cancelTask(request)
        FleetSiriRuntime.store().upsert(job: job)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didUpdateJob(job, previousPhase: snapshot.jobs.first(where: { $0.id == id })?.phase)
        }
        return FleetSiriSpeech.clipped(job.spokenSummary)
    }

    static func explainAlert(alertId: String) async throws -> String {
        let id = try Self.requireIdentifier(alertId)
        let request = FleetExplainAlertRequest(
            envelope: FleetContextEnvelope.siri(spokenText: id),
            alertId: id
        )
        let response = try await FleetSiriRuntime.gateway().explainAlert(request)
        FleetSiriRuntime.store().upsert(alert: response.alert)
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    static func pendingApprovals() async throws -> String {
        let envelope = FleetContextEnvelope.siri()
        let response = try await FleetSiriRuntime.gateway().pendingApprovals(envelope: envelope)
        FleetSiriRuntime.store().replaceApprovals(response.approvals)
        if FleetSiriRuntime.publishesSystemSurfaces {
            FleetSiriSurfaceCoordinator.didReceiveApprovals(response)
        }
        return FleetSiriSpeech.clipped(response.spokenSummary)
    }

    private static func requireText(_ raw: String, max: Int) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= max else { throw FleetGatewayError.invalidRequest }
        return trimmed
    }

    private static func requireIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { throw FleetGatewayError.invalidRequest }
        return trimmed
    }
}

extension FleetGatewayError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Something went wrong.")
    }
}
