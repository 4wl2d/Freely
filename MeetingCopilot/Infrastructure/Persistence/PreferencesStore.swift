import Foundation

/// One bounded, versioned nonsecret file. Profiles are plaintext with user-only filesystem access, not encrypted.
public actor PreferencesStore {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingCopilot", isDirectory: true)
    }
    public nonisolated let directory: URL
    public nonisolated let fileURL: URL
    private let maximumBytes = 4 * 1_024 * 1_024
    private var hasLoaded = false
    private var requiresReset = false

    public init(directory: URL = PreferencesStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("preferences.json")
    }

    public func load() throws -> AppPreferences {
        do {
            let preferences = try readConfiguration()
            hasLoaded = true
            requiresReset = false
            return preferences
        } catch {
            hasLoaded = true
            requiresReset = true
            throw error
        }
    }

    private func readConfiguration() throws -> AppPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppPreferences() }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { do { try handle.close() } catch { /* Closing a completed read cannot change decoded settings. */ } }
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch { throw PreferencesError.storageUnavailable }
        guard data.count <= maximumBytes else { throw PreferencesError.corruptConfiguration }
        struct Header: Decodable { let schemaVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard (1...AppPreferences.currentSchemaVersion).contains(header.schemaVersion) else { throw PreferencesError.unsupportedVersion(header.schemaVersion) }
            return try JSONDecoder().decode(AppPreferences.self, from: data).validated()
        } catch let error as PreferencesError { throw error }
        catch { throw PreferencesError.corruptConfiguration }
    }

    public func save(_ preferences: AppPreferences) throws {
        if !hasLoaded { _ = try load() }
        guard !requiresReset else { throw PreferencesError.corruptConfiguration }
        let valid = try preferences.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(valid) } catch { throw PreferencesError.invalidConfiguration }
        guard data.count <= maximumBytes else { throw PreferencesError.profileTooLarge }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw PreferencesError.storageUnavailable }
    }

    /// Only called after the user chooses Clear local data. Models and Keychain are separate explicit owners.
    public func clearConfiguration() throws {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            hasLoaded = true
            requiresReset = false
        }
        catch { throw PreferencesError.storageUnavailable }
    }
}

public enum ProfileTextImporter {
    /// Reads a derivative into memory and never moves, rewrites or deletes the selected source file.
    public static func read(url: URL) async throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL, ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) else { throw PreferencesError.unsupportedImport }
        let maximumBytes = 131_072
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            do {
                data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                try handle.close()
            } catch {
                do { try handle.close() } catch { /* Preserve the original import error. */ }
                throw error
            }
        } catch { throw PreferencesError.storageUnavailable }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw PreferencesError.importTooLarge }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw PreferencesError.invalidTextEncoding }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreferencesError.emptyImport }
        return text
    }
}
