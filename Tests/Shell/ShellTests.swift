import AppKit
import FreelyCore
import SwiftUI
import Testing
@testable import Freely

struct PanelMigrationTests {
    @Test func migratesBothLegacyVersionsWithoutChangingUserBindingsOrProfiles() throws {
        for version in [1, 2] {
            var preferences = AppPreferences()
            var profile = UserProfile(name: "Engineer")
            profile.projectContext = "A saved project"
            preferences.profiles = [profile]; preferences.selectedProfileID = profile.id
            preferences.ai.answerLanguage = "Serbian"
            preferences.connectionMethod = .apiKey
            preferences.shortcuts.removeAll { $0.action == .focusQuestion || $0.action == .togglePresentationUI }
            preferences.shortcuts[1].chord = .init(key: .k, modifiers: [.command, .shift])
            preferences.shortcuts[2].chord = nil
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
            json["schemaVersion"] = version; json.removeValue(forKey: "panel")
            let migrated = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: json)).validated()
            #expect(migrated.schemaVersion == 3)
            #expect(migrated.profiles == preferences.profiles)
            #expect(migrated.selectedProfileID == profile.id)
            #expect(migrated.ai == preferences.ai)
            #expect(migrated.connectionMethod == .apiKey)
            for old in preferences.shortcuts { #expect(migrated.shortcuts.first { $0.action == old.action } == old) }
            #expect(migrated.panel.positionLocked)
            #expect(migrated.shortcuts.first { $0.action == .focusQuestion }?.chord == .init(key: .return, modifiers: [.control, .option]))
            #expect(migrated.shortcuts.first { $0.action == .togglePresentationUI }?.chord == nil)
        }
    }
    @Test func newInstallationHasIndependentPanelDefaultsAndRejectsInvalidGeometry() throws {
        var preferences = AppPreferences()
        #expect(preferences.shortcuts.first { $0.action == .toggleOverlay }?.chord == .init(key: .space, modifiers: [.control, .option]))
        #expect(preferences.panel.positionLocked)
        preferences.panel.geometries = [.init(displayID: 1, expanded: false, x: .infinity, y: 0, width: 720, height: 520)]
        #expect(throws: PreferencesError.invalidConfiguration) { try preferences.validated() }
    }
    @Test func geometryFollowsDisplayIdentityWhenTheNumericIDChanges() throws {
        var preferences = PanelPreferences()
        let uuid = UUID().uuidString
        let saved = PanelGeometry(displayID: 1, expanded: false, x: -900, y: 100, width: 720, height: 520, displayUUID: uuid)
        preferences.geometries = [saved]
        #expect(preferences.geometry(displayID: 99, displayUUID: uuid.lowercased(), expanded: false) == saved)
        #expect(preferences.geometry(displayID: 1, displayUUID: UUID().uuidString, expanded: false) == nil)
        #expect(preferences.geometry(displayID: 1, displayUUID: uuid, expanded: true) == nil)
        let json = Data("{\"positionLocked\":true,\"geometries\":[]}".utf8)
        #expect(try JSONDecoder().decode(PanelPreferences.self, from: json).lastDisplayUUID == nil)
    }
    @Test func nativeSelectionKeepsRepeatedWordsAndUnicodeAcrossCorrections() {
        let old = "First repeat.\n\nSecond 👋 repeat remains selected."
        let selection = (old as NSString).range(of: "repeat", options: .backwards)
        let new = "A longer first repeat.\n\nSecond 👋 repeat remains selected."
        let mapped = NativeSelection.restoring(selection, from: old, to: new)
        #expect(mapped == (new as NSString).range(of: "repeat", options: .backwards))
        #expect((new as NSString).substring(with: mapped) == "repeat")
    }
    @Test func disconnectedAndSmallDisplaysKeepTheWholePanelReachable() {
        for visible in [CGRect(x: -1920, y: 0, width: 1920, height: 1050), CGRect(x: 0, y: 0, width: 480, height: 320)] {
            for frame in [CGRect(x: 5000, y: 5000, width: 960, height: 700), CGRect(x: -5000, y: -1000, width: 100, height: 100)] {
                let clamped = ShellGeometry.clamped(frame, to: visible)
                #expect(visible.contains(clamped))
                #expect(clamped.width >= min(600, visible.width))
                #expect(clamped.height >= min(420, visible.height))
            }
        }
    }
}

@MainActor struct ShellLifecycleTests {
    @Test func escapeUnwindsTransientStateBeforeNavigationAndKeepsDrafts() async {
        let model = ApplicationModel()
        model.typedQuestion = "Draft question"
        model.sessionNotes = "Unsent session notes"
        model.section = .context; model.section = .settings; model.section = .ai
        model.shell.commandsVisible = true
        #expect(model.shell.back())
        #expect(model.section == .ai)
        model.shell.confirmation = .endSession
        #expect(model.shell.back())
        #expect(model.section == .ai)
        #expect(model.shell.back()); #expect(model.section == .settings)
        model.cancelPanelTransientWork()
        #expect(model.typedQuestion == "Draft question")
        #expect(model.sessionNotes == "Unsent session notes")
        #expect(model.shell.back()); #expect(model.section == .context)
        #expect(model.shell.back()); #expect(!model.shell.back())
        await model.shutdown()
    }
    @Test func endingSessionClearsEveryVolatilePresentationAndReturnsToReadiness() async {
        let model = ApplicationModel()
        model.section = .diagnostics; model.typedQuestion = "Question"; model.sessionNotes = "Notes"; model.pinnedFacts = "Facts"
        model.shell.commandsVisible = true
        await model.stop()
        #expect(model.section == .setup && model.shell.history.isEmpty)
        #expect(model.typedQuestion.isEmpty && model.sessionNotes.isEmpty && model.pinnedFacts.isEmpty)
        #expect(!model.shell.commandsVisible)
        #expect(!model.presentation.active)
        await model.shutdown()
    }
    @Test func hiddenPanelNeverPresentsOrAppliesAFileSheet() {
        let owner = PanelDialogCoordinator()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        owner.window = window
        var result: NSApplication.ModalResponse?
        owner.present(NSOpenPanel()) { result = $0 }
        #expect(result == .cancel)
        #expect(owner.active == nil)
        owner.cancel(); #expect(owner.revision == 1)
    }
    @Test func lockingDoesNotDisableTextOrFreezeTheAnswer() async {
        let model = ApplicationModel()
        let controller = ShellWindowController(model: model)
        #expect(!controller.panel.isMovable)
        #expect(!controller.panel.ignoresMouseEvents)
        #expect(controller.panel.canBecomeKey)
        #expect(!model.pinned)
        model.preferences.panel.positionLocked = false; controller.updatePreferences()
        #expect(controller.panel.isMovable && controller.panel.styleMask.contains(.resizable))
        #expect(!model.pinned)
        controller.dispose(); await model.shutdown()
    }
    @Test func regionMappingClipsToSourceAndCancellationPreservesPriorSelection() {
        let rect = RegionEditorState.map(CGRect(x: 25, y: 20, width: 1000, height: 1000), previewSize: CGSize(width: 200, height: 100), sourceSize: CGSize(width: 1000, height: 500))
        #expect(rect == CGRect(x: 125, y: 100, width: 875, height: 400))
    }
    @Test func transcriptIncludesInterimTimestampsAndActualGaps() {
        let speech = TranscriptSegment(source: .systemAudio, sequence: 1, startTime: 61, endTime: 63, text: "A partial question", finality: .partial)
        let gap = AudioDiscontinuity(source: .localUser, startTime: 60, endTime: 61, cause: .overflow)
        let text = TranscriptExcerpt.body(segments: [speech], gaps: [gap])
        #expect(text.contains("01:01 · Interim"))
        #expect(text.contains("01:00–01:01 · Audio gap"))
        #expect(text.hasPrefix("Local microphone"))
    }
}

struct PresentationCompositorTests {
    static func solid(_ color: CGColor, size: CGSize = CGSize(width: 100, height: 100)) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color); context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }
    static func hasMagenta(_ image: CGImage, minimumIntensity: UInt8 = 240) -> Bool {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            if data[index] > minimumIntensity && data[index + 1] < 12 && data[index + 2] > minimumIntensity { return true }
        }
        return false
    }
    @Test func onlyAnExplicitPanelLayerAddsMarkersAndNeutralAlwaysRemovesThem() throws {
        let source = try Self.solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let marker = try Self.solid(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 1, 1])!)
        let shown = try #require(PresentationCompositor.compose(source: source, panel: marker))
        let hidden = try #require(PresentationCompositor.compose(source: source, panel: nil))
        let neutral = try #require(PresentationCompositor.compose(source: nil, panel: marker))
        #expect(shown.width == 1920 && shown.height == 1080)
        #expect(Self.hasMagenta(marker))
        #expect(Self.hasMagenta(shown))
        #expect(!Self.hasMagenta(hidden))
        #expect(!Self.hasMagenta(neutral))
    }
    @Test func panelsFitInsideSixteenPixelMarginAndSourcePreservesAspectRatio() {
        for size in [CGSize(width: 720, height: 520), CGSize(width: 4000, height: 3000)] {
            let rect = PresentationCompositor.panelRect(size)
            #expect(abs(rect.width / rect.height - size.width / size.height) < 0.00001)
            #expect(rect.maxX == 1904 && rect.minY == 16)
            #expect(rect.minX >= 16 && rect.maxY <= 1064)
        }
        #expect(PresentationCompositor.fit(CGSize(width: 100, height: 100), into: CGRect(x: 0, y: 0, width: 1920, height: 1080)) == CGRect(x: 420, y: 0, width: 1080, height: 1080))
    }
    @Test func captureMailboxRetainsOnlyTheNewestFrameOrFailure() {
        let mailbox = PresentationMailbox()
        for index in 0..<10_000 { mailbox.replace(.unavailable(UInt64(index))) }
        if case .unavailable(let revision) = mailbox.take() { #expect(revision == 9_999) } else { Issue.record("Missing latest signal") }
        #expect(mailbox.take() == nil)
        mailbox.replace(.unavailable(1)); mailbox.clear(); #expect(mailbox.take() == nil)
        mailbox.replace(.unavailable(5)); mailbox.discard(through: 4)
        if case .unavailable(let revision) = mailbox.take() { #expect(revision == 5) } else { Issue.record("New stream was discarded") }
        mailbox.replace(.unavailable(4)); mailbox.discard(through: 4); #expect(mailbox.take() == nil)
    }
}

@MainActor struct ShellSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_SHELL_SNAPSHOTS"] == "1", "Opt-in rendered shell fixture screenshots"))
    func everyScreenAtBothSizes() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FREELY_SHELL_SNAPSHOT_DIR"] ?? "/tmp/freely-shell-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ApplicationModel()
        var profile = UserProfile(name: "Engineering")
        profile.role = "Software engineer"; profile.projectContext = "A native macOS application"
        model.preferences.profiles = [profile]; model.preferences.selectedProfileID = profile.id
        model.sessionNotes = "Discuss the cancellation contract."
        model.session = SessionViewState(phase: .running, sources: [.localUser: .running, .systemAudio: .paused])
        model.session.transcript = [TranscriptSegment(source: .systemAudio, sequence: 1, startTime: 61, endTime: 63, text: "How do you cancel in-flight work?")]
        let question = QuestionState(text: "How do you cancel in-flight work?")
        let identity = GenerationIdentity(sessionEpoch: SessionEpoch(1), questionID: question.id, questionRevision: 1)
        model.answerPresentation.begin(identity: identity, question: question)
        _ = model.answerPresentation.append("Cancel the owned task, invalidate its revision, then await completion before releasing resources.\n\n```swift\nlet current = task\ntask = nil\ncurrent?.cancel()\nawait current?.value\n```\n\nLate callbacks must check the current revision.", identity: identity)
        _ = model.answerPresentation.finish(identity: identity, lifecycle: .completed)
        let controller = ShellWindowController(model: model)
        defer { controller.dispose() }
        controller.show()
        for expanded in [false, true] {
            model.preferences.overlay.expanded = expanded; controller.updatePreferences()
            for section in AppSection.allCases {
                model.section = section
                try await Task.sleep(for: .milliseconds(80))
                let image = try #require(controller.snapshot())
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("\(section.id.replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-").lowercased())-\(expanded ? "expanded" : "compact").png"))
                #expect(image.width == (expanded ? 960 : 720) && image.height == (expanded ? 700 : 520))
            }
            func save(_ name: String) async throws {
                try await Task.sleep(for: .milliseconds(80))
                let image = try #require(controller.snapshot())
                #expect(image.width == (expanded ? 960 : 720) && image.height == (expanded ? 700 : 520))
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("\(name)-\(expanded ? "expanded" : "compact").png"))
            }
            model.section = .session
            model.preferences.overlay.textSize = 28
            try await save("large-text")
            model.preferences.overlay.textSize = 15
            model.shell.commandsVisible = true
            try await save("actions")
            model.shell.commandsVisible = false
            model.shell.choice = PanelChoiceState(title: "Profile", options: [.init(id: 0, title: "Engineering", selected: true, choose: {})])
            try await save("selection")
            model.shell.choice = nil
            model.shell.confirmation = .endSession
            try await save("end-session")
            model.shell.confirmation = nil
            model.errorMessage = "The selected audio source is unavailable. Choose it again in Audio & Speech."
            try await save("error")
            model.errorMessage = nil
            model.session.phase = .preparing; model.session.preparationStage = "Loading speech model for meeting audio"
            try await save("preparing")
            model.session.phase = .running; model.session.preparationStage = nil
            model.answerPresentation.begin(identity: identity, question: question)
            try await save("generating")
            _ = model.answerPresentation.append("An unfinished code block remains selectable.\n\n```swift\nTask {\n    await coordinator.stop()", identity: identity)
            try await save("incomplete-code")
            model.answerPresentation.pin()
            let next = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 2)
            model.answerPresentation.begin(identity: next, question: question)
            _ = model.answerPresentation.append("A replacement answer", identity: next)
            try await save("frozen-answer")
            model.answerPresentation.unpin()

        }
        await model.shutdown()
    }
}
