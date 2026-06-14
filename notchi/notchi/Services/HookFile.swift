import Foundation

nonisolated enum HookFile {
    static let executablePermissions: Int16 = 0o755

    static func writeScriptIfNeeded(
        _ bundledData: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        if let existingData = try? Data(contentsOf: url),
           existingData == bundledData,
           hasExecutablePermissions(at: url, fileManager: fileManager) {
            return
        }

        try bundledData.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: executablePermissions],
            ofItemAtPath: url.path
        )
    }

    static func hasExecutablePermissions(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.int16Value == executablePermissions
    }
}
