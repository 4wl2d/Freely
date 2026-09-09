import AppKit
import ColorSync
import SwiftUI

@MainActor
final class ShellPanel: NSPanel {
    var onInteraction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onInteraction?() }
        super.sendEvent(event)
    }
}

@MainActor
final class ShellWindowController: NSObject, NSWindowDelegate {
    let panel: ShellPanel
    let model: ApplicationModel
    private var previousFrontmost: NSRunningApplication?
    private var updatingGeometry = false
    private var restoredLoadedPreferences = false
    private var lastExpanded: Bool?
    private var displayObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var accessibilityObserver: NSObjectProtocol?
    let backdrop = PanelBackdrop()
    private(set) var contentHost: NSHostingView<ShellView>!

    init(model: ApplicationModel) {
        self.model = model
        panel = ShellPanel(contentRect: CGRect(origin: .zero, size: ShellGeometry.compact),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Freely"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: CGRect(origin: .zero, size: ShellGeometry.compact))
        backdrop.frame = container.bounds; backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        let hosting = NSHostingView(rootView: ShellView(model: model))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.frame = container.bounds; hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting); contentHost = hosting
        panel.contentView = container
        model.dialogs.window = panel
        model.shell.window = panel
        model.presentation.panelImage = { [weak self] in self?.snapshot() }
        panel.onInteraction = { [weak self] in self?.interact() }
        model.shell.onPopupOpened = panel.onInteraction
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 360, y: screen.visibleFrame.midY - 260))
        }
        updatePreferences()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePreferences() }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreGeometry() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self.map { $0.handle(event) == nil } ?? false }
            return consumed ? nil : event
        }
    }
    func toggle() { panel.isVisible ? hide() : show() }
    func show() {
        rememberFrontmost()
        panel.orderFrontRegardless()
        model.overlayVisible = true
        model.presentation.setPanelVisible(true)
        FreelyLog.record(.overlayVisibility, fields: [.enabled: .flag(true)])
    }
    func hide() {
        model.presentation.setPanelVisible(false)
        model.cancelPanelTransientWork()
        let hadFocus = panel.isKeyWindow || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        FreelyLog.record(.overlayVisibility, fields: [.enabled: .flag(false)])
        panel.orderOut(nil); model.overlayVisible = false; model.interactive = false
        if hadFocus, let previousFrontmost, !previousFrontmost.isTerminated { previousFrontmost.activate(options: []) }
    }
    func focusQuestion() {
        model.dialogs.cancel(); model.shell.dismissTransient(); model.showClearConfirmation = false
        model.section = .session
        show(); interact()
        model.shell.focusRequest &+= 1
    }
    private func rememberFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousFrontmost = app }
    }
    private func interact() {
        rememberFrontmost()
        model.interactive = true
        FreelyLog.record(.overlayInteraction, fields: [.enabled: .flag(true)])
        // Nonactivating panel obtains keyboard focus only following an explicit interaction.
        panel.makeKey()
    }
    func windowDidResignKey(_ notification: Notification) { model.interactive = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if model.preferences.panel.positionLocked && !updatingGeometry { return sender.frame.size }
        guard let screen = panel.screen ?? NSScreen.main else { return frameSize }
        return ShellGeometry.clamped(CGRect(origin: panel.frame.origin, size: frameSize), to: screen.visibleFrame).size
    }
    func updatePreferences() {
        backdrop.update(translucent: model.preferences.panel.translucentBackground,
                        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                        hiddenInPresentation: !model.presentation.showPanel)
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        let unlocked = !model.preferences.panel.positionLocked
        if panel.isMovable != unlocked { panel.isMovable = unlocked }
        if panel.styleMask.contains(.resizable) != unlocked {
            if unlocked { panel.styleMask.insert(.resizable) } else { panel.styleMask.remove(.resizable) }
        }
        // AppKit recreates titlebar controls after a style-mask change.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        if lastExpanded != model.expanded || (model.ready && !restoredLoadedPreferences) {
            restoreGeometry(); restoredLoadedPreferences = model.ready
        }
    }
    func restoreGeometry() {
        var destination = panel.screen ?? NSScreen.main
        if model.ready && !restoredLoadedPreferences {
            let preferences = model.preferences.panel
            if let uuid = preferences.lastDisplayUUID {
                destination = NSScreen.screens.first { Self.displayUUID($0) == uuid.lowercased() } ?? destination
            } else if let id = preferences.lastDisplayID ?? preferences.geometries.last?.displayID {
                destination = NSScreen.screens.first { Self.displayID($0) == id } ?? destination
            }
        }
        guard let screen = destination else { return }
        let id = Self.displayID(screen)
        let saved = model.preferences.panel.geometry(displayID: id, displayUUID: Self.displayUUID(screen), expanded: model.expanded)
        let size = model.expanded ? ShellGeometry.expanded : ShellGeometry.compact
        let frame = saved.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        updatingGeometry = true
        panel.minSize = CGSize(width: min(600, screen.visibleFrame.width), height: min(420, screen.visibleFrame.height))
        panel.maxSize = screen.visibleFrame.size
        panel.setFrame(ShellGeometry.clamped(frame, to: screen.visibleFrame), display: true)
        lastExpanded = model.expanded
        updatingGeometry = false
    }
    private func saveGeometry() {
        guard !updatingGeometry, let screen = panel.screen else { return }
        let rect = panel.frame
        let geometry = PanelGeometry(displayID: Self.displayID(screen), expanded: model.expanded,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, displayUUID: Self.displayUUID(screen))
        var preferences = model.preferences.panel
        preferences.geometries.removeAll { $0.expanded == geometry.expanded && ($0.id == geometry.id || ($0.displayUUID == nil && $0.displayID == geometry.displayID)) }
        preferences.geometries.append(geometry)
        if preferences.geometries.count > 32 { preferences.geometries.removeFirst() }
        preferences.lastDisplayID = geometry.displayID; preferences.lastDisplayUUID = geometry.displayUUID
        model.preferences.panel = preferences
    }
    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID(screen))?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, uuid) as String).lowercased()
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel || event.window?.sheetParent === panel else { return event }
        if event.type == .rightMouseDown {
            guard !model.shell.hasTransient else { return nil }
            if let text = panel.firstResponder as? NSTextView {
                let range = text.selectedRange()
                if range.length > 0, NSMaxRange(range) <= (text.string as NSString).length {
                    let selected = (text.string as NSString).substring(with: range)
                    model.shell.choice = PanelChoiceState(title: "Selected text", options: [
                        .init(id: 0, title: "Copy selection", selected: false, choose: {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected, forType: .string)
                        })
                    ])
                }
            }
            return nil
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Physical positions match Freely global shortcuts across input layouts.
        let key = event.keyCode
        if flags == .command && key == 13 { hide(); return nil }
        guard model.dialogs.active == nil else { return event }
        if event.keyCode == 53 {
            if model.showClearConfirmation { model.showClearConfirmation = false }
            else if !model.shell.back() { hide() }
            return nil
        }
        if model.shell.choice != nil || model.shell.commandsVisible {
            if flags == .command && key == 40 {
                _ = model.shell.back(); return nil
            }
            if flags.isEmpty && [125, 126, 36, 76].contains(event.keyCode) {
                // Preserve IME composition in the focused search field.
                if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                model.handlePopupKey(event.keyCode); return nil
            }
            // Native text editing stays in the popup; section shortcuts cannot escape it.
            if flags.contains(.command) && ![0, 8, 9, 7, 6].contains(key) { return nil }
            return event
        }
        if model.shell.hasTransient || model.showClearConfirmation { return event }
        if flags == .command {
            switch key {
            case 40: model.shell.commandsVisible.toggle(); return nil
            case 43: model.section = .settings; return nil
            case 33: if !model.shell.back() { hide() }; return nil
            default: break
            }
        }
        if flags == [.command, .shift] && key == 8 { model.copyAnswer(); return nil }
        return event
    }
    /// AppKit caching includes embedded NSTextView glyphs; SwiftUI ImageRenderer does not.
    func snapshot() -> CGImage? {
        guard panel.isVisible, let view = contentHost else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height), bitsPerComponent: 8,
                  bytesPerRow: Int(view.bounds.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(PanelBackdrop.graphite.cgColor)
        context.fill(view.bounds)
        context.draw(image, in: view.bounds)
        return context.makeImage()
    }
    func dispose() {
        hide()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }; displayObserver = nil
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }; accessibilityObserver = nil
        model.presentation.panelImage = nil
        model.shell.window = nil
        model.shell.onPopupOpened = nil
        panel.delegate = nil; panel.contentView = nil; panel.close()
    }
}

/// Dragging is restricted to the empty header area, never text or controls.
struct HeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if window?.isMovable == true { window?.performDrag(with: event) }
        }
    }
}
