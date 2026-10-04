import XCTest
@testable import OpenGlasses

final class FleetSiriContractsTests: XCTestCase {
    func testEnvelopeRoundTripUsesSnakeCaseAndISO8601() throws {
        let envelope = FleetContextEnvelope(
            schemaVersion: 1,
            source: "siri",
            client: "openglasses-pre27",
            requestId: "req-1",
            spokenText: "status please",
            locale: "en-GB",
            createdAt: FleetSiriFixtures.fixedDate
        )
        let data = try FleetSiriJSON.encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["request_id"] as? String, "req-1")
        XCTAssertEqual(object["spoken_text"] as? String, "status please")
        XCTAssertNil(object["schemaVersion"])
        XCTAssertTrue((object["created_at"] as? String)?.contains("T") == true)

        let decoded = try FleetSiriJSON.decode(FleetContextEnvelope.self, from: data)
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.spokenText, "status please")
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, FleetSiriFixtures.fixedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDateDecoderAcceptsFractionalAndPlainISO8601() throws {
        let fractional = Data(#"{"schema_version":1,"source":"siri","client":"c","request_id":"r","created_at":"2026-08-13T10:00:00.250Z"}"#.utf8)
        let plain = Data(#"{"schema_version":1,"source":"siri","client":"c","request_id":"r","created_at":"2026-08-13T10:00:00Z"}"#.utf8)
        let a = try FleetSiriJSON.decode(FleetContextEnvelope.self, from: fractional)
        let b = try FleetSiriJSON.decode(FleetContextEnvelope.self, from: plain)
        XCTAssertEqual(a.requestId, "r")
        XCTAssertEqual(b.requestId, "r")
        let expected = try XCTUnwrap(FleetSiriJSON.date(from: "2026-08-13T10:00:00Z"))
        XCTAssertEqual(b.createdAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(a.createdAt.timeIntervalSince1970, expected.timeIntervalSince1970 + 0.250, accuracy: 0.001)
    }

    func testStatusResponseRoundTrip() throws {
        let response = FleetStatusResponse(
            spokenSummary: "Fleet is healthy.",
            health: .healthy,
            jobs: [FleetSiriFixtures.job()],
            alerts: [
                FleetAlert(id: "a1", title: "WAN2 down", summary: "Three is offline.", severity: .warning, createdAt: FleetSiriFixtures.fixedDate)
            ]
        )
        let decoded = try FleetSiriJSON.decode(FleetStatusResponse.self, from: try FleetSiriJSON.encode(response))
        XCTAssertEqual(decoded.health, .healthy)
        XCTAssertEqual(decoded.jobs.first?.id, "job-1")
        XCTAssertEqual(decoded.alerts.first?.severity, .warning)
    }

    func testStringClipAndNilIfEmpty() {
        XCTAssertNil("   ".nilIfEmpty)
        XCTAssertEqual("hello".clipped(to: 5), "hello")
        XCTAssertEqual("hello world".clipped(to: 5), "hello…")
    }

    func testErrorDescriptionsNeverEchoSecrets() {
        let secret = FleetSiriFixtures.secret
        for error in [
            FleetGatewayError.notConfigured,
            .missingCredential,
            .unauthorized,
            .httpStatus(500),
            .transportFailed,
            .decodingFailed,
        ] {
            let text = error.localizedDescription
            XCTAssertFalse(FleetSiriRedaction.containsSecret(text, secrets: [secret, FleetSiriFixtures.bearer]), text)
        }
    }

    func testRedactionMasksBearerAndFleetToken() {
        XCTAssertEqual(FleetSiriRedaction.headerValue("Authorization", FleetSiriFixtures.bearer), "Bearer ***")
        XCTAssertEqual(FleetSiriRedaction.headerValue("X-Fleet-Token", "abc"), "***")
        XCTAssertEqual(FleetSiriRedaction.headerValue("Accept", "application/json"), "application/json")
    }
}
