import Foundation

/// Sanitized projections Siri can resolve as `AppEntity`s. No tokens, no email,
/// no message bodies — titles and short summaries only.
struct FleetEntitySnapshot: Codable, Equatable {
    var jobs: [FleetJobSnapshot]
    var alerts: [FleetAlert]
    var deals: [FleetDeal]
    var approvals: [FleetApproval]

    static let empty = FleetEntitySnapshot(jobs: [], alerts: [], deals: [], approvals: [])
}

protocol FleetSnapshotStore: AnyObject {
    func load() -> FleetEntitySnapshot
    func save(_ snapshot: FleetEntitySnapshot)
}

extension FleetSnapshotStore {
    func upsert(job: FleetJobSnapshot) {
        var snap = load()
        snap.jobs = Self.upsert(snap.jobs, Self.systemSnapshot(job), cap: FleetSiriLimits.snapshotCap)
        save(snap)
    }

    func upsert(alert: FleetAlert) {
        var snap = load()
        snap.alerts = Self.upsert(snap.alerts, Self.systemSnapshot(alert), cap: FleetSiriLimits.snapshotCap)
        save(snap)
    }

    func replaceJobs(_ jobs: [FleetJobSnapshot]) {
        var snap = load()
        snap.jobs = jobs.prefix(FleetSiriLimits.snapshotCap).map(Self.systemSnapshot)
        save(snap)
    }

    func replaceAlerts(_ alerts: [FleetAlert]) {
        var snap = load()
        snap.alerts = alerts.prefix(FleetSiriLimits.snapshotCap).map(Self.systemSnapshot)
        save(snap)
    }

    func replaceDeals(_ deals: [FleetDeal]) {
        var snap = load()
        snap.deals = deals.prefix(FleetSiriLimits.snapshotCap).map(Self.systemSnapshot)
        save(snap)
    }

    func replaceApprovals(_ approvals: [FleetApproval]) {
        var snap = load()
        snap.approvals = approvals.prefix(FleetSiriLimits.snapshotCap).map(Self.systemSnapshot)
        save(snap)
    }

    private static func systemSnapshot(_ job: FleetJobSnapshot) -> FleetJobSnapshot {
        var copy = job
        copy.title = copy.title.clipped(to: 120)
        copy.spokenSummary = copy.spokenSummary.clipped(to: FleetSiriLimits.spokenChars)
        copy.detail = nil
        return copy
    }

    private static func systemSnapshot(_ alert: FleetAlert) -> FleetAlert {
        var copy = alert
        copy.title = copy.title.clipped(to: 120)
        copy.summary = copy.summary.clipped(to: FleetSiriLimits.spokenChars)
        return copy
    }

    private static func systemSnapshot(_ deal: FleetDeal) -> FleetDeal {
        var copy = deal
        copy.title = copy.title.clipped(to: 120)
        copy.summary = copy.summary.clipped(to: FleetSiriLimits.spokenChars)
        copy.location = copy.location?.clipped(to: 80)
        return copy
    }

    private static func systemSnapshot(_ approval: FleetApproval) -> FleetApproval {
        var copy = approval
        copy.title = copy.title.clipped(to: 120)
        copy.summary = copy.summary.clipped(to: FleetSiriLimits.spokenChars)
        return copy
    }

    private static func upsert<T: Identifiable>(_ items: [T], _ item: T, cap: Int) -> [T] where T.ID == String {
        var next = items.filter { $0.id != item.id }
        next.insert(item, at: 0)
        if next.count > cap { next = Array(next.prefix(cap)) }
        return next
    }
}

final class InMemoryFleetSnapshotStore: FleetSnapshotStore {
    var snapshot: FleetEntitySnapshot = .empty
    func load() -> FleetEntitySnapshot { snapshot }
    func save(_ snapshot: FleetEntitySnapshot) { self.snapshot = snapshot }
}

/// App-group cache so App Intents, widgets and the foreground app resolve the
/// same sanitized entities without a network round-trip in an entity query.
final class UserDefaultsFleetSnapshotStore: FleetSnapshotStore {
    static let shared = UserDefaultsFleetSnapshotStore()
    static let key = "fleetSiri.snapshot.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SharedAppState.defaults) {
        self.defaults = defaults
    }

    func load() -> FleetEntitySnapshot {
        guard let data = defaults.data(forKey: Self.key) else { return .empty }
        return (try? FleetSiriJSON.decode(FleetEntitySnapshot.self, from: data)) ?? .empty
    }

    func save(_ snapshot: FleetEntitySnapshot) {
        guard let data = try? FleetSiriJSON.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
