import Foundation
import Testing
@testable import Freely

struct PreferencesTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FreelyPreferencesTest-\(UUID().uuidString)", isDirectory: true) }
    private func cleanup(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    @Test func defaultsExcludeSessionDataAndNeverAutoSelectAProfile() async throws {
        let directory = directory()
        let store = PreferencesStore(directory: directory)
        let value = try await store.load()
        #expect(value.selectedProfileID == nil)
        #expect(value.ai.model == "grok-4.6")
        #expect(value.ai.reasoningEffort == .low)
        #expect(value.audio.microphoneDeviceUID == nil)
        #expect(value.audio.systemScope == .application)
        #expect(value.ai.experimentalSpeculation == false)
        #expect(value.shortcuts.count == 10)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for absent in ["apiKey", "credential", "transcript", "screenConsent", "visualSnapshot", "sessionNotes"] { #expect(object[absent] == nil) }
        let audio = try #require(object["audio"] as? [String: Any])
        #expect(audio["samples"] == nil)
        #expect(audio["pid"] == nil)
    }

    @Test func selectedProfileRoundtripAtomicReplaceAndPermissions() async throws {
        let directory = directory()
        let store = PreferencesStore(directory: directory)
        var preferences = AppPreferences()
        var first = UserProfile(name: "Selected")
        first.role = "Engineer"; first.projectContext = "Swift project"
        let second = UserProfile(name: "Unselected")
        preferences.profiles = [first, second]
        preferences.selectedProfileID = first.id
        try await store.save(preferences)
        #expect(try await store.load() == preferences)
        #expect(try await store.load().selectedProfile?.name == "Selected")
        preferences.ai.answerLanguage = "Serbian"
        try await store.save(preferences)
        #expect(try await store.load().ai.answerLanguage == "Serbian")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["preferences.json"])
        try await store.clearConfiguration()
        try await store.clearConfiguration()
        #expect(try await store.load() == AppPreferences())
        try cleanup(directory)
    }

    @Test func corruptAndFutureFilesArePreservedUntilExplicitClear() async throws {
        for bytes in [Data("invalid json".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            let directory = directory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = PreferencesStore(directory: directory)
            try bytes.write(to: store.fileURL)
            do { _ = try await store.load(); Issue.record("Expected load failure") }
            catch { #expect(error is PreferencesError) }
            do { try await store.save(AppPreferences()); Issue.record("Automatic overwrite must be blocked") }
            catch { #expect(error as? PreferencesError == .corruptConfiguration) }
            #expect(try Data(contentsOf: store.fileURL) == bytes)
            try await store.clearConfiguration()
            try await store.save(AppPreferences())
            #expect(try await store.load().schemaVersion == AppPreferences.currentSchemaVersion)
            try cleanup(directory)
        }
    }

    @Test func validationRejectsUnknownSelectionOversizeAndInvalidShortcut() throws {
        var preferences = AppPreferences()
        preferences.selectedProfileID = UUID()
        #expect(throws: PreferencesError.missingSelectedProfile) { try preferences.validated() }
        preferences.selectedProfileID = nil
        var profile = UserProfile()
        profile.importedContext = String(repeating: "x", count: 131_073)
        preferences.profiles = [profile]
        #expect(throws: PreferencesError.profileTooLarge) { try preferences.validated() }
        preferences.profiles = []
        preferences.shortcuts[0].chord = .init(key: .a, modifiers: .shift)
        #expect(throws: PreferencesError.invalidShortcut) { try preferences.validated() }
        preferences.shortcuts = ShortcutBinding.defaults
        preferences.overlay.opacity = .nan
        #expect(throws: PreferencesError.invalidConfiguration) { try preferences.validated() }
    }

    @Test func importedFileRemainsUnchangedAndInvalidInputsAreRejected() async throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("resume.md")
        let bytes = Data("\u{feff}# Experience\nNative Swift applications 👋".utf8)
        try bytes.write(to: file)
        #expect(try await ProfileTextImporter.read(url: file) == "# Experience\nNative Swift applications 👋")
        #expect(try Data(contentsOf: file) == bytes)
        for (data, expected) in [(Data(repeating: 120, count: 131_073), PreferencesError.importTooLarge),
                                 (Data([0xFF, 0xFE]), .invalidTextEncoding), (Data(" \n".utf8), .emptyImport)] {
            try data.write(to: file)
            do { _ = try await ProfileTextImporter.read(url: file); Issue.record("Expected import failure") }
            catch { #expect(error as? PreferencesError == expected) }
        }
        do { _ = try await ProfileTextImporter.read(url: directory.appendingPathComponent("scan.pdf")); Issue.record("Expected unsupported PDF") }
        catch { #expect(error as? PreferencesError == .unsupportedImport) }
        try cleanup(directory)
    }

    @Test func relevantSelectedProfileParagraphsStayBoundedAndSourceFaithful() {
        var profile = UserProfile(name: "Context")
        profile.importedContext = "I grew tomatoes.\nOur project uses Kotlin StateFlow for ordering.\nI studied watercolor painting."
        let selected = profile.selectedContext(for: "Explain StateFlow ordering", maximumBytes: 90)
        #expect(selected.text.contains("Our project uses Kotlin StateFlow for ordering."))
        #expect(!selected.text.contains("watercolor"))
        #expect(selected.text.utf8.count <= 90)
        #expect(selected.isLimited)
        #expect(profile.selectedContext(for: "Explain StateFlow ordering", maximumBytes: 90) == selected)
        #expect(profile.selectedContext(for: "test", maximumBytes: 0).text.isEmpty)
    }
}
