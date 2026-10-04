import AppIntents
import XCTest
@testable import OpenGlasses

@MainActor
final class FleetSiriIntentTests: XCTestCase {
    private var transport: FakeFleetSiriTransport!
    private var store: InMemoryFleetSnapshotStore!

    override func setUp() {
        super.setUp()
        transport = FakeFleetSiriTransport()
        store = InMemoryFleetSnapshotStore()
        FleetSiriRuntime.gatewayOverride = FleetSiriFixtures.gateway(
            transport: transport,
            servers: [FleetSiriFixtures.overseer()]
        )
        FleetSiriRuntime.storeOverride = store
    }

    override func tearDown() {
        FleetSiriRuntime.resetOverrides()
        super.tearDown()
    }

    func testStatusWritesSnapshotAndClipsSpeech() async throws {
        let long = String(repeating: "Fleet is healthy. ", count: 40)
        transport.responseBody = FleetSiriFixtures.encodeJSON([
            "spoken_summary": long,
            "health": "degraded",
            "jobs": [[
                "id": "job-9",
                "title": "WAN check",
                "phase": "running",
                "domain": "os",
                "created_at": "2026-08-13T10:00:00Z",
                "updated_at": "2026-08-13T10:00:00Z",
                "spoken_summary": "WAN check is running.",
            ]],
            "alerts": [[
                "id": "alert-1",
                "title": "WAN2",
                "summary": "Backup WAN is down.",
                "severity": "warning",
            ]],
        ])
        let speech = try await FleetSiriActions.status()
        XCTAssertLessThanOrEqual(speech.count, FleetSiriLimits.spokenChars + 1)
        XCTAssertEqual(store.load().jobs.first?.id, "job-9")
        XCTAssertEqual(store.load().alerts.first?.id, "alert-1")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/siri/v1/status")
    }

    func testRememberRejectsEmptyAndSendsText() async throws {
        do {
            _ = try await FleetSiriActions.remember(text: "   ")
            XCTFail("expected invalidRequest")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .invalidRequest)
        }
        XCTAssertTrue(transport.requests.isEmpty)

        transport.responseBody = FleetSiriFixtures.encodeJSON([
            "accepted": true,
            "memory_id": "mem-1",
            "spoken_summary": "Saved.",
        ])
        let speech = try await FleetSiriActions.remember(text: "Lucas asked about Knight Frank")
        XCTAssertEqual(speech, "Saved.")
        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Lucas asked about Knight Frank")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/siri/v1/remember")
    }

    func testStartTaskPersistsJobForLaterStatus() async throws {
        let job = FleetSiriFixtures.job(id: "job-start", phase: .queued, title: "Refresh pipeline")
        transport.responseBody = try FleetSiriJSON.encode(
            FleetStartTaskResponse(spokenSummary: "Queued refresh pipeline.", job: job)
        )
        let speech = try await FleetSiriActions.startTask(
            title: "Refresh pipeline",
            details: nil,
            domain: .re
        )
        XCTAssertEqual(speech, "Queued refresh pipeline.")
        XCTAssertEqual(store.load().jobs.first?.id, "job-start")

        transport.reset()
        transport.responseBody = try FleetSiriJSON.encode(
            FleetJobSnapshot(
                id: "job-start",
                title: "Refresh pipeline",
                phase: .running,
                domain: .re,
                createdAt: FleetSiriFixtures.fixedDate,
                updatedAt: FleetSiriFixtures.fixedDate,
                spokenSummary: "Still running.",
                detail: nil
            )
        )
        let status = try await FleetSiriActions.taskStatus(jobId: "job-start")
        XCTAssertEqual(status, "Still running.")
        XCTAssertEqual(store.load().jobs.first?.phase, .running)
    }

    func testCancelSkipsNetworkWhenJobAlreadyTerminal() async {
        store.upsert(job: FleetSiriFixtures.job(id: "done-1", phase: .succeeded))
        do {
            _ = try await FleetSiriActions.cancelTask(jobId: "done-1")
            XCTFail("expected notCancellable")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .notCancellable)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSystemSnapshotStripsFullJobDetail() {
        var job = FleetSiriFixtures.job(id: "private-detail", phase: .succeeded)
        job.detail = String(repeating: "sensitive result ", count: 100)
        job.spokenSummary = String(repeating: "summary ", count: 100)

        store.upsert(job: job)

        let saved = store.load().jobs.first
        XCTAssertNil(saved?.detail)
        XCTAssertLessThanOrEqual(saved?.spokenSummary.count ?? .max, FleetSiriLimits.spokenChars + 1)
    }

    func testFindDealAndApprovalsUpdateStore() async throws {
        transport.responseBody = FleetSiriFixtures.encodeJSON([
            "spoken_summary": "One deal: 12 High Street.",
            "deals": [[
                "id": "deal-12",
                "title": "12 High Street",
                "summary": "Guide £400k.",
                "status": "live",
                "location": "N1",
            ]],
        ])
        _ = try await FleetSiriActions.findDeal(query: "High Street")
        XCTAssertEqual(store.load().deals.first?.id, "deal-12")

        transport.responseBody = FleetSiriFixtures.encodeJSON([
            "spoken_summary": "One approval waiting.",
            "approvals": [[
                "id": "ap-1",
                "title": "Restart qBit",
                "summary": "MC Director wants a container restart.",
                "target_agent": "mc",
                "action_type": "restart",
            ]],
        ])
        let speech = try await FleetSiriActions.pendingApprovals()
        XCTAssertEqual(speech, "One approval waiting.")
        XCTAssertEqual(store.load().approvals.first?.id, "ap-1")
    }

    func testIntentAuthAndBackgroundFlags() {
        XCTAssertEqual(FleetStatusIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(FleetDailyBriefingIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(FindFleetDealIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(FleetTaskStatusIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(RememberInCortexIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(StartFleetTaskIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(CancelFleetTaskIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(ExplainFleetAlertIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(PendingFleetApprovalsIntent.authenticationPolicy, .requiresAuthentication)

        XCTAssertFalse(FleetStatusIntent.openAppWhenRun)
        XCTAssertFalse(RememberInCortexIntent.openAppWhenRun)
        XCTAssertFalse(StartFleetTaskIntent.openAppWhenRun)
        XCTAssertFalse(CancelFleetTaskIntent.openAppWhenRun)
        XCTAssertFalse(PendingFleetApprovalsIntent.openAppWhenRun)
    }

    func testJobQueryResolvesUnknownIdWithoutNetwork() async throws {
        let query = FleetJobQuery()
        let entities = try await query.entities(for: ["ghost-id"])
        XCTAssertEqual(entities.first?.id, "ghost-id")
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
