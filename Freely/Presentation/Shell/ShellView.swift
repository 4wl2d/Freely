import AppKit
import FreelyCore
import SwiftUI

// Fixed semantic colors, independent of the macOS appearance.
enum ShellTheme {
    static let background = Color(nsColor: PanelBackdrop.graphite)
    static let surface = Color(red: 0.15, green: 0.15, blue: 0.16)
    static let border = Color.white.opacity(0.12)
    static let text = Color(red: 230 / 255, green: 237 / 255, blue: 243 / 255)
    static let accent = Color(red: 68 / 255, green: 147 / 255, blue: 248 / 255)
    static let button = Color(red: 31 / 255, green: 111 / 255, blue: 235 / 255)
}

struct ShellView: View {
    @Bindable var model: ApplicationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if model.section != .session { header.disabled(model.shell.hasTransient || model.showClearConfirmation); line }
            ZStack {
                VStack(spacing: 0) {
                    if model.section != .session && model.errorMessage != nil {
                        ShellErrorBanner(model: model).disabled(model.shell.hasTransient || model.showClearConfirmation)
                        line
                    }
                    // Visited screens stay mounted to preserve scroll, native selection and drafts.
                    GeometryReader { geometry in
                        ZStack {
                            ForEach(model.shell.visited) { section in
                                RetainedPage(active: model.section == section) {
                                    content(section)
                                        .disabled(model.shell.hasTransient || model.showClearConfirmation)
                                        .environment(model.shell)
                                        .preferredColorScheme(.dark)
                                        .font(.system(size: 13))
                                        .foregroundStyle(ShellTheme.text)
                                        .tint(ShellTheme.accent)
                                        .buttonStyle(.borderless)
                                }.frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
                if let region = model.shell.region { RegionEditorView(editor: region) { model.shell.region = nil } }
                if model.shell.confirmation != nil || model.showClearConfirmation { confirmation }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            line
            footer.disabled(model.shell.hasTransient || model.showClearConfirmation)
        }
        .font(.system(size: 13))
        .foregroundStyle(ShellTheme.text).tint(ShellTheme.accent)
        .buttonStyle(.borderless)
        .overlay {
            if model.shell.commandsVisible || model.shell.choice != nil {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { _ = model.shell.back() }
                        Group {
                            if let choice = model.shell.choice {
                                PanelChoiceView(choice: choice, selection: model.shell.choiceSelection) { model.shell.choice = nil }
                            } else { PanelActionsView(model: model) }
                        }
                        .frame(width: min(340, max(0, geometry.size.width - 24)), height: min(360, max(0, geometry.size.height - 64)))
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(PanelBorder(hiddenInPresentation: !model.presentation.showPanel, cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                        .padding(.trailing, 12).padding(.bottom, 48)
                    }
                }
            }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(PanelBorder(hiddenInPresentation: !model.presentation.showPanel, cornerRadius: 14))
        .preferredColorScheme(.dark)
        .environment(model.shell)
        .onChange(of: model.preferences.panel) { _, _ in model.updateOverlay?() }
        .onChange(of: model.presentation.showPanel) { _, _ in model.updateOverlay?() }
    }
    private var line: some View { PanelDivider(hiddenInPresentation: !model.presentation.showPanel) }
    private var header: some View {
        HStack(spacing: 12) {
            Button { if !model.shell.back() { model.toggleOverlay?() } } label: { Image(systemName: "chevron.left") }
                .help("Back · ⌘[").accessibilityLabel("Back")
            Text(model.section.rawValue).fontWeight(.medium).lineLimit(1)
            HeaderDragArea().frame(minWidth: 10, maxWidth: .infinity, minHeight: 24)
        }.padding(.horizontal, 16).frame(height: 48)
    }
    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .setup: ReadinessView(model: model)
        case .session: AnswerPage(model: model)
        case .transcript: TranscriptPage(model: model)
        case .context: ContextSettingsView(model: model)
        case .screen: ScreenContextPage(model: model)
        case .presentation: PresentationPage(model: model)
        case .settings: settings
        case .ai: AISettingsView(model: model)
        case .audio: AudioSettingsView(model: model)
        case .answers: AnswerSettingsView(model: model)
        case .profiles: ContextSettingsView(model: model, showSessionFields: false)
        case .overlay: OverlaySettingsView(model: model)
        case .privacy: PrivacySettingsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
    }
    private var settings: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach([AppSection.ai, .audio, .answers, .profiles, .overlay, .privacy]) { section in
                    Button { model.section = section } label: {
                        HStack { Label(section.rawValue, systemImage: section.icon); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 15)
                    }
                    line
                }
            }.padding(.horizontal, 24)
        }
    }
    private var footer: some View {
        HStack(spacing: 14) {
            Text(footerStatus).foregroundStyle(.secondary).lineLimit(1).help(footerStatus)
            HeaderDragArea().frame(minWidth: 4, maxWidth: .infinity, minHeight: 24)
            Button("Copy") { model.copyAnswer() }.disabled(model.answerPresentation.displayed?.text.isEmpty != false)
                .help("Copy answer · ⌘⇧C")
            Button("Actions ⌘K") { model.shell.commandsVisible.toggle() }.accessibilityLabel("Actions")
        }.font(.system(size: 12)).padding(.horizontal, 16).frame(height: 40)
    }
    private var footerStatus: String {
        if model.answerPresentation.newAnswerAvailable { return "Frozen · New answer available" }
        if model.preparing { return model.status }
        if model.running {
            let mic = compactSourceLabel(model.session.sources[.localUser] ?? .stopped)
            let meeting = compactSourceLabel(model.session.sources[.systemAudio] ?? .stopped)
            return "\(model.answerStateLabel) · Mic \(mic) · Audio \(meeting)"
        }
        return model.canStart ? "Ready to start" : "Capture is off"
    }
    private func compactSourceLabel(_ state: SourceStatus) -> String {
        switch state {
        case .running: "on"
        case .paused: "paused"
        case .preparing: "preparing"
        case .failed: "unavailable"
        case .stopped: "off"
        }
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text(model.showClearConfirmation ? "Clear local data?" : model.shell.confirmation == .deleteProfile ? "Delete selected profile?" : "End session?").font(.title3.weight(.semibold))
            Text(model.showClearConfirmation ? (model.clearModels ? "Settings, profiles, credentials and the installed speech model will be removed." : "Settings, profiles and credentials will be removed. The speech model will be kept.") : model.shell.confirmation == .deleteProfile ? "The selected saved profile will be removed. Imported source files are preserved." : "Capture and generation will stop. The retained transcript, answers, screen context and session notes will be cleared. Presentation will show a neutral frame.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.showClearConfirmation = false; model.shell.confirmation = nil }
                Spacer()
                Button(model.showClearConfirmation ? "Clear local data" : model.shell.confirmation == .deleteProfile ? "Delete profile" : "End session", role: .destructive) {
                    if model.showClearConfirmation { model.showClearConfirmation = false; Task { await model.clearLocalData() } }
                    else if model.shell.confirmation == .deleteProfile { model.shell.confirmation = nil; model.removeSelectedProfile() }
                    else { model.shell.confirmation = nil; Task { await model.stop() } }
                }.buttonStyle(.borderedProminent).tint(.red)
            }
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(ShellTheme.background)
    }
}

struct ShellErrorBanner: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.callout).textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 0)
                if let recovery = model.errorRecoverySection { Button("Review settings") { model.section = recovery } }
                Button("Details") { model.section = .diagnostics }
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
            }.padding(12).background(ShellTheme.surface)
        }
    }
}

// Kept as a source-compatible harness entry point for the existing integration soak.
struct SetupView: View {
    let model: ApplicationModel
    var body: some View { ShellView(model: model) }
}

struct ReadinessView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.preferences.onboardingCompleted ? "Ready for a meeting" : "Set up Freely").font(.system(size: 20, weight: .semibold))
                VStack(spacing: 0) {
                    row("Audio & permissions", detail: model.audioSelectionReady && model.capturePermissionsReady ? "Selected sources are ready" : "Choose sources and review macOS permissions", done: model.audioSelectionReady && model.capturePermissionsReady, section: .audio)
                    row("Local speech model", detail: model.modelReady ? "Installed and verified" : model.modelProgress.phase, done: model.modelReady, section: .audio)
                    row("Grok connection", detail: model.transcriptionOnly ? "Transcription only" : model.connectionReady ? "Connected" : "Connect your subscription or API key", done: model.connectionReady || model.transcriptionOnly, section: .ai)
                }
                Toggle("Transcription only", isOn: $model.transcriptionOnly).disabled(model.running || model.preparing)
                PanelPicker("Profile", selection: $model.preferences.selectedProfileID,
                    options: [("None", Optional<UUID>.none)] + model.preferences.profiles.map { ($0.name, Optional($0.id)) })
                HStack {
                    Text(model.transcriptionOnly ? "Answers off" : "\(model.preferences.ai.answerLanguage) · \(model.preferences.ai.answerStyle.rawValue)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Answer settings") { model.section = .answers }
                }
                if let requirement = model.startRequirement { Text(requirement).font(.caption).foregroundStyle(.secondary) }
                Button("Start session") { model.preferences.onboardingCompleted = true; model.start() }
                    .buttonStyle(.borderedProminent).tint(ShellTheme.button).disabled(!model.canStart)
            }.padding(24)
        }
    }
    private func row(_ title: String, detail: String, done: Bool, section: AppSection) -> some View {
        Button { model.section = section } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark" : "circle").foregroundStyle(done ? ShellTheme.accent : .secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.vertical, 12).overlay(alignment: .bottom) { PanelDivider(hiddenInPresentation: !model.presentation.showPanel) }
        }.buttonStyle(.plain)
    }
}

struct AnswerPage: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestionInput(text: $model.typedQuestion, focusRequest: model.shell.focusRequest,
                active: model.section == .session && model.overlayVisible && !model.shell.hasTransient,
                currentQuestion: model.answerPresentation.displayed?.question.text ?? model.session.lastQuestion?.text) { model.answerNow() }
                .frame(height: 60).padding(.horizontal, 16).padding(.top, 6)
            PanelDivider(hiddenInPresentation: !model.presentation.showPanel)
            ShellErrorBanner(model: model)
            NativeAnswerView(text: model.answerPresentation.displayed?.text ?? (model.running ? "Waiting for a question. Type above or use the current conversation." : "Start a session when your sources are ready."), textSize: model.textSize, interactive: true)
                .padding(.horizontal, 20).padding(.vertical, 12)
            if let error = model.answerPresentation.displayed?.error {
                Text(error.userAction).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
    }
}
