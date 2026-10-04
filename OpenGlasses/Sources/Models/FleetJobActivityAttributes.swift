import ActivityKit
import Foundation

/// Privacy-bounded job projection for Lock Screen and Dynamic Island. Full job
/// details and fleet credentials never enter ActivityKit state.
struct FleetJobActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var summary: String
        var updatedAt: Date
    }

    var jobId: String
    var title: String
    var domain: String
}
