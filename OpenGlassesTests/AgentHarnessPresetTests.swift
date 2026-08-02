import XCTest
@testable import OpenGlasses

final class AgentHarnessPresetTests: XCTestCase {

    // MARK: - Codex preset

    func testCodexPresetEndpointsAndAuth() {
        let cfg = AgentHarnessPreset.codexCloud(token: "sk-abc", baseURL: nil)
        XCTAssertEqual(cfg.startURL, "https://api.openai.com/v1/agents/runs")
        XCTAssertEqual(cfg.statusURLTemplate, "https://api.openai.com/v1/agents/runs/{id}")
        XCTAssertEqual(cfg.authHeader, "Authorization")
        XCTAssertEqual(cfg.authValue, "Bearer sk-abc")
        XCTAssertTrue(cfg.isConfigured)
    }

    func testCodexPresetHonoursBaseURLOverrideAndTrimsSlash() {
        let cfg = AgentHarnessPreset.codexCloud(token: "t", baseURL: "https://my.codex.host/api/")
        XCTAssertEqual(cfg.startURL, "https://my.codex.host/api/runs")
        XCTAssertEqual(cfg.statusURLTemplate, "https://my.codex.host/api/runs/{id}")
    }

    func testEmptyTokenLeavesAuthValueBlank() {
        XCTAssertEqual(AgentHarnessPreset.codexCloud(token: "", baseURL: nil).authValue, "")
    }

    // MARK: - Claude Code bridge preset

    func testClaudePresetUsesBearerTokenAndBridgeUrls() {
        let cfg = AgentHarnessPreset.claudeRemote(token: "key123", baseURL: "https://mba.local:8898/v1/claude/")
        XCTAssertEqual(cfg.authHeader, "Authorization")
        XCTAssertEqual(cfg.authValue, "Bearer key123")
        XCTAssertEqual(cfg.startURL, "https://mba.local:8898/v1/claude/sessions")
        XCTAssertEqual(cfg.statusURLTemplate, "https://mba.local:8898/v1/claude/sessions/{id}")
        XCTAssertEqual(cfg.cancelURLTemplate, "https://mba.local:8898/v1/claude/sessions/{id}/cancel")
    }

    func testClaudePresetWithoutBridgeURLIsNotConfigured() {
        let cfg = AgentHarnessPreset.claudeRemote(token: "key123", baseURL: nil)
        XCTAssertEqual(cfg.authHeader, "Authorization")
        XCTAssertEqual(cfg.authValue, "Bearer key123")
        XCTAssertEqual(cfg.startURL, "")
        XCTAssertFalse(cfg.isConfigured)
    }

    func testConfigForKind() {
        XCTAssertNotNil(AgentHarnessPreset.config(for: .codexCloud, token: "t", baseURL: nil))
        XCTAssertNotNil(AgentHarnessPreset.config(for: .claudeRemote, token: "t", baseURL: nil))
        XCTAssertNil(AgentHarnessPreset.config(for: .openclaw, token: "t", baseURL: nil))
        XCTAssertNil(AgentHarnessPreset.config(for: .custom, token: "t", baseURL: nil))
    }

    // MARK: - Kind tagging + readiness on the generalized harness

    func testHarnessReportsItsKindAndConfiguredOverride() {
        let cfg = AgentHarnessPreset.codexCloud(token: "t", baseURL: nil)
        let configured = CustomAgentHarness(kind: .codexCloud, config: cfg, displayName: "OpenAI Codex (cloud)", isConfigured: true)
        XCTAssertEqual(configured.kind, .codexCloud)
        XCTAssertEqual(configured.displayName, "OpenAI Codex (cloud)")
        XCTAssertTrue(configured.isConfigured)

        let notReady = CustomAgentHarness(kind: .claudeRemote, config: AgentHarnessPreset.claudeRemote(token: "", baseURL: nil), isConfigured: false)
        XCTAssertFalse(notReady.isConfigured)
    }

    func testStartRequestCarriesAuthAndPrompt() {
        let cfg = AgentHarnessPreset.codexCloud(token: "sk-1", baseURL: nil)
        let req = cfg.startRequest(prompt: "add a test", project: "app")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        let body = req?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["prompt"] as? String, "add a test")
        XCTAssertEqual(body?["project"] as? String, "app")
    }

    func testDefaultBackendPickerCoversAllKinds() {
        // The Settings picker enumerates AgentHarnessKind.allCases — guard the count so a new
        // kind can't silently drop out of the UI.
        XCTAssertEqual(Set(AgentHarnessKind.allCases), [.openclaw, .codexCloud, .claudeRemote, .custom])
    }
}
