import AppKit
import SwiftUI

@main
enum FreelyApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var shell: ShellWindowController?
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
        let controller = ShellWindowController(model: model)
        shell = controller
        model.toggleOverlay = { [weak controller] in controller?.toggle() }
        model.updateOverlay = { [weak controller] in controller?.updatePreferences() }
        model.focusQuestion = { [weak controller] in controller?.focusQuestion() }
        model.chooseRegion = { [weak self] displayID, completion in
            guard let self, let source = model.visualSources.first(where: { $0.kind == .display && $0.nativeID == displayID }) else { completion(nil); return }
            model.shell.region = RegionEditorState(source: source, initial: model.visualRegion, completion: completion)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Freely")
        item.button?.toolTip = "Show / hide Freely"
        item.button?.target = self; item.button?.action = #selector(togglePanel)
        statusItem = item
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
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.model.pauseForSystemEvent() }
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshDevices() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshDevices() }
        })
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        for (title, selector, key) in [("Settings", #selector(showSettings), ","), ("Hide Freely", #selector(hidePanel), "w"), ("Quit Freely", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        NSApp.mainMenu = menu
        model.initialize()
        controller.show()
        if CommandLine.arguments.contains("--diagnostics") { model.section = .diagnostics }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell?.show()
        return false
    }
    @objc private func togglePanel() { shell?.toggle() }
    @objc private func hidePanel() { shell?.hide() }
    @objc private func showSettings() { model.section = .settings; shell?.show() }
    @objc private func quit() { NSApp.terminate(nil) }
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
        shell?.dispose()
        signalSource?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
    }
}
