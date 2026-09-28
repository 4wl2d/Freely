import AppKit
import FreelyCore
import Foundation
import Testing
@testable import Freely

@Suite(.serialized)
struct OverlayFocusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_FOCUS_TEST"] == "1", "Opt-in explicit question focus and hide"))
    @MainActor func explicitQuestionFocusSurvivesNavigationAndHide() async throws {
        let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let model = ApplicationModel()
        let controller = ShellWindowController(model: model)
        defer { controller.dispose() }
        model.typedQuestion = "A preserved draft"
        controller.focusQuestion()
        for _ in 0..<40 {
            if controller.panel.firstResponder is QuestionTextView { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.panel.isVisible && controller.panel.isKeyWindow)
        #expect(controller.panel.firstResponder is QuestionTextView)
        #expect(model.preferences.panel.positionLocked)
        controller.hide()
        #expect(!controller.panel.isVisible)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == initial)
        controller.show()
        #expect(model.typedQuestion == "A preserved draft")
        #expect(!controller.panel.isKeyWindow)
        await model.shutdown()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_FOCUS_TEST"] == "1", "Opt-in live desktop NSPanel focus verification"))
    @MainActor func passiveStreamDoesNotActivateTheApplication() async throws {
        let initial = try #require(NSWorkspace.shared.frontmostApplication)
        let process = ProcessInfo.processInfo.processIdentifier
        guard initial.processIdentifier != process else {
            Issue.record("Focus test requires another application to be frontmost at entry")
            return
        }
        let model = ApplicationModel()
        let controller = ShellWindowController(model: model)
        let question = QuestionState(text: "Focus verification fixture")
        let identity = GenerationIdentity(sessionEpoch: SessionEpoch(1), questionID: question.id, questionRevision: 1)
        model.answerPresentation.begin(identity: identity, question: question)
        var activatedSelf = false
        var panelBecameKey = false
        var otherFocusChanges = 0
        var previousPID = initial.processIdentifier
        controller.toggle()
        defer { controller.dispose() }
        for index in 0..<100 {
            _ = model.answerPresentation.append(index == 0 ? "This is a local focus test. " : "A streamed text update. ", identity: identity)
            try await Task.sleep(for: .milliseconds(40))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == process { activatedSelf = true }
            if controller.panel.isKeyWindow { panelBecameKey = true }
            if let front, front != previousPID, front != process { otherFocusChanges += 1; previousPID = front }
        }
        _ = model.answerPresentation.finish(identity: identity, lifecycle: .completed)
        let result: [String: Any] = [
            "schemaVersion": 1,
            "kind": "real NSPanel + SwiftUI/native text rendering; local stream fixture; no inference",
            "date": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "streamUpdates": 100, "cadenceMilliseconds": 40,
            "frontmostAtStart": initial.bundleIdentifier ?? "unknown",
            "activatedSelf": activatedSelf, "panelBecameKey": panelBecameKey,
            "otherObservedFocusChanges": otherFocusChanges,
            "panelVisible": controller.panel.isVisible,
            "passed": !activatedSelf && !panelBecameKey,
            "limits": "Test process hosts the production panel/controller; not a live Grok request, fullscreen, Spaces or capture-visibility test."
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Benchmarks/results")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("shell-passive-focus.json"), options: .atomic)
        #expect(controller.panel.isVisible)
        #expect(!activatedSelf)
        #expect(!panelBecameKey)
        await model.shutdown()
    }
}
