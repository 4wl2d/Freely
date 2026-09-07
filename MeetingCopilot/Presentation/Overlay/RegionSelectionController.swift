import AppKit

@MainActor
final class RegionSelectionController {
    private var panel: RegionPanel?
    private var completion: ((CGRect?) -> Void)?
    func select(displayID: UInt32, completion: @escaping (CGRect?) -> Void) {
        finish(nil)
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else {
            completion(nil); return
        }
        self.completion = completion
        let window = RegionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isReleasedWhenClosed = false
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect) }
        window.contentView = view
        panel = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }
    private func finish(_ rect: CGRect?) {
        if panel != nil { NSCursor.pop() }
        panel?.orderOut(nil); panel = nil
        let callback = completion; completion = nil
        callback?(rect)
    }
}
@MainActor private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
@MainActor private final class RegionSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onFinish: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var selection: CGRect?
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
            width: abs(origin.x - point.x), height: abs(origin.y - point.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selection, selection.width >= 8, selection.height >= 8 else { onFinish?(nil); return }
        onFinish?(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill(); bounds.fill()
        if let selection {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.systemTeal.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 3; path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        let text = "Drag a readable region · Esc cancels"
        let rect = CGRect(x: 24, y: 24, width: 390, height: 48)
        NSColor.black.withAlphaComponent(0.72).setFill(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: 38, y: 36), withAttributes: attributes)
    }
}
