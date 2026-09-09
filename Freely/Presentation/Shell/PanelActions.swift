import AppKit
import FreelyCore
import SwiftUI

@MainActor struct PanelAction: Identifiable {
    let id: String
    let title: String
    var key = ""
    var keywords = ""
    var section = "Actions"
    var unavailable: String?
    let perform: () -> Void
}

extension ApplicationModel {
    var answerUnavailableReason: String? {
        if maintenanceBusy || isShuttingDown { return "Wait for the current operation to finish." }
        if preparing { return "Wait for session preparation." }
        if !running { return "Start a session first." }
        if session.phase == .paused { return "Resume the session first." }
        if transcriptionOnly { return "Answers are off in transcription-only mode." }
        if !connectionReady { return "Connect Grok in Connections." }
        return nil
    }
    var panelActions: [PanelAction] {
        let empty = answerPresentation.displayed?.text.isEmpty != false
        let answerActions: [PanelAction] = [
            .init(id: "question", title: "Focus question", keywords: "ask draft follow up", perform: { self.focusQuestion?() }),
            .init(id: "copy", title: "Copy answer", key: "⌘⇧C", keywords: "clipboard", unavailable: empty ? "No answer to copy yet." : nil, perform: { self.copyAnswer() }),
            .init(id: "detailed", title: "Detailed answer", keywords: "expand explain more", unavailable: answerUnavailableReason, perform: { self.answerNow(detailed: true) }),
            .init(id: "freeze", title: pinned ? "Unfreeze answer" : "Freeze answer", keywords: "pin hold new answer", unavailable: empty ? "No answer to freeze yet." : nil, perform: { self.setPinned(!self.pinned) }),
            .init(id: "clear", title: "Clear answer", keywords: "reset", unavailable: answerPresentation.displayed == nil ? "No answer to clear yet." : nil, perform: { self.clearAnswer() })
        ]
        var actions: [PanelAction] = []
        switch section {
        case .session:
            actions += answerActions
            if answerPresentation.displayed?.error != nil {
                actions.append(.init(id: "retry", title: "Retry answer", keywords: "error try again", unavailable: answerUnavailableReason, perform: { self.answerNow() }))
            }
        case .setup:
            actions.append(.init(id: "start", title: "Start session", keywords: "meeting begin", unavailable: canStart ? nil : startRequirement ?? "A session is already active.", perform: { self.preferences.onboardingCompleted = true; self.start() }))
        case .transcript:
            actions.append(.init(id: "export", title: "Export transcript excerpt", keywords: "save text", unavailable: session.transcript.isEmpty ? "No transcript to export yet." : nil, perform: { self.exportRetainedTranscript() }))
        case .context, .profiles:
            actions += [
                .init(id: "new-profile", title: "New profile", perform: { self.addProfile() }),
                .init(id: "import", title: "Import text / Markdown", unavailable: selectedProfileIndex == nil ? "Select a profile first." : nil, perform: { self.importProfile() }),
                .init(id: "delete-profile", title: "Delete selected profile…", unavailable: selectedProfileIndex == nil ? "Select a profile first." : nil, perform: { self.shell.confirmation = .deleteProfile })
            ]
        case .screen:
            actions.append(.init(id: "capture", title: "Capture and analyze", keywords: "screen image", unavailable: answerUnavailableReason ?? (screenMode == .off ? "Enable screen context for this session." : selectedVisual == nil ? "Select a visual source first." : nil), perform: { self.answerNow(captureVisual: true) }))
        case .presentation:
            actions += [
                .init(id: "prepare-output", title: "Prepare presentation", unavailable: presentation.preview == nil ? "Select a source and load its preview first." : presentation.preparing ? "Preparation is already in progress." : nil, perform: { self.presentation.prepare() }),
                .init(id: "pause-output", title: "Pause output", unavailable: !presentation.active && !presentation.preparing ? "Presentation is not running." : nil, perform: { self.presentation.suspend("Output paused. Check preview and prepare to resume.") }),
                .init(id: "close-output", title: "Close output", unavailable: presentation.window == nil ? "No output window is open." : nil, perform: { self.presentation.closeOutput() })
            ]
        default: break
        }
        for source in AudioSource.allCases {
            let paused = session.sources[source] != .running
            let name = source == .localUser ? "microphone" : "meeting audio"
            let enabled = source == .localUser ? preferences.audio.microphoneEnabled : preferences.audio.systemAudioEnabled
            actions.append(.init(id: "source-\(source.rawValue)", title: "\(paused ? "Resume" : "Pause") \(name)", keywords: "source mic speaker capture independent", unavailable: preparing ? "Wait for preparation." : !running ? "Start a session first." : !enabled ? "Enable this source in Audio & Speech before starting." : nil, perform: { self.toggleSource(source) }))
        }
        actions += [
            .init(id: "pause-all", title: session.phase == .paused ? "Resume all sources" : "Pause all sources", keywords: "audio capture", unavailable: !running ? "Start a session first." : nil, perform: { self.pauseOrResume() }),
            .init(id: "lock", title: preferences.panel.positionLocked ? "Unlock position" : "Lock position", keywords: "move resize geometry", perform: { self.preferences.panel.positionLocked.toggle() }),
            .init(id: "expand", title: expanded ? "Compact panel" : "Expand panel", keywords: "size window", perform: { self.toggleExpanded() }),
            .init(id: "show-output", title: presentation.showPanel ? "Hide Freely in presentation" : "Show Freely in presentation", keywords: "output share visibility", perform: { self.presentation.setShowPanel(!self.presentation.showPanel) }),
            .init(id: "end", title: preparing ? "Cancel preparation…" : "End session…", keywords: "stop meeting", unavailable: running || preparing ? nil : "No active session.", perform: { self.requestEndSession() })
        ]
        actions += [AppSection.session, .transcript, .context, .screen, .presentation, .settings, .diagnostics, .setup].map { destination in
            .init(id: "navigate-\(destination.id)", title: destination.rawValue, key: destination == .settings ? "⌘," : "", keywords: "open go \(destination == .setup ? "ready start" : "")", section: "Go to", perform: { self.section = destination })
        }
        actions.append(.init(id: "quit", title: "Quit Freely", key: "⌘Q", section: "Application", perform: { NSApp.terminate(nil) }))
        return actions
    }
    var matchingPanelActions: [PanelAction] {
        let terms = shell.commandSearch.split(whereSeparator: \.isWhitespace)
        return panelActions.filter { action in
            terms.allSatisfy { (action.title + " " + action.keywords).localizedCaseInsensitiveContains(String($0)) }
        }
    }
    func performPanelAction(_ id: String) {
        guard let action = matchingPanelActions.first(where: { $0.id == id }), action.unavailable == nil else { return }
        shell.commandsVisible = false
        action.perform()
    }
    func confirmChoice() {
        guard let choice = shell.choice, let option = choice.matching.first(where: { String($0.id) == shell.choiceSelection.selectedID }) else { return }
        shell.choice = nil
        option.choose()
    }
    func handlePopupKey(_ keyCode: UInt16) {
        if let choice = shell.choice {
            let ids = choice.matching.map { String($0.id) }
            shell.choiceSelection.reconcile(ids)
            if keyCode == 125 || keyCode == 126 { shell.choiceSelection.move(keyCode == 125 ? 1 : -1, in: ids) }
            else { confirmChoice() }
        } else if shell.commandsVisible {
            let ids = matchingPanelActions.map(\.id)
            shell.actionSelection.reconcile(ids)
            if keyCode == 125 || keyCode == 126 { shell.actionSelection.move(keyCode == 125 ? 1 : -1, in: ids) }
            else if let id = shell.actionSelection.selectedID { performPanelAction(id) }
        }
    }
}

struct PanelActionsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            PopupSearchField(text: Binding(get: { model.shell.commandSearch }, set: { model.shell.commandSearch = $0 }),
                placeholder: "Search actions…") { model.handlePopupKey(36) }
                .frame(height: 20).padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.matchingPanelActions.enumerated()), id: \.element.id) { index, action in
                            if index == 0 || model.matchingPanelActions[index - 1].section != action.section {
                                Text(action.section).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                            }
                            Button { model.performPanelAction(action.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text(action.title).foregroundStyle(action.unavailable == nil ? ShellTheme.text : Color.secondary); Spacer(minLength: 4); Text(action.key).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                    if let reason = action.unavailable { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.shell.actionSelection.selectedID == action.id ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(PopupRowButtonStyle()).disabled(action.unavailable != nil)
                                .accessibilityAddTraits(model.shell.actionSelection.selectedID == action.id ? [.isSelected] : [])
                                .id(action.id)
                        }
                        if model.matchingPanelActions.isEmpty { Text("No matching actions").foregroundStyle(.secondary).padding(16) }
                    }.padding(6)
                }
                .onChange(of: model.shell.actionSelection.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onAppear { if let id = model.shell.actionSelection.selectedID { proxy.scrollTo(id, anchor: .center) } }
            }
            Divider()
            HStack { Text("↑↓ Select   ↵ Run"); Spacer(); Text("Esc Close") }.font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
        }
        .onAppear { model.shell.actionSelection.reconcile(model.matchingPanelActions.map(\.id)) }
        .onChange(of: model.matchingPanelActions.map(\.id)) { _, ids in model.shell.actionSelection.reconcile(ids) }
    }
}

/// Keep the explanation readable even when an action is unavailable.
private struct PopupRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
