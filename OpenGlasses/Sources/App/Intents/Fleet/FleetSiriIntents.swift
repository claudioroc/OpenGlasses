import AppIntents
import Foundation

// PRE-iOS-27 Siri↔Fleet intents. All are discoverable in Shortcuts; the five
// highest-frequency intents are also promoted by `OpenGlassesShortcuts` within
// iOS's ten-shortcut cap. No AppStateProvider or iOS-27-only intent APIs.

// MARK: - Status

struct FleetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Fleet Status"
    static var description = IntentDescription("Ask Home Overseer for a short fleet status")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.status()
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Daily briefing (fleet — distinct from the on-device DailyBriefingIntent)

struct FleetDailyBriefingIntent: AppIntent {
    static var title: LocalizedStringResource = "Fleet Daily Briefing"
    static var description = IntentDescription("Hear the Overseer daily briefing")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.briefing()
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Remember

struct RememberInCortexIntent: AppIntent {
    static var title: LocalizedStringResource = "Remember in Cortex"
    static var description = IntentDescription("Save something to fleet Cortex memory")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Memory", requestValueDialog: "What should I remember?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.remember(text: text)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Find deal

struct FindFleetDealIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Fleet Deal"
    static var description = IntentDescription("Look up a property deal on the fleet pipeline")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Deal", requestValueDialog: "Which deal?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.findDeal(query: query)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Start task

struct StartFleetTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Fleet Task"
    static var description = IntentDescription("Queue a task on Home Overseer and return immediately")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Task", requestValueDialog: "What should the fleet do?")
    var title: String

    @Parameter(title: "Details")
    var details: String?

    @Parameter(title: "Agent", default: .overseer)
    var domain: FleetAgentDomain

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.startTask(title: title, details: details, domain: domain)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Task status

struct FleetTaskStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Fleet Task Status"
    static var description = IntentDescription("Check a queued fleet job")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Job", requestValueDialog: "Which fleet job?")
    var job: FleetJobEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.taskStatus(jobId: job.id)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Cancel task

struct CancelFleetTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Fleet Task"
    static var description = IntentDescription("Cancel a queued or running fleet job")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Job", requestValueDialog: "Which fleet job should I cancel?")
    var job: FleetJobEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.cancelTask(jobId: job.id)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Explain alert

struct ExplainFleetAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Explain Fleet Alert"
    static var description = IntentDescription("Explain a fleet alert in one or two sentences")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Alert", requestValueDialog: "Which alert?")
    var alert: FleetAlertEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.explainAlert(alertId: alert.id)
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}

// MARK: - Pending approvals

struct PendingFleetApprovalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Pending Fleet Approvals"
    static var description = IntentDescription("List fleet actions waiting for your approval")
    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let speech = try await FleetSiriActions.pendingApprovals()
        return .result(value: speech, dialog: IntentDialog(stringLiteral: speech))
    }
}
