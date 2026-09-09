import AppKit

/// Local-only sibling of the transparent content host. Never included in panelImage.
@MainActor final class PanelBackdrop: NSView {
    nonisolated static let graphite = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    let blur = NSVisualEffectView()
    private let shade = NSView()
    private let dots = PanelBackdropDots()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        for view in [blur, shade, dots] {
            view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
        }
        shade.wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    func update(translucent: Bool, reduceTransparency: Bool, hiddenInPresentation: Bool = false) {
        let glass = translucent && !reduceTransparency
        blur.isHidden = !glass
        shade.layer?.backgroundColor = Self.graphite.withAlphaComponent(glass ? 0.75 : 1).cgColor
        dots.isHidden = !hiddenInPresentation
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A quiet local visibility cue, kept outside the content captured for presentation.
@MainActor private final class PanelBackdropDots: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setFill()
        let path = NSBezierPath()
        for y in stride(from: 6.0, to: bounds.height, by: 12) {
            for x in stride(from: 6.0, to: bounds.width, by: 12) {
                path.appendOval(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
            }
        }
        path.fill()
    }
}
