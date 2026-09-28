import AppKit
import SwiftUI

/// Hiding the native page removes its text controls from AppKit's key-view loop without
/// rebuilding them. SwiftUI opacity alone would leave invisible NSTextViews focusable.
struct RetainedPage<Content: View>: NSViewRepresentable {
    let active: Bool
    @ViewBuilder let content: Content
    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []; host.safeAreaRegions = []
        host.isHidden = !active
        return host
    }
    func updateNSView(_ host: NSHostingView<Content>, context: Context) {
        host.rootView = content
        if !active, let responder = host.window?.firstResponder as? NSView, responder.isDescendant(of: host) {
            host.window?.makeFirstResponder(nil)
        }
        host.isHidden = !active
    }
}
