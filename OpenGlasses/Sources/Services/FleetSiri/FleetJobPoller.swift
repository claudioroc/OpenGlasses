import Foundation

/// Best-effort pre-APNs completion bridge. While the App Intent process remains
/// alive, active jobs are refreshed in the background without holding Siri open.
/// ActivityKit push can replace this monitor once APNs credentials are available.
@MainActor
final class FleetJobPoller {
    static let shared = FleetJobPoller()

    private var monitors: [String: Task<Void, Never>] = [:]

    private init() {}

    func monitor(jobId: String) {
        guard monitors[jobId] == nil else { return }
        monitors[jobId] = Task { [weak self] in
            defer { self?.monitors.removeValue(forKey: jobId) }
            for _ in 0..<40 {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let store = FleetSiriRuntime.store()
                let previous = store.load().jobs.first(where: { $0.id == jobId })?.phase
                do {
                    let request = FleetTaskStatusRequest(
                        envelope: FleetContextEnvelope.siri(spokenText: jobId),
                        jobId: jobId
                    )
                    let job = try await FleetSiriRuntime.gateway().taskStatus(request)
                    store.upsert(job: job)
                    FleetSiriSurfaceCoordinator.didUpdateJob(job, previousPhase: previous)
                    if job.phase.isTerminal || job.phase == .awaitingApproval { return }
                } catch {
                    // Transient failures do not kill the monitor; the normal Siri
                    // status intent remains the source-of-truth fallback.
                    continue
                }
            }
        }
    }

    func stop(jobId: String) {
        monitors.removeValue(forKey: jobId)?.cancel()
    }
}
