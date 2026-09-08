import AppKit
import SwiftUI

/// Native selectable text, incremental appends, and literal fenced code. No HTML or remote resources.
struct NativeAnswerView: NSViewRepresentable {
    let text: String
    let textSize: Double
    let interactive: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = interactive
        view.isRichText = false; view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        view.isSelectable = interactive
        let state = context.coordinator
        guard text != state.lastText || textSize != state.size else { return }
        let append = textSize == state.size && text.hasPrefix(state.lastText)
        let newText = append ? String(text.dropFirst(state.lastText.count)) : text
        storage.beginEditing()
        if !append { storage.setAttributedString(NSAttributedString()); state.inCode = false; state.lineStart = 0 }
        let start = storage.length
        storage.append(NSAttributedString(string: newText, attributes: [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor.labelColor]))
        let ns = storage.string as NSString
        var lineStart = state.lineStart
        while lineStart < storage.length {
            let range = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: range)
            let fence = line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: state.inCode || fence ? NSFont.monospacedSystemFont(ofSize: max(11, textSize - 1), weight: .regular) : NSFont.systemFont(ofSize: textSize),
                .foregroundColor: fence ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]
            storage.addAttributes(attributes, range: range)
            if line.hasSuffix("\n") {
                if fence { state.inCode.toggle() }
                lineStart = NSMaxRange(range)
            } else { break }
        }
        state.lineStart = lineStart
        storage.endEditing()
        if start == 0 { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        state.lastText = text; state.size = textSize
    }
    final class Coordinator {
        var lastText = ""
        var size = 0.0
        var inCode = false
        var lineStart = 0
    }
}
