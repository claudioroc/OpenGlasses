import XCTest
@testable import OpenGlasses

final class FleetIntentGatewayTests: XCTestCase {
    private var transport: FakeFleetSiriTransport!

    override func setUp() {
        super.setUp()
        transport = FakeFleetSiriTransport()
    }

    func testStatusPostsTypedPathWithAuthAndDoesNotNetworkOnEmptyConfig() async throws {
        let empty = FleetSiriFixtures.gateway(transport: transport, servers: [])
        do {
            _ = try await empty.fleetStatus(envelope: FleetContextEnvelope.siri())
            XCTFail("expected notConfigured")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .notConfigured)
        }
        XCTAssertTrue(transport.requests.isEmpty)

        transport.responseBody = FleetSiriFixtures.encodeJSON([
            "spoken_summary": "All green.",
            "health": "healthy",
            "jobs": [],
            "alerts": [],
        ])
        let gateway = FleetSiriFixtures.gateway(transport: transport, servers: [FleetSiriFixtures.overseer()])
        let envelope = FleetContextEnvelope.siri(spokenText: "fleet status", now: FleetSiriFixtures.fixedDate)
        let response = try await gateway.fleetStatus(envelope: envelope)

        XCTAssertEqual(response.spokenSummary, "All green.")
        XCTAssertEqual(response.health, .healthy)
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://bus.rochasilva.co.uk/siri/v1/status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), FleetSiriFixtures.bearer)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenGlasses-Client"), "openglasses-pre27")
        XCTAssertEqual(request.timeoutInterval, FleetSiriLimits.requestTimeout)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sentEnvelope = try XCTUnwrap(json["envelope"] as? [String: Any])
        XCTAssertEqual(sentEnvelope["source"] as? String, "siri")
        XCTAssertEqual(sentEnvelope["spoken_text"] as? String, "fleet status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-Id"), sentEnvelope["request_id"] as? String)
    }

    func testHTTPErrorsMapWithoutLeakingBodyOrToken() async {
        transport.statusCode = 401
        transport.responseBody = Data("token \(FleetSiriFixtures.secret) rejected".utf8)
        let gateway = FleetSiriFixtures.gateway(transport: transport, servers: [FleetSiriFixtures.overseer()])
        do {
            _ = try await gateway.dailyBriefing(envelope: FleetContextEnvelope.siri())
            XCTFail("expected unauthorized")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(
                FleetSiriRedaction.containsSecret(
                    error.localizedDescription,
                    secrets: [FleetSiriFixtures.secret, FleetSiriFixtures.bearer]
                )
            )
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStartTaskUsesTasksPathAndDecodesJob() async throws {
        let job = FleetSiriFixtures.job(id: "job-42", phase: .queued, title: "Scan pipeline")
        transport.responseBody = try FleetSiriJSON.encode(
            FleetStartTaskResponse(spokenSummary: "Queued scan pipeline.", job: job)
        )
        let gateway = FleetSiriFixtures.gateway(transport: transport, servers: [FleetSiriFixtures.overseer()])
        let response = try await gateway.startTask(
            FleetStartTaskRequest(
                envelope: FleetContextEnvelope.siri(spokenText: "scan pipeline"),
                title: "Scan pipeline",
                details: nil,
                domain: .re,
                idempotencyKey: "idem-1"
            )
        )
        XCTAssertEqual(response.job.id, "job-42")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/siri/v1/tasks")
        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["domain"] as? String, "re")
        XCTAssertEqual(json["idempotency_key"] as? String, "idem-1")
    }

    func testMalformedJSONIsDecodingFailedNotRawError() async {
        transport.responseBody = Data("not-json".utf8)
        let gateway = FleetSiriFixtures.gateway(transport: transport, servers: [FleetSiriFixtures.overseer()])
        do {
            _ = try await gateway.pendingApprovals(envelope: FleetContextEnvelope.siri())
            XCTFail("expected decodingFailed")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .decodingFailed)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTransportFailureDoesNotCallThroughAsSuccess() async {
        transport.error = .transportFailed
        let gateway = FleetSiriFixtures.gateway(transport: transport, servers: [FleetSiriFixtures.overseer()])
        do {
            _ = try await gateway.fleetStatus(envelope: FleetContextEnvelope.siri())
            XCTFail("expected transportFailed")
        } catch let error as FleetGatewayError {
            XCTAssertEqual(error, .transportFailed)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
