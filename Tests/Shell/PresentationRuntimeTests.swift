import AppKit
import FreelyCore
import ScreenCaptureKit
import Testing
@testable import Freely

@MainActor struct PresentationRuntimeTests {
    private func wait(_ condition: () -> Bool, timeout: Double = 10) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        while !condition(), ProcessInfo.processInfo.systemUptime - start < timeout { try await Task.sleep(for: .milliseconds(40)) }
        #expect(condition())
    }
    private func capturePublishedWindow(_ output: PresentationCoordinator) async throws -> CGImage {
        let window = try #require(output.window)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let captured = try #require(content.windows.first { $0.windowID == UInt32(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = 1920; config.height = 1080
        config.captureDynamicRange = .SDR; config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false; config.captureMicrophone = false
        return try await PresentationCapture.firstFrame(filter: SCContentFilter(desktopIndependentWindow: captured), configuration: config)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_PRESENTATION_TEST"] == "1", "Opt-in ScreenCaptureKit + local public CaptureFixture window"))
    func nativeOutputExcludesMarkersAfterHideSourceChangeAndSystemPause() async throws {
        let model = ApplicationModel(presentation: PresentationCoordinator(outputMode: .previewWindow))
        let shell = ShellWindowController(model: model)
        defer { shell.dispose() }
        shell.show()
        let marker = MarkerView(frame: CGRect(x: 15, y: 100, width: 40, height: 40))
        shell.contentHost.addSubview(marker)
        let panel = try #require(shell.snapshot())
        #expect(PresentationCompositorTests.hasMagenta(panel))
        let output = model.presentation
        await output.refreshSources()
        let source = try #require(output.sources.first { $0.application == "local.freely.capture-fixture" && $0.name.contains("Freely capture fixture — public test content") })
        output.sourceID = source.id; output.loadPreview()
        try await wait { output.preview != nil }
        output.prepare()
        try await wait { output.active }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        output.setShowPanel(true)
        #expect(PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        let readback = try await capturePublishedWindow(output)
        try NSBitmapImageRep(cgImage: readback).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/freely-output-readback.png"))
        #expect(PresentationCompositorTests.hasMagenta(readback))
        #expect(output.window?.isKeyWindow == false && output.window?.canBecomeKey == false)
        // Check embedded NSTextView glyphs, independently of the rectangle marker.
        marker.isHidden = true
        model.section = .session
        let question = QuestionState(text: "Native glyph fixture")
        let identity = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 1)
        model.answerPresentation.begin(identity: identity, question: question)
        _ = model.answerPresentation.append("NATIVE ANSWER GLYPHS", identity: identity)
        func findText(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string == "NATIVE ANSWER GLYPHS" { return text }
            return view.subviews.compactMap { findText($0) }.first
        }
        try await wait { shell.panel.contentView.flatMap(findText) != nil }
        let text = try #require(shell.panel.contentView.flatMap(findText))
        text.textStorage?.addAttribute(.foregroundColor, value: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), range: NSRange(location: 0, length: (text.string as NSString).length))
        output.setShowPanel(false); output.setShowPanel(true)
        let localGlyphs = try #require(shell.snapshot())
        try NSBitmapImageRep(cgImage: localGlyphs).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/freely-panel-native-text.png"))
        let glyphReadback = try await capturePublishedWindow(output)
        try NSBitmapImageRep(cgImage: glyphReadback).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/freely-output-native-text.png"))
        // Antialiased glyphs are dimmer than a solid marker after window-server resampling.
        #expect(PresentationCompositorTests.hasMagenta(glyphReadback, minimumIntensity: 140))
        model.shell.commandsVisible = true
        try await Task.sleep(for: .milliseconds(150))
        output.setShowPanel(false); output.setShowPanel(true)
        let actionsReadback = try await capturePublishedWindow(output)
        #expect(actionsReadback.dataProvider?.data != glyphReadback.dataProvider?.data)
        #expect(PresentationCompositorTests.hasMagenta(actionsReadback, minimumIntensity: 140))
        let evidenceDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FREELY_SHELL_SNAPSHOT_DIR"] ?? "/tmp/freely-glass-snapshots")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: actionsReadback).representation(using: .png, properties: [:])?.write(to: evidenceDirectory.appendingPathComponent("presentation-actions-readback.png"))
        model.shell.commandsVisible = false
        shell.hide()
        let hiddenReadback = try await capturePublishedWindow(output)
        #expect(!PresentationCompositorTests.hasMagenta(hiddenReadback, minimumIntensity: 140))
        try NSBitmapImageRep(cgImage: hiddenReadback).representation(using: .png, properties: [:])?.write(to: evidenceDirectory.appendingPathComponent("presentation-hidden-readback.png"))
        shell.show()
        marker.isHidden = false
        for section in AppSection.allCases {
            model.section = section
            for _ in 0..<3 {
                shell.hide()
                #expect(output.publishedRevision == output.revision)
                #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
                shell.show()
                #expect(PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
            }
        }
        shell.hide()
        try await Task.sleep(for: .milliseconds(150))
        #expect(output.active)
        #expect(!PresentationCompositorTests.hasMagenta(try await capturePublishedWindow(output)))
        #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        // Display capture must also exclude the panel and output at the SCContentFilter boundary.
        if let display = output.sources.first(where: { $0.kind == .display }) {
            output.sourceID = display.id; output.loadPreview()
            try await wait { output.preview != nil }
            output.prepare(); try await wait { output.active }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
            shell.show(); output.setShowPanel(true)
            #expect(PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
            output.setShowPanel(false)
            try await Task.sleep(for: .milliseconds(150))
            #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        }
        output.sourceID = "missing-window"
        #expect(!output.active)
        let neutral = try #require(output.publishedFrame)
        #expect(!PresentationCompositorTests.hasMagenta(neutral))
        output.setShowPanel(true); shell.show(); output.suspend()
        #expect(!output.active && !output.preparing)
        #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        await model.stop()
        #expect(output.window != nil)
        output.closeOutput()
        #expect(output.window == nil)
        await model.shutdown()
    }
}

@MainActor private final class MarkerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill(); bounds.fill()
    }
}
