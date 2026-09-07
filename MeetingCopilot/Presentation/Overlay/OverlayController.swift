import AppKit
import CopilotCore
import SwiftUI

@MainActor
final class CompanionPanel: NSPanel {
    var allowsInteraction = false
    override var canBecomeKey: Bool { allowsInteraction }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    let panel: CompanionPanel
    private let model: ApplicationModel
    private var previousFrontmost: NSRunningApplication?
    private var updatingPreferences = false
    init(model: ApplicationModel) {
        self.model = model
        panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 240)
        panel.maxSize = NSSize(width: 1_400, height: 1_200)
        // Best effort only; external full-display capture can still include the panel.
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: OverlayView(model: model, interaction: { [weak self] in self?.setInteractive($0) }))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 500, y: screen.visibleFrame.maxY - 350))
        }
    }
    func toggle() {
        if panel.isVisible { panel.orderOut(nil); model.overlayVisible = false; model.interactive = false }
        else { panel.orderFrontRegardless(); model.overlayVisible = true }
        CopilotLog.overlay.info("Overlay visibility changed; visible=\(self.panel.isVisible)")
    }
    func setInteractive(_ enabled: Bool) {
        CopilotLog.overlay.info("Explicit overlay interaction changed; interactive=\(enabled)")
        let wasKey = panel.isKeyWindow
        panel.allowsInteraction = enabled
        model.interactive = enabled
        if enabled {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousFrontmost = front }
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless(); model.overlayVisible = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
            panel.ignoresMouseEvents = model.clickThrough
            if wasKey, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               let previousFrontmost, !previousFrontmost.isTerminated {
                previousFrontmost.activate(options: [])
            }
            previousFrontmost = nil
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        panel.allowsInteraction = false; model.interactive = false
        panel.ignoresMouseEvents = model.clickThrough
    }
    func windowDidResize(_ notification: Notification) {
        guard !updatingPreferences else { return }
        model.preferences.overlay.width = panel.frame.width
        if !model.expanded { model.preferences.overlay.height = panel.frame.height }
        model.savePreferencesDebounced()
    }
    func updatePreferences() {
        updatingPreferences = true
        defer { updatingPreferences = false }
        panel.alphaValue = model.opacity
        panel.ignoresMouseEvents = model.clickThrough && !model.interactive
        let size = NSSize(width: max(360, model.preferences.overlay.width),
            height: model.expanded ? max(520, model.preferences.overlay.height) : max(240, model.preferences.overlay.height))
        if abs(panel.frame.width - size.width) > 1 || abs(panel.frame.height - size.height) > 1 {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
        // Settings and streamed presentation never call activate or makeKey here.
    }
}

private struct OverlayView: View {
    @Bindable var model: ApplicationModel
    let interaction: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("Drag to move")
                Text("MeetingCopilot").font(.caption.bold())
                Spacer()
                Button { model.setPinned(!model.pinned) } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }.help(model.pinned ? "Unpin answer" : "Freeze displayed answer")
                Button { interaction(!model.interactive) } label: { Image(systemName: model.interactive ? "checkmark" : "cursorarrow") }.help(model.interactive ? "Done interacting" : "Interact with text and question")
                Button { model.toggleOverlay?() } label: { Image(systemName: "eye.slash") }.help("Hide overlay")
            }.buttonStyle(.borderless)
            Text(model.question).font(.headline).lineLimit(model.expanded ? 5 : 2)
            NativeAnswerView(text: model.answer, textSize: model.textSize, interactive: model.interactive)
            if model.interactive {
                HStack {
                    TextField("Ask or correct a question", text: $model.typedQuestion).textFieldStyle(.roundedBorder)
                        .onSubmit { model.answerNow() }
                    Button("Ask") { model.answerNow() }
                }
            }
            if model.answerPresentation.newAnswerAvailable {
                Button("New answer available · unpin") { model.setPinned(false) }.font(.caption).buttonStyle(.plain).foregroundStyle(.teal)
            }
            HStack(spacing: 10) {
                Circle().fill(model.session.phase == .running ? Color.teal : Color.secondary).frame(width: 5, height: 5)
                Text(model.generationDiagnostics.status == "Idle" ? model.status : model.generationDiagnostics.status)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 2)
                Button("Copy") { model.copyAnswer() }
                Button("Clear") { model.clearAnswer() }
                Button(model.expanded ? "Compact" : "Expand") { model.toggleExpanded() }
            }.font(.caption).buttonStyle(.borderless)
            if model.screenMode != .off {
                Label("Screen context enabled for this session", systemImage: "rectangle.dashed").font(.caption2).foregroundStyle(.orange)
            }
        }.padding(16).padding(.top, 8).background(.regularMaterial)
    }
}
