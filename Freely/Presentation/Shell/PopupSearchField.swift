import AppKit
import SwiftUI

/// SwiftUI FocusState does not reliably focus a field in a passive nonactivating NSPanel.
/// Focus the native field once it has joined the visible window, without activating NSApp.
struct PopupSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.textColor = .labelColor
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PopupSearchField
        init(_ parent: PopupSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() { parent.submit(); return true }
            return false
        }
    }
    final class SearchField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
