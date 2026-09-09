import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class RegionEditorState {
    let source: VisualSource
    var image: CGImage?
    var selection: CGRect?
    var zoom = 1.0
    var message = "Loading local preview…"
    var loading = true
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var completion: ((CGRect?) -> Void)?
    init(source: VisualSource, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        self.source = source; selection = initial; self.completion = completion
        task = Task { [weak self] in
            do {
                // Local preview is independent of AI consent and never enters the provider pipeline.
                let image = try await NativeScreenCapture.localPreview(source)
                guard let self, !Task.isCancelled else { return }
                self.image = image; loading = false; message = "Drag a region, then confirm. Coordinates refer to the selected display."
            } catch { if !Task.isCancelled { self?.loading = false; self?.message = "Preview unavailable. Review capture permission and try again." } }
        }
    }
    func confirm() { finish(selection) }
    func cancel() { finish(nil) }
    private func finish(_ rect: CGRect?) {
        task?.cancel(); task = nil
        let callback = completion; completion = nil; callback?(rect)
    }
    static func map(_ rect: CGRect, previewSize: CGSize, sourceSize: CGSize) -> CGRect {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGRect(x: rect.minX / previewSize.width * sourceSize.width, y: rect.minY / previewSize.height * sourceSize.height,
            width: rect.width / previewSize.width * sourceSize.width, height: rect.height / previewSize.height * sourceSize.height)
            .intersection(CGRect(origin: .zero, size: sourceSize))
    }
}

struct RegionEditorView: View {
    @Bindable var editor: RegionEditorState
    let dismiss: () -> Void
    @State private var origin: CGPoint?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select region").font(.headline)
            Text(editor.source.name).font(.caption).lineLimit(1)
            HStack {
                Text("Preview zoom")
                Slider(value: $editor.zoom, in: 1...3).frame(maxWidth: 160)
                Text("\(Int(editor.zoom * 100))%").monospacedDigit()
            }
            GeometryReader { proxy in
                let fitted = PresentationCompositor.fit(CGSize(width: editor.source.width, height: editor.source.height), into: CGRect(origin: .zero, size: proxy.size)).size
                let size = CGSize(width: fitted.width * editor.zoom, height: fitted.height * editor.zoom)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        if let image = editor.image {
                            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                            if let selection = editor.selection {
                                Rectangle().stroke(ShellTheme.accent, lineWidth: 2)
                                    .background(ShellTheme.accent.opacity(0.12))
                                    .frame(width: selection.width / editor.source.width * size.width, height: selection.height / editor.source.height * size.height)
                                    .offset(x: selection.minX / editor.source.width * size.width, y: selection.minY / editor.source.height * size.height)
                            }
                        } else if editor.loading { ProgressView().frame(width: size.width, height: size.height) }
                        else { Text("Preview unavailable").foregroundStyle(.secondary).frame(width: size.width, height: size.height) }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let start = value.startLocation, end = value.location
                        editor.selection = RegionEditorState.map(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)), previewSize: size,
                            sourceSize: CGSize(width: editor.source.width, height: editor.source.height))
                    })
                    .accessibilityLabel("Local region preview. Use the coordinate fields below to select a region with the keyboard.")
                }
            }.frame(minHeight: 100)
            HStack {
                coordinate("X", \.origin.x); coordinate("Y", \.origin.y)
                coordinate("Width", \.size.width); coordinate("Height", \.size.height)
            }
            Text(editor.message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { editor.cancel(); dismiss() }
                Spacer()
                Button("Use region") { editor.confirm(); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(editor.image == nil || !NativeScreenCapture.validRegion(editor.selection ?? .zero, inside: CGRect(x: 0, y: 0, width: editor.source.width, height: editor.source.height)))
            }
        }.padding(20).background(ShellTheme.background)
    }
    private func coordinate(_ label: String, _ key: WritableKeyPath<CGRect, CGFloat>) -> some View {
        TextField(label, value: Binding(get: { Double((editor.selection ?? .zero)[keyPath: key]) }, set: { value in
            var rect = editor.selection ?? CGRect(x: 0, y: 0, width: editor.source.width, height: editor.source.height)
            rect[keyPath: key] = value; editor.selection = rect
        }), format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).accessibilityLabel(label)
    }
}
