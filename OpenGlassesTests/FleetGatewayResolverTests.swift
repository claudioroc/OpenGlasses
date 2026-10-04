import XCTest
@testable import OpenGlasses

final class FleetGatewayResolverTests: XCTestCase {
    func testResolvesCatalogHostAndStripsMCPPath() throws {
        let result = try FleetGatewayResolver.resolve(servers: [FleetSiriFixtures.overseer()]).get()
        XCTAssertEqual(result.origin.absoluteString, "https://bus.rochasilva.co.uk")
        XCTAssertEqual(result.serverLabel, "Home Overseer (M4)")
        XCTAssertEqual(try result.url(forPath: "/siri/v1/status").absoluteString, "https://bus.rochasilva.co.uk/siri/v1/status")
    }

    func testResolvesLegacyM4MCPHost() throws {
        let server = FleetSiriFixtures.overseer(url: "https://m4-mcp.rochasilva.co.uk/mcp/")
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.origin.host, "m4-mcp.rochasilva.co.uk")
        XCTAssertEqual(result.origin.path, "")
    }

    func testPublicHostDropsSecretMCPPath() throws {
        let server = FleetSiriFixtures.overseer(
            url: "https://bus.rochasilva.co.uk/mcp-private-route-that-must-not-leak"
        )
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.origin.absoluteString, "https://bus.rochasilva.co.uk")
        XCTAssertEqual(
            try result.url(forPath: "/siri/v1/status").absoluteString,
            "https://bus.rochasilva.co.uk/siri/v1/status"
        )
    }

    func testResolvesDedicatedGlassesRouterHost() throws {
        let server = FleetSiriFixtures.overseer(
            url: "https://glasses-router.rochasilva.co.uk/anything"
        )
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.origin.absoluteString, "https://glasses-router.rochasilva.co.uk")
    }

    func testResolvesLANHostByLabelAndKeepsPort() throws {
        let server = FleetSavedServer(
            id: "lan",
            label: "M4 Overseer",
            url: "http://192.168.10.135:3001/mcp",
            headers: ["Authorization": FleetSiriFixtures.bearer],
            enabled: true
        )
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.origin.absoluteString, "http://192.168.10.135:3001")
    }

    func testIgnoresUnrelatedServers() {
        let slack = FleetSavedServer(
            id: "slack",
            label: "Slack",
            url: "https://example.test/mcp",
            headers: ["Authorization": "Bearer x"],
            enabled: true
        )
        let result = FleetGatewayResolver.resolve(servers: [slack])
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .notConfigured)
    }

    func testDisabledOverseerFailsClosed() {
        let result = FleetGatewayResolver.resolve(servers: [FleetSiriFixtures.overseer(enabled: false)])
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .disabled)
    }

    func testMissingAuthFailsClosed() {
        let result = FleetGatewayResolver.resolve(servers: [
            FleetSiriFixtures.overseer(headers: ["X-Debug": "1"])
        ])
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .missingCredential)
    }

    func testStripsUserinfoAndQueryFromOrigin() throws {
        let server = FleetSiriFixtures.overseer(url: "https://user:supersecret@bus.rochasilva.co.uk/mcp?token=supersecret")
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.origin.absoluteString, "https://bus.rochasilva.co.uk")
        XCTAssertFalse(result.origin.absoluteString.contains("supersecret"))
        XCTAssertFalse(result.description.contains("supersecret"))
        XCTAssertFalse(result.debugDescription.contains(FleetSiriFixtures.secret))
    }

    func testCopiesOnlyAuthHeaders() throws {
        let server = FleetSiriFixtures.overseer(headers: [
            "Authorization": FleetSiriFixtures.bearer,
            "X-Fleet-Token": "fleet-secret",
            "Cookie": "session=nope",
        ])
        let result = try FleetGatewayResolver.resolve(servers: [server]).get()
        XCTAssertEqual(result.authHeaders["Authorization"], FleetSiriFixtures.bearer)
        XCTAssertEqual(result.authHeaders["X-Fleet-Token"], "fleet-secret")
        XCTAssertNil(result.authHeaders["Cookie"])
    }

    func testPrefersEnabledWhenBothPresent() throws {
        let disabled = FleetSiriFixtures.overseer(enabled: false, url: "https://m4-mcp.rochasilva.co.uk/mcp")
        let enabled = FleetSavedServer(
            id: "live",
            label: "Home Overseer (M4)",
            url: "https://bus.rochasilva.co.uk/mcp",
            headers: ["Authorization": FleetSiriFixtures.bearer],
            enabled: true
        )
        let result = try FleetGatewayResolver.resolve(servers: [disabled, enabled]).get()
        XCTAssertEqual(result.serverID, "live")
    }
}
