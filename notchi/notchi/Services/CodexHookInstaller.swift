import Foundation
import os.log

nonisolated private let codexHookLogger = Logger(subsystem: "com.ruban.notchi", category: "CodexHookInstaller")

struct CodexHookInstaller {
    nonisolated private static let hookScriptName = "notchi-codex-hook.sh"

    nonisolated static var codexDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    nonisolated static var hooksJSONURL: URL {
        codexDirectoryURL.appendingPathComponent("hooks.json")
    }

    nonisolated static var configURL: URL {
        codexDirectoryURL.appendingPathComponent("config.toml")
    }

    nonisolated static var hooksDirectoryURL: URL {
        codexDirectoryURL.appendingPathComponent("hooks", isDirectory: true)
    }

    nonisolated static var hookScriptURL: URL {
        hooksDirectoryURL.appendingPathComponent(hookScriptName)
    }

    nonisolated static var hookCommand: String {
        hookScriptURL.path
    }

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let fileManager = FileManager.default

        guard codexDirectoryExists(fileManager: fileManager, directoryURL: codexDirectoryURL) else {
            codexHookLogger.warning("Codex not installed (config dir not found at \(codexDirectoryURL.path, privacy: .public))")
            return false
        }

        do {
            try fileManager.createDirectory(at: hooksDirectoryURL, withIntermediateDirectories: true)
        } catch {
            codexHookLogger.error("Failed to create Codex hook directories: \(error.localizedDescription)")
            return false
        }

        guard let bundled = Bundle.main.url(forResource: "notchi-codex-hook", withExtension: "sh") else {
            codexHookLogger.error("Codex hook script not found in bundle")
            return false
        }

        do {
            let bundledData = try Data(contentsOf: bundled)
            try bundledData.write(to: hookScriptURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
            codexHookLogger.info("Installed Codex hook script to \(hookScriptURL.path, privacy: .public)")
        } catch {
            codexHookLogger.error("Failed to install Codex hook script: \(error.localizedDescription)")
            return false
        }

        let hooksWritten = updateHooksJSON(at: hooksJSONURL, command: hookCommand)
        let featureEnabled = updateConfig(at: configURL)
        return hooksWritten && featureEnabled
    }

    nonisolated static func upsertHooksJSON(from existingData: Data?, command: String) -> Data? {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let desiredHookEvents: [String: [[String: Any]]] = [
            "SessionStart": [makeHookGroup(matcher: "startup|resume", command: command)],
            "UserPromptSubmit": [makeHookGroup(matcher: nil, command: command)],
            "Stop": [makeHookGroup(matcher: nil, command: command, timeout: 30)],
        ]

        for (event, desiredEntries) in desiredHookEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = pruneManagedHooks(from: existingEntries) + desiredEntries
        }

        json["hooks"] = hooks

        return try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated private static func pruneManagedHooks(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let filteredHooks = entryHooks.filter { hook in
                let existingCommand = hook["command"] as? String ?? ""
                return !existingCommand.contains(hookScriptName)
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = filteredHooks
            return updatedEntry
        }
    }

    nonisolated static func upsertFeatureFlag(in existingContents: String?) -> String {
        let featureLine = "codex_hooks = true"
        var text = existingContents ?? ""

        if let range = text.range(
            of: #"(?m)^[ \t]*codex_hooks[ \t]*=[^\n]*$"#,
            options: .regularExpression
        ) {
            text.replaceSubrange(range, with: featureLine)
            return text
        }

        if let featuresRange = text.range(of: #"(?m)^\[features\][ \t]*$"#, options: .regularExpression) {
            if let newlineIndex = text[featuresRange.upperBound...].firstIndex(of: "\n") {
                let insertionPoint = text.index(after: newlineIndex)
                text.insert(contentsOf: "\(featureLine)\n", at: insertionPoint)
            } else {
                text.insert(contentsOf: "\n\(featureLine)", at: featuresRange.upperBound)
            }
            return text
        }

        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }

        return text + "\n[features]\n\(featureLine)\n"
    }

    nonisolated static func isHookInstalled(in hooksData: Data?) -> Bool {
        guard let hooksData,
              let json = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains(hookScriptName) == true
                }
            }
        }
    }

    nonisolated static func isFeatureEnabled(in configContents: String?) -> Bool {
        guard let configContents else { return false }
        return configContents.range(
            of: #"(?m)^[ \t]*codex_hooks[ \t]*=[ \t]*true[ \t]*$"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func isInstalled() -> Bool {
        let hooksData = try? Data(contentsOf: hooksJSONURL)
        let configContents = try? String(contentsOf: configURL, encoding: .utf8)
        return isHookInstalled(in: hooksData) && isFeatureEnabled(in: configContents)
    }

    nonisolated static func codexDirectoryExists(
        fileManager: FileManager = .default,
        directoryURL: URL = codexDirectoryURL
    ) -> Bool {
        fileManager.fileExists(atPath: directoryURL.path)
    }

    nonisolated private static func makeHookGroup(
        matcher: String?,
        command: String,
        timeout: Int? = nil
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": command,
        ]
        if let timeout {
            hook["timeout"] = timeout
        }

        var group: [String: Any] = [
            "hooks": [hook]
        ]
        if let matcher, !matcher.isEmpty {
            group["matcher"] = matcher
        }

        return group
    }

    nonisolated private static func updateHooksJSON(at url: URL, command: String) -> Bool {
        let existingData = try? Data(contentsOf: url)

        guard let data = upsertHooksJSON(from: existingData, command: command) else {
            codexHookLogger.error("Failed to serialize Codex hooks.json")
            return false
        }

        do {
            try data.write(to: url)
            codexHookLogger.info("Updated hooks.json with Notchi Codex hooks")
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex hooks.json: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func updateConfig(at url: URL) -> Bool {
        let existingContents = try? String(contentsOf: url, encoding: .utf8)
        let updatedContents = upsertFeatureFlag(in: existingContents)

        do {
            try updatedContents.write(to: url, atomically: true, encoding: .utf8)
            codexHookLogger.info("Enabled codex_hooks in config.toml")
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex config.toml: \(error.localizedDescription)")
            return false
        }
    }
}
