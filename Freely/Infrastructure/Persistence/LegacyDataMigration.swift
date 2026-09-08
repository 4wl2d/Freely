import Foundation

/// Copy the former app's data once. Existing Freely data wins and the source is never
/// moved/deleted. Original names here are migration keys, not current product identity.
enum LegacyDataMigration {
    static let marker = ".legacy-import-complete"
    static func copyIfNeeded(destination: URL, legacy: URL) throws -> Bool {
        let manager = FileManager.default
        let markerURL = destination.appendingPathComponent(marker)
        guard !manager.fileExists(atPath: markerURL.path) else { return false }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied = false
        for name in ["preferences.json", "Models"] {
            let source = legacy.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) else { continue }
            guard (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { continue }
            let staged = destination.appendingPathComponent(".import-\(UUID().uuidString)")
            do {
                try manager.copyItem(at: source, to: staged)
                try manager.moveItem(at: staged, to: target)
                copied = true
            } catch {
                try? manager.removeItem(at: staged)
                throw PreferencesError.storageUnavailable
            }
        }
        try Data().write(to: markerURL, options: .atomic)
        return copied
    }
}
