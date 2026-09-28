import AppKit
import Observation

@MainActor @Observable
final class ShellState {
    private(set) var section = AppSection.setup
    private(set) var history: [AppSection] = []
    private(set) var visited: [AppSection] = [.setup]
    var choice: PanelChoiceState? {
        didSet {
            if choice !== oldValue {
                choiceSelection.selectedID = choice?.options.first(where: \.selected).map { String($0.id) }
                choiceSelection.reconcile(choice?.matching.map { String($0.id) } ?? [])
                if (choice == nil) != (oldValue == nil) { popupChanged("choice", opened: choice != nil) }
            }
        }
    }
    var commandsVisible = false {
        didSet { if commandsVisible != oldValue { popupChanged("actions", opened: commandsVisible) } }
    }
    var commandSearch = ""
    let actionSelection = PopupListSelection()
    let choiceSelection = PopupListSelection()
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onPopupOpened: (() -> Void)?
    @ObservationIgnored private var focusBookmarks: [String: FocusBookmark] = [:]
    @ObservationIgnored private var focusRevision = 0
    var confirmation: Confirmation?
    var focusRequest = 0
    var region: RegionEditorState?
    var hasTransient: Bool { commandsVisible || choice != nil || confirmation != nil || region != nil }
    enum Confirmation { case endSession, deleteProfile }

    @MainActor private final class FocusBookmark {
        weak var responder: NSResponder?
        let fieldSelection: NSRange?
        init(_ responder: NSResponder?) {
            if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSResponder {
                self.responder = owner
                fieldSelection = editor.selectedRange()
            } else { self.responder = responder; fieldSelection = nil }
        }
    }
    private func popupChanged(_ id: String, opened: Bool) {
        focusRevision &+= 1
        if opened {
            focusBookmarks[id] = FocusBookmark(window?.firstResponder)
            if window?.isVisible == true { onPopupOpened?() }
        } else {
            let bookmark = focusBookmarks.removeValue(forKey: id)
            let expected = focusRevision
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, expected == focusRevision, let window, window.isVisible,
                      confirmation == nil, region == nil,
                      let responder = bookmark?.responder else { return }
                if let view = responder as? NSView, view.isHiddenOrHasHiddenAncestor { return }
                if window.makeFirstResponder(responder), let selection = bookmark?.fieldSelection,
                   let editor = window.firstResponder as? NSTextView, NSMaxRange(selection) <= (editor.string as NSString).length {
                    editor.setSelectedRange(selection)
                }
            }
        }
    }

    func navigate(_ destination: AppSection) {
        commandsVisible = false; choice = nil
        guard destination != section else { return }
        history.append(section)
        if history.count > 50 { history.removeFirst() }
        section = destination
        if !visited.contains(destination) { visited.append(destination) }
    }
    func root(_ destination: AppSection) {
        navigate(destination); history.removeAll()
    }
    /// Returns false only at the root, where the window owner hides the panel.
    func back() -> Bool {
        if choice != nil { choice = nil; return true }
        if confirmation != nil { confirmation = nil; return true }
        if let region { region.cancel(); self.region = nil; return true }
        if commandsVisible { commandsVisible = false; return true }
        guard let previous = history.popLast() else { return false }
        section = previous
        return true
    }
    func dismissTransient() {
        commandsVisible = false; choice = nil; confirmation = nil
        region?.cancel(); region = nil
    }
}

/// Highlight is independent of a selector's committed value. Both popup types share it.
@MainActor @Observable
final class PopupListSelection {
    var selectedID: String?
    func reconcile(_ ids: [String]) {
        if !ids.contains(selectedID ?? "") { selectedID = ids.first }
    }
    func move(_ delta: Int, in ids: [String]) {
        reconcile(ids)
        guard let current = selectedID, let index = ids.firstIndex(of: current), !ids.isEmpty else { return }
        selectedID = ids[min(ids.count - 1, max(0, index + delta))]
    }
}

/// All native file sheets have one owner and one invalidation fence.
@MainActor
final class PanelDialogCoordinator {
    weak var window: NSWindow?
    var beforeSystemUI: (() -> Void)?
    private(set) var revision: UInt64 = 0
    private(set) var active: NSSavePanel?

    func present(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window, window.isVisible, active == nil else { completion(.cancel); return }
        beforeSystemUI?()
        revision &+= 1
        let expected = revision
        active = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { completion(.cancel); return }
            if self.active === panel { self.active = nil }
            completion(expected == self.revision && window.isVisible ? response : .cancel)
        }
    }
    func cancel() {
        revision &+= 1
        let panel = active; active = nil
        panel?.cancel(nil)
        if let panel, let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
    }
}

enum ShellGeometry {
    static let compact = CGSize(width: 720, height: 520)
    static let expanded = CGSize(width: 960, height: 700)
    static let minimum = CGSize(width: 600, height: 420)
    static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let size = CGSize(width: min(visible.width, max(minimum.width, frame.width)),
                          height: min(visible.height, max(minimum.height, frame.height)))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
    }
}
