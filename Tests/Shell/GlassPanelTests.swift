import AppKit
import FreelyCore
import SwiftUI
import ScreenCaptureKit
import Testing
@testable import Freely

struct GlassPreferencesTests {
    @Test func oldV3DefaultsToGlassAndPreservesEveryOtherPreference() throws {
        var saved = AppPreferences()
        saved.panel.positionLocked = false
        saved.panel.geometries = [.init(displayID: 42, expanded: true, x: -950, y: 64, width: 930, height: 680)]
        saved.panel.lastDisplayID = 42
        saved.profiles = [UserProfile(name: "Existing profile")]; saved.selectedProfileID = saved.profiles[0].id
        saved.shortcuts[0].chord = .init(key: .k, modifiers: [.control, .shift])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var panel = try #require(json["panel"] as? [String: Any]); panel.removeValue(forKey: "translucentBackground"); json["panel"] = panel
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        #expect(restored == saved)
        #expect(restored.panel.translucentBackground)
        saved.panel.translucentBackground = false
        #expect(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(saved)) == saved)
    }
}

@MainActor struct PopupBehaviorTests {
    @Test func arrowsHighlightWithoutCommittingAndEscapeRestoresOldChoice() async {
        let model = ApplicationModel()
        var committed = 3
        func open() {
            model.shell.choice = PanelChoiceState(title: "Fixture", options: (0..<40).map { index in
                .init(id: index, title: "Value \(index)", selected: index == committed, choose: { committed = index })
            })
        }
        open()
        #expect(model.shell.choiceSelection.selectedID == "3")
        model.handlePopupKey(125); model.handlePopupKey(125)
        #expect(model.shell.choiceSelection.selectedID == "5")
        #expect(committed == 3)
        #expect(model.shell.back()); #expect(committed == 3)
        open(); model.handlePopupKey(126); model.handlePopupKey(36)
        #expect(committed == 2 && model.shell.choice == nil)
        open(); model.shell.choice?.search = "Value 39"; model.handlePopupKey(36)
        #expect(committed == 39)
        open(); model.shell.choice?.search = "no match"; model.handlePopupKey(36)
        #expect(committed == 39 && model.shell.choice != nil)
        await model.shutdown()
    }
    @Test func contextualActionsPrecedeNavigationAndDisabledEnterDoesNothing() async throws {
        let model = ApplicationModel()
        model.section = .session; model.shell.commandsVisible = true
        model.typedQuestion = "Keep this draft"
        #expect(model.panelActions.first?.id == "question")
        #expect(try #require(model.panelActions.firstIndex { $0.id == "freeze" }) < #require(model.panelActions.firstIndex { $0.section == "Go to" }))
        model.shell.commandSearch = "clipboard"
        model.handlePopupKey(36)
        #expect(model.shell.actionSelection.selectedID == "copy")
        #expect(model.shell.commandsVisible)
        #expect(model.matchingPanelActions.first?.unavailable != nil)
        model.shell.commandSearch = "geometry"; model.handlePopupKey(36)
        #expect(!model.preferences.panel.positionLocked && !model.shell.commandsVisible)
        #expect(model.typedQuestion == "Keep this draft")
        await model.shutdown()
    }
    @Test func failedSubmitAndIncomingAnswersNeverOverwriteDraft() async {
        let model = ApplicationModel()
        model.typedQuestion = "Draft 👋\nwith a second line"
        model.answerNow()
        #expect(model.typedQuestion == "Draft 👋\nwith a second line")
        let question = QuestionState(text: "Incoming spoken question")
        let identity = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 1)
        model.answerPresentation.begin(identity: identity, question: question)
        _ = model.answerPresentation.append("A streamed answer", identity: identity)
        model.section = .context; model.cancelPanelTransientWork(); _ = model.shell.back()
        #expect(model.typedQuestion == "Draft 👋\nwith a second line")
        #expect(model.question == "Incoming spoken question")
        await model.shutdown()
    }
    @Test func backdropUsesOpaqueFallbackWithoutFadingContent() async {
        let model = ApplicationModel()
        let controller = ShellWindowController(model: model)
        controller.backdrop.update(translucent: true, reduceTransparency: true)
        #expect(controller.backdrop.blur.isHidden)
        controller.backdrop.update(translucent: false, reduceTransparency: false)
        #expect(controller.backdrop.blur.isHidden)
        controller.backdrop.update(translucent: true, reduceTransparency: false)
        #expect(!controller.backdrop.blur.isHidden)
        #expect(controller.panel.alphaValue == 1)
        #expect(controller.contentHost.superview === controller.backdrop.superview)
        #expect(!controller.contentHost.isDescendant(of: controller.backdrop))
        controller.dispose(); await model.shutdown()
    }
}

@Suite(.serialized) @MainActor struct GlassNativeTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }
    private func key(_ controller: ShellWindowController, _ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        if let unhandled = controller.handle(event) { controller.panel.firstResponder?.keyDown(with: unhandled) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_TEST"] == "1", "Opt-in Actions focus from a passive window"))
    func openingActionsFromPassiveWindowAcquiresSearchFocus() async throws {
        let model = ApplicationModel(), shell: ShellWindowController
        shell = ShellWindowController(model: model)
        defer { shell.dispose() }
        shell.show()
        #expect(!shell.panel.isKeyWindow)
        model.shell.commandsVisible = true
        try await settle()
        #expect(shell.panel.isKeyWindow)
        #expect(model.interactive)
        #expect(shell.panel.firstResponder is NSTextView)
        #expect(!(shell.panel.firstResponder is QuestionTextView))
        #expect(!(shell.panel.firstResponder is AnswerTextView))
        let transparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(shell.backdrop.blur.isHidden == transparency)
        #expect(shell.panel.animationBehavior == (motion ? .none : .utilityWindow))
        #expect(shell.panel.alphaValue == 1)
        if let path = ProcessInfo.processInfo.environment["FREELY_ACCESSIBILITY_RESULT"] {
            let result: [String: Any] = ["reduceTransparency": transparency, "reduceMotion": motion,
                "nativeBlurHidden": shell.backdrop.blur.isHidden, "windowAnimationsDisabled": shell.panel.animationBehavior == .none,
                "windowAlpha": shell.panel.alphaValue, "nativeSearchFocused": shell.panel.firstResponder is NSTextView]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        await model.shutdown()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_TEST"] == "1", "Opt-in shared AppKit field-editor focus restoration"))
    func selectorRestoresTheOriginalFieldEditorOwnerAndSelection() async throws {
        let model = ApplicationModel(), shell: ShellWindowController
        shell = ShellWindowController(model: model)
        defer { shell.dispose() }
        shell.show(); shell.panel.makeKey()
        let field = NSTextField(frame: CGRect(x: 20, y: 100, width: 250, height: 24))
        field.stringValue = "A settings field draft"
        shell.contentHost.addSubview(field)
        shell.panel.makeFirstResponder(field)
        let editor = try #require(shell.panel.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 8))
        model.shell.choice = PanelChoiceState(title: "Example", options: [.init(id: 0, title: "Old value", selected: true, choose: {})])
        try await settle()
        let searchEditor = try #require(shell.panel.firstResponder as? NSTextView)
        #expect(searchEditor.delegate !== field)
        try key(shell, 53); try await settle()
        let restored = try #require(shell.panel.firstResponder as? NSTextView)
        #expect(restored.delegate === field)
        #expect(restored.selectedRange() == NSRange(location: 2, length: 8))
        #expect(field.stringValue == "A settings field draft")
        await model.shutdown()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_TEST"] == "1", "Opt-in native focus, editing, popups and retained selection"))
    func keyboardJourneyRetainsNativeViewsAndRestoresFocus() async throws {
        let model = ApplicationModel(), controller: ShellWindowController
        controller = ShellWindowController(model: model)
        defer { controller.dispose() }
        model.typedQuestion = "First draft"
        controller.focusQuestion(); try await settle()
        let editor = try #require(controller.panel.firstResponder as? QuestionTextView)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        try key(controller, 36, characters: "\r", flags: .shift)
        #expect(model.typedQuestion == "First\n draft")
        let draft = model.typedQuestion
        try key(controller, 36, characters: "\r")
        #expect(model.typedQuestion == draft)
        model.errorMessage = nil
        try key(controller, 40, characters: "л", flags: .command); try await settle()
        #expect(model.shell.commandsVisible)
        #expect(controller.panel.firstResponder !== editor)
        #expect(!editor.isHiddenOrHasHiddenAncestor && !editor.acceptsFirstResponder)
        model.shell.commandSearch = "geometry"; try await settle()
        try key(controller, 36, characters: "\r"); try await settle()
        #expect(!model.preferences.panel.positionLocked && !model.shell.commandsVisible)
        #expect(controller.panel.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        try key(controller, 40, characters: "л", flags: .command); try await settle()
        model.shell.commandSearch = ""; try await settle()
        try key(controller, 125); try await settle()
        #expect(model.shell.actionSelection.selectedID != model.matchingPanelActions.first?.id)
        let highlighted = model.shell.actionSelection.selectedID
        try key(controller, 43, characters: ",", flags: .command)
        #expect(model.section == .session)
        try key(controller, 53); try await settle()
        #expect(controller.panel.firstResponder === editor)
        try key(controller, 40, characters: "л", flags: .command); try await settle()
        #expect(model.shell.actionSelection.selectedID == highlighted)
        try key(controller, 53); try await settle()
        var committed = 4
        model.shell.choice = PanelChoiceState(title: "Choices", options: (0..<40).map { index in
            .init(id: index, title: "Choice \(index)", selected: index == committed, choose: { committed = index })
        }); try await settle()
        try key(controller, 125); #expect(committed == 4)
        try key(controller, 36); try await settle()
        #expect(committed == 5 && controller.panel.firstResponder === editor)
        try key(controller, 13, characters: "ц", flags: .command)
        #expect(!controller.panel.isVisible)
        controller.show(); try await settle()
        #expect(editor.string == draft)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        await model.shutdown()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_TEST"] == "1", "Opt-in long answer selection and scroll retention"))
    func longAnswerRetainsSelectionAndScrollAcrossNavigationHideAndReplacement() async throws {
        let model = ApplicationModel(), shell: ShellWindowController
        shell = ShellWindowController(model: model)
        defer { shell.dispose() }
        let question = QuestionState(text: "A long answer")
        let identity = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 1)
        let answer = (0..<100).map { "Paragraph \($0): a uniquely numbered line for native selection and scroll verification." }.joined(separator: "\n\n")
        model.answerPresentation.begin(identity: identity, question: question)
        _ = model.answerPresentation.append(answer, identity: identity)
        model.typedQuestion = "An unfinished follow-up"
        shell.focusQuestion(); try await settle()
        func find(_ view: NSView) -> AnswerTextView? {
            if let text = view as? AnswerTextView, text.string == answer { return text }
            return view.subviews.compactMap(find).first
        }
        let text = try #require(find(shell.contentHost))
        let range = (answer as NSString).range(of: "Paragraph 60")
        text.setSelectedRange(range); text.scrollRangeToVisible(range)
        shell.panel.makeFirstResponder(text)
        let scroll = try #require(text.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        try key(shell, 40, characters: "k", flags: .command); try await settle()
        #expect(!text.isHiddenOrHasHiddenAncestor && text.selectedRange() == range)
        try key(shell, 53); try await settle()
        #expect(shell.panel.firstResponder === text)
        model.section = .transcript; try await settle(); _ = model.shell.back(); try await settle()
        #expect(text.selectedRange() == range)
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        shell.hide()
        let replacement = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 2)
        model.answerPresentation.begin(identity: replacement, question: question)
        let updated = "Inserted preamble.\n\n" + answer
        _ = model.answerPresentation.append(updated, identity: replacement)
        try await settle(); shell.show(); try await settle()
        #expect(text.string == updated)
        #expect(text.selectedRange() == (updated as NSString).range(of: "Paragraph 60"))
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        #expect(model.typedQuestion == "An unfinished follow-up")
        await model.shutdown()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_TEST"] == "1", "Opt-in actual content snapshot isolation"))
    func snapshotExcludesLocalBackdropAndIncludesNativeAnswerAndActions() async throws {
        let model = ApplicationModel(), controller: ShellWindowController
        controller = ShellWindowController(model: model)
        defer { controller.dispose() }
        model.section = .session; controller.show(); try await settle()
        let beforeBackdrop = try #require(controller.snapshot())
        let desktopMarker = GlassMarker(frame: CGRect(x: 100, y: 100, width: 90, height: 90))
        controller.backdrop.addSubview(desktopMarker)
        let afterBackdrop = try #require(controller.snapshot())
        #expect(afterBackdrop.dataProvider?.data == beforeBackdrop.dataProvider?.data)
        #expect(!PresentationCompositorTests.hasMagenta(afterBackdrop))
        let interfaceMarker = GlassMarker(frame: CGRect(x: 220, y: 220, width: 90, height: 90))
        controller.contentHost.addSubview(interfaceMarker)
        #expect(PresentationCompositorTests.hasMagenta(try #require(controller.snapshot())))
        interfaceMarker.isHidden = true
        let baseline = try #require(controller.snapshot())
        model.shell.commandsVisible = true; try await settle()
        let actions = try #require(controller.snapshot())
        #expect(actions.dataProvider?.data != baseline.dataProvider?.data)
        #expect(!PresentationCompositorTests.hasMagenta(actions))
        #expect(actions.width == 720 && actions.height == 520)
        controller.hide(); #expect(controller.snapshot() == nil)
        await model.shutdown()
    }
}

@MainActor private final class GlassMarker: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill(); bounds.fill() }
}

@Suite(.serialized) @MainActor struct GlassDesktopCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GLASS_CAPTURE"] == "1", "Opt-in light/dark desktop and real window capture"))
    func localGlassChangesWithBackdropButPresentationSnapshotDoesNot() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FREELY_SHELL_SNAPSHOT_DIR"] ?? "/tmp/freely-glass-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ApplicationModel(), shell: ShellWindowController
        shell = ShellWindowController(model: model)
        let desktop = NSWindow(contentRect: try #require(NSScreen.main).frame, styleMask: [.borderless], backing: .buffered, defer: false)
        desktop.isReleasedWhenClosed = false
        desktop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        desktop.contentView = NSView(frame: desktop.frame)
        desktop.contentView?.wantsLayer = true
        defer { desktop.orderOut(nil); desktop.close(); shell.dispose() }
        let question = QuestionState(text: "How do you preserve a draft while answers stream?")
        let identity = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 1)
        model.answerPresentation.begin(identity: identity, question: question)
        _ = model.answerPresentation.append("Keep the editable draft separate from the current question.\n\nIncoming answers update the answer only. Esc closes Actions and restores the prior text selection.\n\n```swift\nlet draft = model.typedQuestion\nawait receiveAnswer()\nassert(model.typedQuestion == draft)\n```", identity: identity)
        _ = model.answerPresentation.finish(identity: identity, lifecycle: .completed)
        model.section = .session
        desktop.orderFrontRegardless(); shell.show()
        var localImages: [CGImage] = []
        for expanded in [false, true] {
            model.preferences.overlay.expanded = expanded; shell.updatePreferences()
            var snapshots: [Data] = []
            for light in [false, true] {
                desktop.contentView?.layer?.backgroundColor = (light ? NSColor.white : NSColor.black).cgColor
                shell.panel.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                let ui = try #require(shell.snapshot())
                snapshots.append(try #require(ui.dataProvider?.data) as Data)
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let window = try #require(content.windows.first { $0.windowID == UInt32(shell.panel.windowNumber) })
                let background = try #require(content.windows.first { $0.windowID == UInt32(desktop.windowNumber) })
                let display = try #require(content.displays.first { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) })
                _ = background // Confirms the opaque public backdrop is present before capturing only the panel rectangle.
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                config.width = expanded ? 960 : 720; config.height = expanded ? 700 : 520
                config.captureDynamicRange = .SDR; config.colorSpaceName = CGColorSpace.sRGB
                config.ignoreShadowsSingleWindow = true; config.capturesAudio = false; config.captureMicrophone = false
                let image = try await PresentationCapture.firstFrame(filter: filter, configuration: config)
                localImages.append(image)
                let suffix = "\(light ? "light" : "dark")-\(expanded ? "expanded" : "compact")"
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("desktop-\(suffix).png"))
                model.shell.commandsVisible = true
                try await Task.sleep(for: .milliseconds(150))
                let actions = try await PresentationCapture.firstFrame(filter: filter, configuration: config)
                try NSBitmapImageRep(cgImage: actions).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("desktop-actions-\(suffix).png"))
                model.shell.commandsVisible = false
            }
            #expect(snapshots[0] == snapshots[1], "Presentation snapshot must not depend on the local desktop")
        }
        let darkMean = interiorMean(localImages[0]), lightMean = interiorMean(localImages[1])
        let evidence: [String: Any] = [
            "kind": "ScreenCaptureKit display crop of production panel over public solid light/dark test windows",
            "date": ISO8601DateFormatter().string(from: Date()),
            "darkInteriorMean": darkMean, "lightInteriorMean": lightMean,
            "presentationContentIdenticalAcrossBackgrounds": true,
            "reduceTransparencyAtCapture": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "reduceMotionAtCapture": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("desktop-evidence.json"))
        #expect(lightMean - darkMean > 1, "Native glass interior must react to the changed desktop, excluding corners and shadows")
        await model.shutdown()
    }
    private func interiorMean(_ image: CGImage) -> Double {
        let rect = CGRect(x: 50, y: 330, width: 500, height: 60)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var total = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) { total += Double(data[(y * image.width + x) * 4]) } }
        return total / (rect.width * rect.height)
    }

}
