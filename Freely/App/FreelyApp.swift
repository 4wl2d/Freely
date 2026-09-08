import AppKit
import FreelyCore
import SwiftUI

@main
struct FreelyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SetupView(model: delegate.model) }
            .commands {
                CommandGroup(after: .appSettings) {
                    Button("Debug console…") { delegate.showDiagnostics() }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var diagnosticWindow: NSWindow?
    private var overlay: OverlayController?
    private let regionSelection = RegionSelectionController()
    private var signalSource: DispatchSourceSignal?
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var terminationReady = false
    private var terminationTask: Task<Void, Never>?
    let model = ApplicationModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FreelyLog.recorder.setVerbose(CommandLine.arguments.contains("--diagnostic-verbose"))
        FreelyLog.record(.appLaunched)
        NSApp.setActivationPolicy(.accessory)
        let controller = OverlayController(model: model)
        overlay = controller
        model.toggleOverlay = { [weak controller] in controller?.toggle() }
        model.updateOverlay = { [weak controller] in controller?.updatePreferences() }
        model.focusQuestion = { [weak controller] in controller?.setInteractive(true) }
        model.chooseRegion = { [weak self] display, completion in self?.regionSelection.select(displayID: display, completion: completion) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Freely")
        item.button?.toolTip = "Freely — session controls"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        statusItem = item
        model.sessionPresentationChanged = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        source.resume(); signalSource = source
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.model.pauseForSystemEvent() }
            })
        }
        // loginwindow's distributed lock notification supplements the documented workspace
        // sleep/session signals. It never resumes capture; physical OS-version coverage is
        // recorded separately because Apple does not document this notification name as an API contract.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.model.pauseForSystemEvent() }
            }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshDevices() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshDevices() }
        })
        model.initialize()
        showMainWindow()
        if CommandLine.arguments.contains("--diagnostics") { showDiagnostics() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        for source in AudioSource.allCases {
            let title = "\(source.label): \(sourceLabel(model.session.sources[source] ?? .stopped))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, model.running || model.preparing ? "End session" : "Start session", #selector(toggleSession))
        add(menu, "Pause / resume session", #selector(pauseSession))
        add(menu, "Pause / resume microphone", #selector(toggleMicrophone))
        add(menu, "Pause / resume system audio", #selector(toggleSystem))
        menu.addItem(.separator())
        add(menu, "Answer now", #selector(answerNow))
        add(menu, "Capture and analyze", #selector(analyzeScreen))
        add(menu, "Show / hide overlay", #selector(toggleOverlay))
        add(menu, "Interact with overlay", #selector(interact))
        add(menu, "Expand / collapse answer", #selector(expand))
        add(menu, "Copy answer", #selector(copyCurrentAnswer))
        add(menu, "Clear answer", #selector(clear))
        add(menu, model.pinned ? "Unpin answer" : "Pin answer", #selector(pin))
        menu.addItem(.separator())
        add(menu, "Open Freely…", #selector(showMainWindow))
        add(menu, "Debug console…", #selector(showDiagnostics))
        menu.items.last?.keyEquivalent = "d"
        menu.items.last?.keyEquivalentModifierMask = [.command, .option]
        add(menu, "Quit Freely", #selector(quit))
    }
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let microphone = model.session.sources[.localUser] ?? .stopped
        let system = model.session.sources[.systemAudio] ?? .stopped
        func mark(_ state: SourceStatus) -> String {
            switch state {
            case .running: "●"
            case .paused: "Ⅱ"
            case .preparing: "…"
            case .failed: "!"
            case .stopped: "○"
            }
        }
        button.title = " M\(mark(microphone)) S\(mark(system))"
        button.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        button.toolTip = "\(model.status)\nMicrophone: \(sourceLabel(microphone))\nMeeting audio: \(sourceLabel(system))"
        button.setAccessibilityLabel("Freely. Microphone \(sourceLabel(microphone)); meeting audio \(sourceLabel(system)).")
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
    @objc private func toggleSession() { if model.running || model.preparing { Task { await model.stop() } } else { model.start() } }
    @objc private func pauseSession() { model.pauseOrResume() }
    @objc private func toggleMicrophone() { model.toggleSource(.localUser) }
    @objc private func toggleSystem() { model.toggleSource(.systemAudio) }
    @objc private func answerNow() { model.answerNow() }
    @objc private func analyzeScreen() { model.answerNow(captureVisual: true) }
    @objc private func toggleOverlay() { model.toggleOverlay?() }
    @objc private func interact() { model.focusQuestion?() }
    @objc private func expand() { model.toggleExpanded() }
    @objc private func copyCurrentAnswer() { model.copyAnswer() }
    @objc private func clear() { model.clearAnswer() }
    @objc private func pin() { model.setPinned(!model.pinned) }
    @objc func showDiagnostics() {
        FreelyLog.record(.debugOpened)
        if diagnosticWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Freely — Debug console"
            panel.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
            panel.minSize = NSSize(width: 850, height: 620)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center(); diagnosticWindow = panel
        }
        diagnosticWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === diagnosticWindow {
            diagnosticWindow?.contentView = nil
            diagnosticWindow = nil
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc func showMainWindow() {
        if window == nil {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            newWindow.title = "Freely"
            newWindow.contentView = NSHostingView(rootView: SetupView(model: model))
            newWindow.minSize = NSSize(width: 880, height: 650)
            newWindow.isReleasedWhenClosed = false
            newWindow.center(); window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task { [weak self] in
                guard let self else { return }
                await model.shutdown()
                terminationReady = true
                // A fresh AppKit event avoids retaining a Swift MainActor job in AppKit's
                // nested terminateLater run loop while shutdown needs that same actor.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        signalSource?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
    }
}
