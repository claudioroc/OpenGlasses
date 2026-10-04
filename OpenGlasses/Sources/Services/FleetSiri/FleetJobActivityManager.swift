import ActivityKit
import Foundation

/// Keeps one local Live Activity per active fleet job. Server-driven ActivityKit
/// push is intentionally not enabled until an APNs key is installed; Siri/status
/// refreshes still update and finish the activity immediately.
@MainActor
final class FleetJobActivityManager {
    static let shared = FleetJobActivityManager()

    private init() {}

    func synchronize(_ job: FleetJobSnapshot) {
        let state = contentState(for: job)
        if let activity = Activity<FleetJobActivityAttributes>.activities.first(where: {
            $0.attributes.jobId == job.id
        }) {
            Task {
                if job.phase.isTerminal {
                    await activity.end(
                        .init(state: state, staleDate: nil),
                        dismissalPolicy: .after(Date().addingTimeInterval(60 * 60))
                    )
                } else {
                    await activity.update(.init(state: state, staleDate: staleDate(for: job)))
                }
            }
            return
        }

        guard !job.phase.isTerminal, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = FleetJobActivityAttributes(
            jobId: job.id,
            title: String(job.title.prefix(80)),
            domain: job.domain.displayName
        )
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: staleDate(for: job)),
                pushType: nil
            )
        } catch {
            NSLog("[FleetLiveActivity] start failed: %@", error.localizedDescription)
        }
    }

    private func contentState(for job: FleetJobSnapshot) -> FleetJobActivityAttributes.ContentState {
        FleetJobActivityAttributes.ContentState(
            phase: job.phase.rawValue,
            summary: String(job.spokenSummary.prefix(160)),
            updatedAt: job.updatedAt
        )
    }

    private func staleDate(for job: FleetJobSnapshot) -> Date {
        max(job.updatedAt, Date()).addingTimeInterval(15 * 60)
    }
}
