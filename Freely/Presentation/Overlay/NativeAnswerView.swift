import AppKit
import SwiftUI

/// Native selectable text, incremental appends, and literal fenced code. No HTML or remote resources.
struct NativeAnswerView: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let text: String
    let textSize: Double
    let interactive: Bool
    var followLatest: Binding<Bool>? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = AnswerTextView()
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
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll, followLatest: followLatest)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        view.isSelectable = interactive
        (view as? AnswerTextView)?.keyboardActive = enabled
        let state = context.coordinator
        state.followLatest = followLatest
        if followLatest?.wrappedValue == true && !state.wasFollowing {
            view.scrollToEndOfDocument(nil)
        }
        state.wasFollowing = followLatest?.wrappedValue ?? false
        guard text != state.lastText || textSize != state.size else { return }
        state.updating = true
        defer { state.updating = false }
        let selection = view.selectedRanges
        // NSTextStorage's bridged NSString may change while storage is edited.
        // Use the prior model value so selection mapping sees an immutable old text.
        let oldString = state.lastText
        let oldVisible = scroll.contentView.bounds.origin
        let shouldFollow = followLatest?.wrappedValue == true
        let append = textSize == state.size && text.hasPrefix(state.lastText)
        let newText = append ? String(text.dropFirst(state.lastText.count)) : text
        storage.beginEditing()
        if !append { storage.setAttributedString(NSAttributedString()); state.inCode = false; state.lineStart = 0 }
        storage.append(NSAttributedString(string: newText, attributes: [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor(srgbRed: 230 / 255, green: 237 / 255, blue: 243 / 255, alpha: 1)]))
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
        if append {
            view.selectedRanges = selection
        } else {
            view.selectedRanges = selection.map { value in
                NSValue(range: NativeSelection.restoring(value.rangeValue, from: oldString, to: text))
            }
        }
        if shouldFollow && view.selectedRange().length == 0 { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: oldVisible); scroll.reflectScrolledClipView(scroll.contentView) }
        state.lastText = text; state.size = textSize
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.dispose() }
    @MainActor final class Coordinator {
        var followLatest: Binding<Bool>?
        var wasFollowing = true
        var updating = false
        var observer: NSObjectProtocol?
        func observe(_ scroll: NSScrollView, followLatest: Binding<Bool>?) {
            self.followLatest = followLatest
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll, !self.updating, let document = scroll.documentView else { return }
                    let latest = scroll.contentView.bounds.maxY >= document.bounds.maxY - 28
                    if self.followLatest?.wrappedValue != latest { self.followLatest?.wrappedValue = latest }
                }
            }
        }
        func dispose() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }

        var lastText = ""
        var size = 0.0
        var inCode = false
        var lineStart = 0
    }
}

final class AnswerTextView: NSTextView {
    var keyboardActive = true
    override var acceptsFirstResponder: Bool { keyboardActive && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { keyboardActive && super.becomeFirstResponder() }
}
