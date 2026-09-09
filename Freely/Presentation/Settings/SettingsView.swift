import AppKit
import AVFoundation
import FreelyCore
import SwiftUI

struct AISettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Connect Grok") {
                PanelPicker("Connection", selection: $model.preferences.connectionMethod, options: ConnectionMethod.allCases.map { ($0.rawValue, $0) }).pickerStyle(.segmented).disabled(model.running || model.preparing || model.subscriptionBusy || model.validatingAPI)
                if model.preferences.connectionMethod == .subscription {
                    HStack {
                        Button(model.subscriptionBusy ? "Connecting…" : "Connect Grok") { model.connectSubscription() }
                            .buttonStyle(.borderedProminent).disabled(model.subscriptionBusy || model.running || model.preparing || model.validatingAPI)
                        if model.subscriptionBusy {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.cancelSubscriptionConnection() }
                        }
                        if model.subscriptionConnected {
                            Button("Disconnect") { Task { await model.disconnectSubscription() } }.disabled(model.running || model.preparing)
                        }
                    }
                    Text(model.subscriptionStatus).font(.callout).foregroundStyle(model.subscriptionConnected ? Color.green : Color.primary).textSelection(.enabled)
                    if model.usesGrokBuild {
                        Text("Uses the official Grok Build client and your grok.com subscription. Connect runs a short test that may consume subscription usage. Freely does not read your password or tokens.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.grokBuild.needsInstall {
                            Button("Install Grok Build") { model.openExternal(URL(string: "https://docs.x.ai/build/overview")!) }
                            Text("Install the official client, then click Connect Grok again. No OAuth client ID is needed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Disconnect affects Freely only. Your other Grok Build sessions stay signed in.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Advanced: registered native OAuth integration") {
                        SettingsTextField("Registered Freely client ID", text: $model.preferences.subscriptionClientID)
                            .disabled(model.running || model.preparing || model.subscriptionBusy)
                        LabeledContent("Registered callback", value: "freely://oauth/callback")
                        Text("Leave this empty to use Grok Build. Only enter a client ID if xAI has registered a separate native Freely integration with this callback and inference access.").font(.caption).foregroundStyle(.secondary)
                        Button("xAI subscription integration information") { model.openExternal(URL(string: "https://x.ai/news/grok-opencode")!) }
                    }
                } else {
                    SecureField(model.hasAPIKey ? "Replace API key" : "API key", text: $model.apiKeyDraft)
                    HStack {
                        Button("Save in Keychain") { Task { await model.saveAPIKey() } }.disabled(model.apiKeyDraft.isEmpty || model.running || model.preparing)
                        Button("Remove key", role: .destructive) { Task { await model.deleteAPIKey() } }.disabled(!model.hasAPIKey || model.running || model.preparing)
                        Spacer()
                        Label(model.hasAPIKey ? "Key stored" : "No key configured", systemImage: model.hasAPIKey ? "key.fill" : "key")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Optional direct API connection. Use an official xAI API key with model access and API billing; this path does not automatically use your consumer subscription.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Test text streaming (may consume usage)") { model.validateAPI() }
                        .disabled(!model.connectionReady || model.validatingAPI || model.running || model.preparing)
                    if model.validatingAPI { ProgressView().controlSize(.small) }
                }
                Text(model.apiValidation).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
}

struct AnswerSettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Answers") {
                SettingsTextField("Answer language", text: $model.preferences.ai.answerLanguage)
                PanelPicker("Answer style", selection: $model.preferences.ai.answerStyle, options: AnswerStyle.allCases.map { ($0.rawValue.capitalized, $0) })
                Toggle("Automatically answer eligible meeting-audio questions", isOn: $model.preferences.ai.automaticAnswers)
                    .disabled(model.running || model.preparing)
                Toggle("Also allow local microphone speech to trigger answers", isOn: $model.preferences.ai.localSpeechTriggersAnswers)
                    .disabled(model.running || model.preparing)
                DisclosureGroup("Advanced") {
                SettingsTextField("Model", text: $model.preferences.ai.model).disabled(model.running || model.preparing || model.subscriptionBusy || model.validatingAPI)
                if model.usesGrokBuild, !model.grokBuild.availableModels.isEmpty {
                    Text("Available: " + model.grokBuild.availableModels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                PanelPicker("Reasoning effort", selection: $model.preferences.ai.reasoningEffort, options: XAIReasoningEffort.allCases.map { ($0.rawValue.capitalized, $0) }).disabled(model.running || model.preparing)
                Text("Low still performs reasoning. End the session to change the model, request limits or automatic-answer behavior.").font(.caption).foregroundStyle(.secondary)
                Stepper("Maximum request starts per minute: \(model.preferences.ai.requestsPerMinute)", value: $model.preferences.ai.requestsPerMinute, in: 1...120)
                    .disabled(model.running || model.preparing)
                if !model.usesGrokBuild {
                Stepper("Normal output token cap: \(model.preferences.ai.normalOutputTokens)", value: $model.preferences.ai.normalOutputTokens, in: 256...32_768, step: 256)
                    .disabled(model.running || model.preparing)
                Stepper("Detailed output token cap: \(model.preferences.ai.detailedOutputTokens)", value: $model.preferences.ai.detailedOutputTokens, in: 256...32_768, step: 256)
                    .disabled(model.running || model.preparing)
                } else {
                    Text("Grok Build manages its output token budget. Freely limits each received answer to 128 KiB and cancels requests when you end the session.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Answers, retries and summaries share the request cap. Cancelled requests may still incur provider charges. No cost estimate is shown without current authoritative pricing.").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Advanced · experimental") {
                Toggle("Speculative prefix answers", isOn: $model.preferences.ai.experimentalSpeculation)
                    .disabled(model.running || model.preparing)
                Text("Disabled by default. Experimental results are reported separately; ordinary answers do not require speculation.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
}

struct AudioSettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Microphone") {
                Toggle("Capture the local microphone", isOn: $model.preferences.audio.microphoneEnabled)
                    .disabled(model.running || model.preparing)
                PanelPicker("Device", selection: $model.preferences.audio.microphoneDeviceUID, options: [("Follow system default", Optional<String>.none)] + model.microphones.map { ($0.name, Optional($0.id)) }).disabled(model.preparing || model.session.sources[.localUser] == .running || model.session.sources[.localUser] == .preparing)
                HStack {
                    Text("Permission: \(microphoneLabel(model.microphonePermission))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Request access") { Task { await model.requestMicrophone() } }
                    Button("System Settings") { model.openPermissions(microphone: true) }
                }
                Button("Refresh devices") { model.refreshDevices() }
                Text("Pause the microphone to change its device.").font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection("Meeting audio") {
                Toggle("Capture meeting application audio", isOn: $model.preferences.audio.systemAudioEnabled)
                    .disabled(model.running || model.preparing)
                PanelPicker("Scope", selection: $model.preferences.audio.systemScope, options: [("Selected application", .application), ("All system audio", .allSystemAudio)]).disabled(model.preparing || model.session.sources[.systemAudio] == .running || model.session.sources[.systemAudio] == .preparing)
                if model.preferences.audio.systemScope == .application {
                    PanelPicker("Application", selection: $model.preferences.audio.applicationBundleID, options: [("Choose a meeting application", Optional<String>.none)] + model.applications.filter { !$0.bundleID.isEmpty }.map { ($0.name, Optional($0.bundleID)) }).disabled(model.preparing || model.session.sources[.systemAudio] == .running || model.session.sources[.systemAudio] == .preparing)
                }
                HStack {
                    Button("Refresh applications") { Task { await model.refreshApplications() } }
                    Button("Capture permissions") { model.openPermissions() }
                }
                Text(model.systemPermissionStatus).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced · capture scope") {
                Text("Application scope includes all its capturable audio. Selecting a browser does not isolate one tab. This app's own audio is excluded. A missing application never falls back to system-wide capture.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pause the source before changing capture scope. Resume explicitly to capture the new selection.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSection("Local speech model") {
                DisclosureGroup("Advanced · speech model") {
                LabeledContent("Engine", value: "FluidAudio / Parakeet TDT v3")
                LabeledContent("Speech language", value: "English (v1)")
                Text("Pinned FluidAudio default model variant · downloaded separately from the app").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: model.modelProgress.fraction)
                Text("\(model.modelProgress.phase) · \(ByteCountFormatter.string(fromByteCount: model.modelProgress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.modelProgress.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button(model.modelReady ? "Repair model" : "Download and verify model") { model.installModel() }
                        .disabled(model.modelInstalling || model.running || model.preparing)
                    if model.modelInstalling { Button("Cancel download") { model.cancelModelInstall() } }
                    Button("Run local sanity check") { Task { await model.sanityCheck() } }.disabled(!model.modelReady || model.modelInstalling || model.sanityChecking || model.running || model.preparing)
                }
                Text(model.localSanity).font(.caption).foregroundStyle(.secondary)
                Text("Model changes are available after the meeting.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
            .task { await model.refreshApplications() }
    }
}

struct ContextSettingsView: View {
    @Bindable var model: ApplicationModel
    var showSessionFields = true
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Reusable context · saved locally") {
                PanelPicker("Active profile", selection: $model.preferences.selectedProfileID, options: [("None — do not send a profile", Optional<UUID>.none)] + model.preferences.profiles.map { ($0.name, Optional($0.id)) })
                HStack {
                    Button("New profile") { model.addProfile() }
                    Button("Import text / Markdown") { model.importProfile() }.disabled(model.selectedProfileIndex == nil)
                    Button("Delete selected", role: .destructive) { model.shell.confirmation = .deleteProfile }.disabled(model.selectedProfileIndex == nil)
                }
                Text("Only the selected profile is used. Profiles are stored locally as plaintext.").font(.caption).foregroundStyle(.secondary)
                if let index = model.selectedProfileIndex {
                    SettingsTextField("Profile name", text: $model.preferences.profiles[index].name)
                    SettingsTextField("Role", text: $model.preferences.profiles[index].role)
                    SettingsTextField("Professional background", text: $model.preferences.profiles[index].professionalBackground, axis: .vertical).lineLimit(2...5)
                    SettingsTextField("Technology stack", text: $model.preferences.profiles[index].technologyStack, axis: .vertical).lineLimit(2...4)
                    SettingsTextField("Project context", text: $model.preferences.profiles[index].projectContext, axis: .vertical).lineLimit(2...5)
                    SettingsTextField("Answer preferences", text: $model.preferences.profiles[index].answerPreferences, axis: .vertical).lineLimit(2...4)
                    SettingsTextField("Vocabulary / technical terms", text: $model.preferences.profiles[index].vocabulary, axis: .vertical).lineLimit(2...4)
                    Text("Vocabulary informs answer context. This STT adapter does not apply vocabulary bias or rewrite recognized words.").font(.caption).foregroundStyle(.secondary)
                    SettingsTextField("Custom instructions", text: $model.preferences.profiles[index].customInstructions, axis: .vertical).lineLimit(2...5)
                    DisclosureGroup("Imported context") {
                        TextEditor(text: $model.preferences.profiles[index].importedContext).frame(minHeight: 120)
                    }
                }
            }
            if showSessionFields { SettingsSection("Current session only · cleared when it ends") {
                SettingsTextField("Session notes", text: $model.sessionNotes, axis: .vertical).lineLimit(3...8)
                SettingsTextField("Pinned facts", text: $model.pinnedFacts, axis: .vertical).lineLimit(2...5)
                Text("Actual conversation and prior AI suggestions keep separate provenance. The app does not invent professional experience or achievements.").font(.caption).foregroundStyle(.secondary)
            } }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
}

struct OverlaySettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Panel") {
                Stepper("Answer text size: \(Int(model.preferences.overlay.textSize)) pt", value: $model.preferences.overlay.textSize, in: 11...32)
                Toggle("Translucent background", isOn: $model.preferences.panel.translucentBackground)
                Toggle("Lock position", isOn: $model.preferences.panel.positionLocked)
                Button(model.expanded ? "Use compact size" : "Use expanded size") { model.toggleExpanded() }
                Text("Lock prevents moving and resizing. Freeze holds the answer.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced · previous overlay preferences") {
                    Slider(value: $model.preferences.overlay.opacity, in: 0.35...1) { Text("Legacy opacity") }
                    Toggle("Legacy click through", isOn: $model.preferences.overlay.clickThrough)
                    Toggle("Legacy show on session start", isOn: $model.preferences.overlay.initiallyVisible)
                    Text("Retained for migration. The panel accepts clicks and opens only when you call it. Reduce Transparency uses an opaque background; Reduce Motion disables transitions.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSection("Global shortcuts") {
                Text("No Accessibility permission is required. Shortcuts use physical key positions; the labels below follow US positions. Menu alternatives remain available for conflicts.").font(.caption).foregroundStyle(.secondary)
                ForEach($model.preferences.shortcuts) { $binding in
                    ShortcutRow(binding: $binding, status: model.hotkeyStatuses[binding.action] ?? .disabled)
                }
                HStack {
                    Button("Apply shortcuts") { model.applyShortcuts() }
                    Button("Restore defaults") { model.preferences.shortcuts = ShortcutBinding.defaults; model.applyShortcuts() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
}
private struct ShortcutRow: View {
    @Binding var binding: ShortcutBinding
    let status: HotkeyRegistrationStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(binding.action.title).frame(width: 170, alignment: .leading)
                Toggle("On", isOn: Binding(get: { binding.chord != nil }, set: { binding.chord = $0 ? ShortcutChord(key: .space, modifiers: [.command, .control, .option]) : nil })).labelsHidden()
                if binding.chord != nil {
                    PanelPicker("Key", selection: Binding(get: { binding.chord?.keyCode ?? 49 }, set: { binding.chord?.keyCode = $0 }), options: ShortcutKey.allCases.map { ($0.label, $0.rawValue) }).frame(width: 95)
                    modifier("⌃", .control); modifier("⌥", .option); modifier("⇧", .shift); modifier("⌘", .command)
                }
            }
            Text(status.message).font(.caption2).foregroundStyle(status == .registered ? Color.secondary : Color.orange)
        }
    }
    private func modifier(_ label: String, _ value: ShortcutModifiers) -> some View {
        Toggle(label, isOn: Binding(get: { binding.chord?.modifiers.contains(value) == true }, set: { enabled in
            if enabled { binding.chord?.modifiers.insert(value) } else { binding.chord?.modifiers.remove(value) }
        })).toggleStyle(.button)
    }
}

struct PrivacySettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Where data goes") {
                Label("Microphone and system audio are processed locally and never saved or uploaded.", systemImage: "waveform")
                Label("Selected transcript context, profile excerpts and questions go to the official xAI API.", systemImage: "network")
                Label("Images are sent only with explicit session consent and a selected visual source.", systemImage: "rectangle.dashed")
                Label("No automatic meeting history. Ending a session clears volatile meeting data.", systemImage: "clock.arrow.circlepath")
                Text("Requests set store:false and use bounded client-side context. This does not promise zero provider retention; consult xAI's current data policy and your account agreement. No model tools, browsing, shell or computer-control capabilities are enabled.").font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection("Presentation") {
                Text("Prepare a source in Presentation, then share the Freely Presentation window in your meeting app. Show Freely in presentation controls the interface layer in that output.")
                Text("Sharing a screen directly in another app is outside this output. Freely reports its own published frames; it cannot confirm what a recipient receives or recall frames already sent.").font(.caption).foregroundStyle(.secondary)
                Button("Open Presentation") { model.section = .presentation }
            }
            SettingsSection("Clear local data") {
                Toggle("Also remove the installed speech model", isOn: $model.clearModels)
                Button("Clear settings, profiles and Keychain credential…", role: .destructive) { model.showClearConfirmation = true }
                    .disabled(model.running || model.preparing)
                Text("Previously exported, backed-up or transmitted data cannot be recalled. This is not a forensic erasure guarantee.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
}

struct DiagnosticsOverview: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Session") {
                LabeledContent("State", value: model.status)
                LabeledContent("Session ID", value: model.session.sessionID?.uuidString ?? "No active session").textSelection(.enabled)
                LabeledContent("Owned session tasks", value: model.diagnosticState["ownedSessionTasks"]?.text ?? "0")
                LabeledContent("Retained transcript", value: "\(model.session.transcript.count) segments")
                LabeledContent("Explicit audio gaps", value: "\(model.session.gapCount)")
                LabeledContent("Summary coverage", value: model.session.summaryCoverage)
                LabeledContent("Last teardown", value: duration(model.session.teardownSeconds))
            }
            ForEach(AudioSource.allCases, id: \.self) { source in
                SettingsSection(source.label) {
                    let metrics = model.session.metrics[source]
                    LabeledContent("Source state", value: sourceLabel(model.session.sources[source] ?? .stopped))
                    LabeledContent("Native sample rate", value: metrics.map { String(format: "%.0f Hz", $0.sampleRate) } ?? "Not measured")
                    LabeledContent("Frames received", value: metrics.map { "\($0.receivedFrames)" } ?? "Not measured")
                    LabeledContent("Queue duration", value: duration(metrics?.queuedSeconds))
                    LabeledContent("In-flight audio batch", value: duration(metrics?.retainedBatchSeconds))
                    LabeledContent("Dropped audio", value: duration(metrics?.droppedSeconds))
                    LabeledContent("Processing / represented audio", value: metrics.map { String(format: "%.3f RTF", $0.realTimeFactor) } ?? "Not measured")
                    LabeledContent("Window-end processing delay", value: duration(metrics?.windowProcessingDelay))
                    LabeledContent("Last finalization delay", value: duration(metrics?.finalizationLatency))
                }
            }
            SettingsSection("Grok") {
                LabeledContent("Configured model", value: model.preferences.ai.model)
                LabeledContent("Generation", value: model.generationDiagnostics.status)
                LabeledContent("Request ID", value: model.generationDiagnostics.requestID?.uuidString ?? "No request").textSelection(.enabled)
                LabeledContent("Estimated text input", value: "\(model.generationDiagnostics.inputEstimate) tokens (conservative estimate)")
                LabeledContent("Submission to first text", value: duration(model.generationDiagnostics.firstTextSeconds))
                LabeledContent("Question end to first text", value: duration(model.generationDiagnostics.endToVisibleSeconds))
                LabeledContent("Provider input tokens", value: model.generationDiagnostics.usage?.inputTokens.map(String.init) ?? "Not reported")
                LabeledContent("Provider output tokens", value: model.generationDiagnostics.usage?.outputTokens.map(String.init) ?? "Not reported")
                LabeledContent("Cached input tokens", value: model.generationDiagnostics.usage?.cachedInputTokens.map(String.init) ?? "Not reported")
                Text("Window processing delay is not reference-aligned speech latency. First text is not automatically a useful answer. Benchmarks report those measurements separately; no internet p95 guarantee is implied.").font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection("Recent user-facing errors · excluded from report") {
                if model.recentErrors.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(Array(model.recentErrors.enumerated()), id: \.offset) { _, error in Text(error).font(.caption).textSelection(.enabled) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20) }
    }
    private func duration(_ seconds: Double?) -> String { seconds.map { String(format: "%.3f s", $0) } ?? "Not measured" }
}

func sourceLabel(_ state: SourceStatus) -> String {
    switch state {
    case .stopped: "Off"
    case .preparing: "Preparing"
    case .running: "Capturing locally"
    case .paused: "Paused"
    case .failed: "Needs attention"
    }
}
private func microphoneLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .notDetermined: "Not requested"
    @unknown default: "Unknown"
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Rectangle().fill(ShellTheme.border).frame(height: 1)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) { self.title = title; _text = text; self.axis = axis }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text, axis: axis).textFieldStyle(.roundedBorder)
        }
    }
}
