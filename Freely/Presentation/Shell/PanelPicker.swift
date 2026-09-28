import Observation
import SwiftUI

@MainActor @Observable
final class PanelChoiceState {
    struct Option: Identifiable {
        let id: Int
        let title: String
        let selected: Bool
        let choose: () -> Void
    }
    let title: String
    let options: [Option]
    var search = ""
    init(title: String, options: [Option]) { self.title = title; self.options = options }
    var matching: [Option] { options.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
}

/// Selectors use the shell's in-panel list, so no NSMenu window can survive Hide.
struct PanelPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @Environment(ShellState.self) private var shell
    init(_ title: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.title = title; _selection = selection; self.options = options
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                shell.choice = PanelChoiceState(title: title, options: options.enumerated().map { index, option in
                    .init(id: index, title: option.0, selected: option.1 == selection, choose: { selection = option.1 })
                })
            } label: {
                HStack(spacing: 6) {
                    Text(options.first { $0.1 == selection }?.0 ?? "Unavailable selection").lineLimit(2).multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
            }.accessibilityLabel(title).accessibilityValue(options.first { $0.1 == selection }?.0 ?? "Unavailable selection")
        }
    }
}

struct PanelChoiceView: View {
    @Bindable var choice: PanelChoiceState
    @Bindable var selection: PopupListSelection
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(choice.title).font(.headline); Spacer(); Button("Cancel", action: close) }.padding(12)
            PopupSearchField(text: $choice.search, placeholder: "Search options") { confirm() }
                .frame(height: 20).padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(choice.matching) { option in
                            optionRow(option)
                        }
                        if choice.matching.isEmpty { Text("No matching options").foregroundStyle(.secondary).padding(16) }
                    }.padding(6)
                }
                .onChange(of: selection.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onAppear { if let id = selection.selectedID { proxy.scrollTo(id, anchor: .center) } }
            }
            Divider()
            Text("↑↓ Select   ↵ Confirm   Esc Cancel").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
        }
        .onAppear { selection.reconcile(choice.matching.map { String($0.id) }) }
        .onChange(of: choice.matching.map(\.id)) { _, ids in selection.reconcile(ids.map(String.init)) }
    }
    private func optionRow(_ option: PanelChoiceState.Option) -> some View {
        let highlighted = selection.selectedID == String(option.id)
        return Button { selection.selectedID = String(option.id); confirm() } label: {
            HStack {
                Text(option.title).frame(maxWidth: .infinity, alignment: .leading)
                if option.selected { Image(systemName: "checkmark").foregroundStyle(ShellTheme.accent) }
            }.padding(10)
                .background(highlighted ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(String(option.id))
            .accessibilityAddTraits(highlighted ? [.isSelected] : [])
    }
    private func confirm() {
        guard let option = choice.matching.first(where: { String($0.id) == selection.selectedID }) else { return }
        close(); option.choose()
    }
}
