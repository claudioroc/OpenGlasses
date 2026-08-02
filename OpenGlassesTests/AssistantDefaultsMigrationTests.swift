import XCTest
@testable import OpenGlasses

final class AssistantDefaultsMigrationTests: XCTestCase {
    private let keys = [
        "assistantDefaults202607Migrated",
        "defaultAgentHarness",
        "activePromptPresetId",
        "savedPersonas",
    ]

    override func setUp() {
        super.setUp()
        clearState()
    }

    override func tearDown() {
        clearState()
        super.tearDown()
    }

    private func clearState() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func legacyPersona() -> Persona {
        Persona(
            id: "legacy-default",
            name: "OpenGlasses",
            wakePhrase: "hey claude",
            alternativeWakePhrases: [],
            modelId: "model-1",
            presetId: "preset-wine-sommelier",
            enabled: true
        )
    }

    func testRepairsPersistedSommelierDefaultsWithoutChangingHarnessChoice() {
        Config.setDefaultAgentHarness(.claudeRemote)
        Config.setActivePresetId("preset-wine-sommelier")
        Config.setSavedPersonas([legacyPersona()])

        Config.migrateAssistantDefaultsIfNeeded()

        XCTAssertEqual(Config.defaultAgentHarness, .claudeRemote)
        XCTAssertEqual(Config.activePresetId, "preset-default")
        XCTAssertEqual(Config.savedPersonas.first?.name, "Claude")
        XCTAssertEqual(Config.savedPersonas.first?.presetId, "preset-default")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "assistantDefaults202607Migrated"))
    }

    func testMigrationRunsOnlyOnce() {
        Config.setDefaultAgentHarness(.claudeRemote)
        Config.setActivePresetId("preset-wine-sommelier")
        Config.setSavedPersonas([legacyPersona()])
        Config.migrateAssistantDefaultsIfNeeded()

        Config.setDefaultAgentHarness(.custom)
        Config.setActivePresetId("preset-wine-sommelier")
        Config.migrateAssistantDefaultsIfNeeded()

        XCTAssertEqual(Config.defaultAgentHarness, .custom)
        XCTAssertEqual(Config.activePresetId, "preset-wine-sommelier")
    }

    func testMigrationPreservesOtherExplicitHarnessAndPresetChoices() {
        let specialist = Persona(
            id: "mode-specialist",
            name: "Specialist",
            wakePhrase: "hey specialist",
            alternativeWakePhrases: [],
            modelId: "model-2",
            presetId: "preset-clinical-assistant",
            enabled: true
        )
        Config.setDefaultAgentHarness(.codexCloud)
        Config.setActivePresetId("preset-clinical-assistant")
        Config.setSavedPersonas([specialist])

        Config.migrateAssistantDefaultsIfNeeded()

        XCTAssertEqual(Config.defaultAgentHarness, .codexCloud)
        XCTAssertEqual(Config.activePresetId, "preset-clinical-assistant")
        XCTAssertNotNil(Config.persona(named: "Claude"))
    }
}
