import Foundation

/// Publishes only the sanitized fleet snapshot to iOS system surfaces.
@MainActor
enum FleetSiriSurfaceCoordinator {
    static func didReceiveStatus(_ response: FleetStatusResponse) {
        let lastJob = response.jobs.max(by: { $0.updatedAt < $1.updatedAt })
        var state = SharedAppState.fleetWidgetState
        state.health = response.health.rawValue
        state.spokenSummary = FleetSiriSpeech.clipped(response.spokenSummary)
        state.activeJobs = response.jobs.filter { !$0.phase.isTerminal }.count
        state.lastJobTitle = lastJob?.title
        state.lastJobPhase = lastJob?.phase.displayName
        state.updatedAt = Date()
        SharedAppState.fleetWidgetState = state

        for job in response.jobs {
            FleetJobActivityManager.shared.synchronize(job)
        }
        SpotlightIndexService.shared.requestRefresh()
    }

    static func didReceiveBriefing(_ response: FleetBriefingResponse) {
        var state = SharedAppState.fleetWidgetState
        state.spokenSummary = FleetSiriSpeech.clipped(response.spokenSummary)
        state.updatedAt = Date()
        SharedAppState.fleetWidgetState = state
    }

    static func didUpdateJob(_ job: FleetJobSnapshot, previousPhase: FleetJobPhase?) {
        var state = SharedAppState.fleetWidgetState
        state.lastJobTitle = job.title
        state.lastJobPhase = job.phase.displayName
        state.spokenSummary = FleetSiriSpeech.clipped(job.spokenSummary)
        let jobs = UserDefaultsFleetSnapshotStore.shared.load().jobs
        state.activeJobs = jobs.filter { !$0.phase.isTerminal }.count
        state.updatedAt = Date()
        SharedAppState.fleetWidgetState = state

        FleetJobActivityManager.shared.synchronize(job)
        Task { await FleetNotificationCoordinator.notifyTransition(job: job, previousPhase: previousPhase) }
        SpotlightIndexService.shared.requestRefresh()
    }

    static func didStartJob(_ job: FleetJobSnapshot) {
        didUpdateJob(job, previousPhase: nil)
        FleetJobPoller.shared.monitor(jobId: job.id)
        Task { await FleetNotificationCoordinator.prepareAuthorization() }
    }

    static func didFindDeals() {
        SpotlightIndexService.shared.requestRefresh()
    }

    static func didReceiveApprovals(_ response: FleetPendingApprovalsResponse) {
        var state = SharedAppState.fleetWidgetState
        state.pendingApprovals = response.approvals.count
        state.updatedAt = Date()
        SharedAppState.fleetWidgetState = state
    }
}
