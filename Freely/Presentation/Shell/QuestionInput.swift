import AppKit
import SwiftUI

struct QuestionInput: View {
    @Binding var text: String
    let focusRequest: Int
    let active: Bool
    var currentQuestion: String? = nil
    let submit: () -> Void
    var body: some View {
        NativeQuestionEditor(text: $text, focusRequest: focusRequest, active: active, currentQuestion: currentQuestion, submit: submit)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(currentQuestion ?? "Ask a question or follow up…")
                        .font(.system(size: 14)).foregroundStyle(currentQuestion == nil ? Color.secondary : ShellTheme.text)
                        .lineLimit(2).padding(.leading, 9).padding(.trailing, 16).padding(.top, 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

private struct NativeQuestionEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let active: Bool
    var currentQuestion: String? = nil
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let view = QuestionTextView()
        view.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 52)
        view.minSize = NSSize(width: 0, height: 52)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isRichText = false; view.importsGraphics = false
        view.drawsBackground = false; view.font = .systemFont(ofSize: 14)
        view.textColor = .init(srgbRed: 230 / 255, green: 237 / 255, blue: 243 / 255, alpha: 1)
        view.insertionPointColor = .white; view.textContainerInset = NSSize(width: 4, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Question or follow-up. Enter sends; Shift Enter inserts a line break.")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? QuestionTextView else { return }
        context.coordinator.parent = self
        view.submit = submit
        view.keyboardActive = active
        view.setAccessibilityHelp(currentQuestion.map { "Current question: \($0). Type a separate draft; incoming answers preserve your draft." } ?? "Enter sends. Shift Enter adds a line.")
        view.needsDisplay = true
        if view.string != text { view.string = text }
        if active && focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            let expected = focusRequest
            Task { @MainActor [weak view, weak coordinator = context.coordinator] in
                guard let coordinator, coordinator.parent.active, coordinator.parent.focusRequest == expected else { return }
                view?.window?.makeFirstResponder(view)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeQuestionEditor
        var focusRequest = 0
        init(_ parent: NativeQuestionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string; view.needsDisplay = true }
        }
    }
}

final class QuestionTextView: NSTextView {
    var submit: (() -> Void)?
    var keyboardActive = true
    override var acceptsFirstResponder: Bool { keyboardActive && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { keyboardActive && super.becomeFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) && !hasMarkedText() { submit?() }
        else { super.keyDown(with: event) }
    }
}
