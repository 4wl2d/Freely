import CopilotCore
import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion = currentSchemaVersion
    public var ai = AIPreferences()
    public var audio = AudioPreferences()
    public var overlay = OverlayPreferences()
    public var shortcuts = ShortcutBinding.defaults
    public var profiles: [UserProfile] = []
    public var selectedProfileID: UUID?
    public var onboardingCompleted = false
    public var connectionMethod: ConnectionMethod = .subscription
    public var subscriptionClientID = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ai, audio, overlay, shortcuts, profiles, selectedProfileID, onboardingCompleted
        case connectionMethod, subscriptionClientID
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else { throw PreferencesError.unsupportedVersion(version) }
        schemaVersion = Self.currentSchemaVersion
        ai = try values.decode(AIPreferences.self, forKey: .ai)
        audio = try values.decode(AudioPreferences.self, forKey: .audio)
        overlay = try values.decode(OverlayPreferences.self, forKey: .overlay)
        shortcuts = try values.decode([ShortcutBinding].self, forKey: .shortcuts)
        profiles = try values.decode([UserProfile].self, forKey: .profiles)
        selectedProfileID = try values.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        onboardingCompleted = try values.decode(Bool.self, forKey: .onboardingCompleted)
        connectionMethod = try values.decodeIfPresent(ConnectionMethod.self, forKey: .connectionMethod) ?? .subscription
        subscriptionClientID = try values.decodeIfPresent(String.self, forKey: .subscriptionClientID) ?? ""
    }

    /// Selection is explicit. An absent/deleted selection never falls back to another profile.
    public var selectedProfile: UserProfile? { profiles.first { $0.id == selectedProfileID } }

    public func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else { throw PreferencesError.unsupportedVersion(schemaVersion) }
        guard subscriptionClientID.utf8.count <= 256,
              subscriptionClientID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
            throw PreferencesError.invalidConfiguration
        }
        guard !ai.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ai.model.utf8.count <= 128,
              ai.answerLanguage.utf8.count <= 64, !ai.answerLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...120).contains(ai.requestsPerMinute), (1...32_768).contains(ai.normalOutputTokens),
              (1...32_768).contains(ai.detailedOutputTokens), ai.modelContextLimit >= ai.detailedOutputTokens + 1_024,
              ai.modelContextLimit <= 2_000_000,
              (0.35...1).contains(overlay.opacity), (11...32).contains(overlay.textSize),
              (280...1_400).contains(overlay.width), (120...1_200).contains(overlay.height),
              audio.speechLanguage == "en", audio.microphoneDeviceUID?.utf8.count ?? 0 <= 512,
              audio.applicationBundleID?.utf8.count ?? 0 <= 512,
              profiles.count <= 20, Set(profiles.map(\.id)).count == profiles.count,
              shortcuts.count == HotkeyAction.allCases.count,
              Set(shortcuts.map(\.action)) == Set(HotkeyAction.allCases) else { throw PreferencesError.invalidConfiguration }
        // Conflicting valid shortcuts are persisted so users can see and repair them in Settings.
        guard shortcuts.allSatisfy({ $0.chord?.isValid ?? true }) else { throw PreferencesError.invalidShortcut }
        for profile in profiles { try profile.validate() }
        guard selectedProfileID == nil || selectedProfile != nil else { throw PreferencesError.missingSelectedProfile }
        return self
    }
}

public struct AIPreferences: Codable, Equatable, Sendable {
    public var model = "grok-4.6"
    public var reasoningEffort: XAIReasoningEffort = .low
    public var answerLanguage = "English"
    public var answerStyle: AnswerStyle = .concise
    public var normalOutputTokens = 4_096
    public var detailedOutputTokens = 8_192
    public var modelContextLimit = 500_000
    public var requestsPerMinute = 12
    public var automaticAnswers = true
    public var localSpeechTriggersAnswers = false
    public var experimentalSpeculation = false
    public init() {}

    public var transportConfiguration: XAIConfiguration {
        var configuration = XAIConfiguration()
        configuration.model = model
        configuration.reasoningEffort = reasoningEffort
        configuration.normalOutputTokens = normalOutputTokens
        configuration.detailedOutputTokens = detailedOutputTokens
        configuration.modelContextLimit = modelContextLimit
        configuration.requestStartsPerMinute = requestsPerMinute
        return configuration
    }
}

public struct AudioPreferences: Codable, Equatable, Sendable {
    public enum SystemScope: String, Codable, Sendable { case application, allSystemAudio }
    public var microphoneEnabled = true
    /// nil follows the current system default. A persisted explicit UID is stable across process launches.
    public var microphoneDeviceUID: String?
    public var systemAudioEnabled = true
    public var systemScope: SystemScope = .application
    /// A PID is deliberately not persisted: the application resolves this bundle ID against current sources.
    public var applicationBundleID: String?
    public var speechLanguage = "en"
    public init() {}
}

public struct OverlayPreferences: Codable, Equatable, Sendable {
    public var opacity = 0.94
    public var textSize = 15.0
    public var width = 420.0
    public var height = 240.0
    public var clickThrough = false
    public var initiallyVisible = true
    public var expanded = false
    public init() {}
}

public struct UserProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var role = ""
    public var professionalBackground = ""
    public var technologyStack = ""
    public var projectContext = ""
    public var answerPreferences = ""
    public var vocabulary = ""
    public var customInstructions = ""
    public var importedContext = ""

    public init(id: UUID = UUID(), name: String = "New profile") { self.id = id; self.name = name }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 120,
              role.utf8.count <= 2_048, professionalBackground.utf8.count <= 16_384,
              technologyStack.utf8.count <= 8_192, projectContext.utf8.count <= 16_384,
              answerPreferences.utf8.count <= 4_096, vocabulary.utf8.count <= 8_192,
              customInstructions.utf8.count <= 8_192, importedContext.utf8.count <= 131_072 else { throw PreferencesError.profileTooLarge }
    }

    /// Stable field framing; imported text remains untrusted observed material in the context builder.
    /// Only invoke on the explicitly selected profile. The domain builder performs its own final budget enforcement.
    public var contextText: String {
        [("Role", role), ("Professional background", professionalBackground), ("Technology stack", technologyStack),
         ("Project context", projectContext), ("Answer preferences", answerPreferences), ("Vocabulary", vocabulary),
         ("User custom instructions", customInstructions), ("Imported context (untrusted)", importedContext)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.0):\n\($0.1)" }.joined(separator: "\n\n")
    }

    /// Deterministic lexical selection for large user-selected material; no embedding database or remote indexing.
    public func selectedContext(for question: String, maximumBytes: Int = 2_000) -> ProfileContextSelection {
        let stopwords: Set<String> = ["the", "and", "for", "this", "that", "what", "how", "would", "could", "about", "with", "your"]
        func terms(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopwords.contains($0) })
        }
        let query = terms(question)
        let fields: [(String, String, Int)] = [
            ("Role", role, 80), ("Professional background", professionalBackground, 20), ("Technology stack", technologyStack, 50),
            ("Project context", projectContext, 40), ("Answer preferences", answerPreferences, 80), ("Vocabulary", vocabulary, 10),
            ("User custom instructions", customInstructions, 100), ("Imported context (untrusted)", importedContext, 0)
        ]
        struct Entry { let index: Int; let text: String; let score: Int }
        var candidates: [Entry] = []
        for (label, field, priority) in fields {
            for line in field.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                candidates.append(Entry(index: candidates.count, text: "\(label):\n\(text)", score: priority + query.intersection(terms(text)).count * 100))
            }
        }
        var selected: [Entry] = []
        var bytes = 0
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
            let cost = candidate.text.utf8.count + (selected.isEmpty ? 0 : 2)
            if bytes + cost <= max(0, maximumBytes) { selected.append(candidate); bytes += cost }
        }
        return ProfileContextSelection(text: selected.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n\n"),
                                       omittedParagraphCount: candidates.count - selected.count)
    }
}

public struct ProfileContextSelection: Sendable, Equatable {
    public let text: String
    public let omittedParagraphCount: Int
    public var isLimited: Bool { omittedParagraphCount > 0 }
}

public enum PreferencesError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidConfiguration
    case invalidShortcut
    case missingSelectedProfile
    case profileTooLarge
    case corruptConfiguration
    case storageUnavailable
    case importTooLarge
    case unsupportedImport
    case invalidTextEncoding
    case emptyImport
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Settings use unsupported format version \(version). Use a compatible application version or explicitly clear local settings."
        case .invalidConfiguration: "Settings contain an unsupported value. Review AI, audio and overlay limits before saving."
        case .invalidShortcut: "Use a valid key with Command or Control for each enabled shortcut."
        case .missingSelectedProfile: "The selected profile is unavailable. Explicitly select another profile or select None."
        case .profileTooLarge: "The profile exceeds a field limit. Shorten it or import a text file no larger than 128 KiB."
        case .corruptConfiguration: "The settings file is unreadable or corrupted. It has been preserved. Clear local settings explicitly to restore defaults."
        case .storageUnavailable: "Local settings could not be read or saved. Check storage access and available disk space."
        case .importTooLarge: "Import a text or Markdown file no larger than 128 KiB."
        case .unsupportedImport: "Choose a local .txt, .md or .markdown file. PDF and scanned document import are not supported."
        case .invalidTextEncoding: "The selected file is not valid UTF-8 text. Export it as UTF-8 and try again."
        case .emptyImport: "The selected file has no readable text."
        }
    }
}
