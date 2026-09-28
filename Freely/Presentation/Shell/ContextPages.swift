import AppKit
import FreelyCore
import SwiftUI

struct TranscriptPage: View {
    @Bindable var model: ApplicationModel
    @State private var following = true
    private var excerpt: String { TranscriptExcerpt.body(segments: model.session.transcript, gaps: model.session.gaps) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeAnswerView(text: excerpt.isEmpty ? "Waiting for speech. Start a session to transcribe your selected sources." : excerpt,
                textSize: model.textSize, interactive: true, followLatest: $following)
            if !following { Button("Jump to latest") { following = true } }
            if model.session.contextLimited || model.session.gapCount > 0 {
                Text("\(model.session.gapCount) audio gaps · older context may be compacted. This is a retained excerpt.").font(.caption).foregroundStyle(.orange)
            }
        }.padding(20)
    }
}

struct ScreenContextPage: View {
    @Bindable var model: ApplicationModel
    @State private var preview: CGImage?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Images may be sent to Grok only with the mode and source you choose for this session. Presentation has its own source and controls.").foregroundStyle(.secondary)
                PanelPicker("Mode", selection: $model.screenMode, options: ScreenContextMode.allCases.map { ($0.rawValue, $0) }).disabled(!model.running)
                PanelPicker("Source", selection: $model.selectedVisualID, options: [("Choose a window or display", "")] + model.visualSources.map { ($0.name, $0.id) }).disabled(model.screenMode == .off)
                HStack {
                    Button("Refresh sources") { Task { await model.refreshVisualSources() } }.disabled(!model.running || model.screenMode == .off)
                    Button("Local preview") { loadPreview() }.disabled(model.selectedVisual == nil)
                    Button(model.visualRegion == nil ? "Select region" : "Change region") { model.selectRegion() }.disabled(model.selectedVisual?.kind != .display)
                    if model.visualRegion != nil { Button("Use full display") { model.visualRegion = nil } }
                }
                if let preview { Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 240) }
                if let previewError { Text(previewError).foregroundStyle(.orange) }
                if let region = model.visualRegion { Text("Region: \(Int(region.width)) × \(Int(region.height)) pt at \(Int(region.minX)), \(Int(region.minY))").font(.caption.monospacedDigit()) }
                Text("Viewing a preview does not send an image.").font(.caption).foregroundStyle(.secondary)
                Button("Capture and analyze") { model.answerNow(captureVisual: true) }.buttonStyle(.borderedProminent).tint(ShellTheme.button)
                    .disabled(!model.running || model.screenMode == .off || model.selectedVisual == nil || model.transcriptionOnly)
            }.padding(24)
        }
        .onChange(of: model.selectedVisualID) { _, _ in previewTask?.cancel(); preview = nil; previewError = nil }
        .onChange(of: model.screenMode) { _, mode in if mode == .off { previewTask?.cancel(); preview = nil } }
        .onChange(of: model.overlayVisible) { _, visible in if !visible { previewTask?.cancel() } }
    }
    private func loadPreview() {
        guard let source = model.selectedVisual else { return }
        previewTask?.cancel(); previewError = nil
        previewTask = Task {
            do {
                let image = try await NativeScreenCapture.localPreview(source)
                guard !Task.isCancelled, model.selectedVisualID == source.id, model.screenMode != .off else { return }
                preview = image
            } catch { if !Task.isCancelled { previewError = "Preview unavailable. Review permissions and select the source again." } }
        }
    }
}

struct PresentationPage: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        @Bindable var presentation = model.presentation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prepare the output, then select the Freely Presentation window in Meet, Zoom or Teams.").foregroundStyle(.secondary)
                PanelPicker("Source", selection: $presentation.sourceID, options: [("Choose a window or display", "")] + presentation.sources.map { ($0.name, $0.id) })
                HStack {
                    Button("Refresh sources") { Task { await presentation.refreshSources() } }
                    Button(presentation.previewLoading ? "Loading preview…" : "Local preview") { presentation.loadPreview() }.disabled(presentation.selectedSource == nil || presentation.previewLoading)
                    Button(presentation.region == nil ? "Select region" : "Change region") { selectRegion() }.disabled(presentation.selectedSource?.kind != .display)
                    if presentation.region != nil { Button("Use full display") { presentation.region = nil } }
                }
                if let preview = presentation.preview { Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 180) }
                Text(presentation.state).textSelection(.enabled)
                Toggle("Show Freely in presentation", isOn: Binding(get: { presentation.showPanel }, set: { presentation.setShowPanel($0) }))
                if presentation.window != nil { Text(presentation.visibilityStatus).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(presentation.preparing ? "Preparing…" : "Prepare presentation") { presentation.prepare() }
                        .buttonStyle(.borderedProminent).tint(ShellTheme.button).disabled(presentation.preview == nil || presentation.preparing)
                    if presentation.active || presentation.preparing { Button("Pause output") { presentation.suspend("Output paused. Check preview and prepare to resume.") } }
                    if presentation.window != nil { Button("Close output") { presentation.closeOutput() } }
                }
                DisclosureGroup("Advanced · output details") {
                Text("1920 × 1080 · up to 30 fps · no audio. This output does not send images to Grok. Status describes Freely's output; it does not confirm reception. Previously sent frames cannot be recalled.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
    }
    private func selectRegion() {
        guard let source = model.presentation.selectedSource else { return }
        let expected = model.presentation.revision.source
        model.shell.region = RegionEditorState(source: source, initial: model.presentation.region) { rect in
            guard let rect, expected == model.presentation.revision.source, source.id == model.presentation.sourceID else { return }
            model.presentation.region = rect
        }
    }
}
