import AppKit
import SwiftUI
import Testing
@testable import Freely

@MainActor struct NativeAnswerLayoutTests {
    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let result = textView(in: child) { return result } }
        return nil
    }
    private func renderedText(_ host: NSHostingView<NativeAnswerView>) async throws -> NSTextView {
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if let text = textView(in: host), !text.string.isEmpty { return text }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try #require(textView(in: host))
    }
    @Test func nativeTextLaysOutAndKeepsIncrementalCodeFencesReadable() async throws {
        let initial = "A concise answer.\n```swift\nlet value = 1"
        let host = NSHostingView(rootView: NativeAnswerView(text: initial, textSize: 15, interactive: true))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Kept hidden; no activation or synthetic keystrokes.
        let text = try await renderedText(host)
        let container = try #require(text.textContainer), manager = try #require(text.layoutManager)
        manager.ensureLayout(for: container)
        #expect(text.string == initial)
        #expect(text.bounds.width > 100)
        #expect(manager.usedRect(for: container).height > 20)
        #expect(text.isSelectable && !text.isEditable && !text.importsGraphics)
        let updated = initial + "\nlet next = 2\n```\nDone"
        host.rootView = NativeAnswerView(text: updated, textSize: 15, interactive: true)
        for _ in 0..<50 { host.layoutSubtreeIfNeeded(); if text.string == updated { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(text.string == updated)
        let storage = try #require(text.textStorage)
        let codeRange = (updated as NSString).range(of: "let next")
        let proseRange = (updated as NSString).range(of: "Done")
        let codeFont = try #require(storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        let proseFont = try #require(storage.attribute(.font, at: proseRange.location, effectiveRange: nil) as? NSFont)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(!proseFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        window.contentView = nil
    }
}
