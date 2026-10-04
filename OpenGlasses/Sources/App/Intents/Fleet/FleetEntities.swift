import AppIntents
import Foundation

extension FleetAgentDomain: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fleet Agent")

    static var caseDisplayRepresentations: [FleetAgentDomain: DisplayRepresentation] = [
        .overseer: "Overseer",
        .os: "OS",
        .re: "Real Estate",
        .pa: "Personal Assistant",
        .mc: "Media Center",
        .ha: "Home Assistant",
    ]
}

/// A fleet job Siri can name. Query is snapshot-only (no network) so entity
/// resolution stays inside the App Intent budget. Unknown ids still resolve so
/// a spoken job id can be sent to M4.
struct FleetJobEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fleet Job"
    static var defaultQuery = FleetJobQuery()

    let id: String
    let title: String
    let phaseName: String
    let summary: String

    init(id: String, title: String, phaseName: String, summary: String) {
        self.id = id
        self.title = title
        self.phaseName = phaseName
        self.summary = summary
    }

    init(_ job: FleetJobSnapshot) {
        self.init(id: job.id, title: job.title, phaseName: job.phase.displayName, summary: job.spokenSummary)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(phaseName)")
    }
}

struct FleetJobQuery: EntityStringQuery {
    func entities(for identifiers: [FleetJobEntity.ID]) async throws -> [FleetJobEntity] {
        let jobs = await FleetSiriRuntime.store().load().jobs
        return identifiers.map { id in
            if let job = jobs.first(where: { $0.id == id }) {
                return FleetJobEntity(job)
            }
            return FleetJobEntity(id: id, title: id, phaseName: "", summary: "")
        }
    }

    func suggestedEntities() async throws -> [FleetJobEntity] {
        await FleetSiriRuntime.store().load().jobs.prefix(10).map(FleetJobEntity.init)
    }

    func entities(matching string: String) async throws -> [FleetJobEntity] {
        let target = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        let jobs = await FleetSiriRuntime.store().load().jobs
        let hits = jobs.filter {
            $0.id.lowercased() == target
                || $0.title.lowercased().contains(target)
        }
        if hits.isEmpty {
            return [FleetJobEntity(id: string.trimmingCharacters(in: .whitespacesAndNewlines), title: string, phaseName: "", summary: "")]
        }
        return hits.map(FleetJobEntity.init)
    }
}

struct FleetAlertEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fleet Alert"
    static var defaultQuery = FleetAlertQuery()

    let id: String
    let title: String
    let summary: String
    let severityName: String

    init(id: String, title: String, summary: String, severityName: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.severityName = severityName
    }

    init(_ alert: FleetAlert) {
        self.init(id: alert.id, title: alert.title, summary: alert.summary, severityName: alert.severity.rawValue)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(severityName)")
    }
}

struct FleetAlertQuery: EntityStringQuery {
    func entities(for identifiers: [FleetAlertEntity.ID]) async throws -> [FleetAlertEntity] {
        let alerts = await FleetSiriRuntime.store().load().alerts
        return identifiers.map { id in
            if let alert = alerts.first(where: { $0.id == id }) {
                return FleetAlertEntity(alert)
            }
            return FleetAlertEntity(id: id, title: id, summary: "", severityName: "")
        }
    }

    func suggestedEntities() async throws -> [FleetAlertEntity] {
        await FleetSiriRuntime.store().load().alerts.prefix(10).map(FleetAlertEntity.init)
    }

    func entities(matching string: String) async throws -> [FleetAlertEntity] {
        let target = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        let alerts = await FleetSiriRuntime.store().load().alerts
        let hits = alerts.filter {
            $0.id.lowercased() == target
                || $0.title.lowercased().contains(target)
        }
        if hits.isEmpty {
            return [FleetAlertEntity(id: string.trimmingCharacters(in: .whitespacesAndNewlines), title: string, summary: "", severityName: "")]
        }
        return hits.map(FleetAlertEntity.init)
    }
}

struct FleetDealEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fleet Deal"
    static var defaultQuery = FleetDealQuery()

    let id: String
    let title: String
    let summary: String
    let status: String

    init(id: String, title: String, summary: String, status: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
    }

    init(_ deal: FleetDeal) {
        self.init(id: deal.id, title: deal.title, summary: deal.summary, status: deal.status ?? "")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(status)")
    }
}

struct FleetDealQuery: EntityStringQuery {
    func entities(for identifiers: [FleetDealEntity.ID]) async throws -> [FleetDealEntity] {
        let deals = await FleetSiriRuntime.store().load().deals
        return identifiers.map { id in
            if let deal = deals.first(where: { $0.id == id }) {
                return FleetDealEntity(deal)
            }
            return FleetDealEntity(id: id, title: id, summary: "", status: "")
        }
    }

    func suggestedEntities() async throws -> [FleetDealEntity] {
        await FleetSiriRuntime.store().load().deals.prefix(10).map(FleetDealEntity.init)
    }

    func entities(matching string: String) async throws -> [FleetDealEntity] {
        let target = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        let deals = await FleetSiriRuntime.store().load().deals
        let hits = deals.filter {
            $0.id.lowercased() == target
                || $0.title.lowercased().contains(target)
                || ($0.location?.lowercased().contains(target) ?? false)
        }
        if hits.isEmpty {
            return [FleetDealEntity(id: string.trimmingCharacters(in: .whitespacesAndNewlines), title: string, summary: "", status: "")]
        }
        return hits.map(FleetDealEntity.init)
    }
}
