import Foundation
import XCTest
@testable import notchi

final class CodexHookInstallerTests: XCTestCase {
    func testCodexDirectoryExistsReturnsFalseWhenConfigDirectoryIsMissing() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertFalse(CodexHookInstaller.codexDirectoryExists(directoryURL: tempRoot))
    }

    func testCodexDirectoryExistsReturnsTrueWhenConfigDirectoryExists() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertTrue(CodexHookInstaller.codexDirectoryExists(directoryURL: tempRoot))
    }

    func testUpsertHooksJSONAddsConfiguredHookCommand() throws {
        let data = CodexHookInstaller.upsertHooksJSON(from: nil, command: "/tmp/notchi-codex-hook.sh")

        XCTAssertTrue(CodexHookInstaller.isHookInstalled(in: data))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let hookEntries = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(hookEntries.first?["command"] as? String, "/tmp/notchi-codex-hook.sh")
    }

    func testUpsertHooksJSONPreservesExistingEntriesAndAvoidsDuplicates() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/tmp/notchi-codex-hook.sh"],
                        ],
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(CodexHookInstaller.upsertHooksJSON(from: existing, command: "/tmp/notchi-codex-hook.sh"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let stopHooks = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])

        XCTAssertEqual(stopHooks.count, 2)
        XCTAssertTrue(CodexHookInstaller.isHookInstalled(in: updated))
    }

    func testUpsertFeatureFlagEnablesCodexHooksInExistingFeaturesSection() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        model = "gpt-5.4"

        [features]
        some_other_flag = true
        """)

        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: updated))
        XCTAssertTrue(updated.contains("some_other_flag = true"))
    }

    func testUpsertFeatureFlagAppendsFeaturesSectionWhenMissing() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        model = "gpt-5.4"
        """)

        XCTAssertTrue(updated.contains("[features]"))
        XCTAssertTrue(updated.contains("codex_hooks = true"))
    }
}
