import AppKit
import AVFoundation
import FreelyCore
import SwiftUI

struct SetupView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.badge.mic").font(.title2).foregroundStyle(.teal)
                    Text("Freely").font(.headline)
                }.padding(.vertical, 20)
                ForEach(AppSection.allCases) { section in
                    Button { model.section = section } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(model.section == section ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Local speech · Grok answers").font(.caption).foregroundStyle(.secondary)
                Text("Screen context: \(model.screenMode == .off ? "Off" : "Enabled for session")")
                    .font(.caption2).foregroundStyle(model.screenMode == .off ? Color.secondary : Color.orange)
                Text("v1.0 · macOS 15+").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).padding(.bottom, 20).frame(width: 200).background(.bar)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.section.rawValue).font(.title2.bold())
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.running {
                        Button(model.session.phase == .paused ? "Resume" : "Pause") { model.pauseOrResume() }
                        Button("End session", role: .destructive) { Task { await model.stop() } }
                    } else if model.preparing {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { Task { await model.stop() } }
                    } else { Button("Start session") { model.start() }.buttonStyle(.borderedProminent).disabled(!model.canStart) }
                    Button { model.toggleOverlay?() } label: { Image(systemName: "rectangle.on.rectangle") }
                        .help("Show or hide the private companion overlay")
                }.padding(22)
                Divider()
                if let error = model.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(Color.orange.opacity(0.09))
                }
                sectionContent
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 850, minHeight: 600)
        .onChange(of: model.preferences) { _, _ in model.savePreferencesDebounced() }
        .onChange(of: model.sessionNotes) { _, _ in model.savePreferencesDebounced() }
        .onChange(of: model.pinnedFacts) { _, _ in model.savePreferencesDebounced() }
        .onChange(of: model.screenMode) { _, _ in model.screenConsentChanged() }
        .onChange(of: model.selectedVisualID) { _, _ in model.visualRegion = nil; model.visualSelectionChanged() }
        .confirmationDialog("Clear local settings, profiles and credentials?", isPresented: $model.showClearConfirmation) {
            Button("Clear local data", role: .destructive) { Task { await model.clearLocalData() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.clearModels ? "The installed speech model will also be removed. Exported and transmitted data cannot be recalled." : "The installed speech model will be kept. Exported and transmitted data cannot be recalled.") }
    }
    @ViewBuilder private var sectionContent: some View {
        switch model.section {
        case .setup: OnboardingView(model: model)
        case .session: SessionContentView(model: model)
        case .ai: AISettingsView(model: model)
        case .audio: AudioSettingsView(model: model)
        case .context: ContextSettingsView(model: model)
        case .overlay: OverlaySettingsView(model: model)
        case .privacy: PrivacySettingsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
    }
}

private struct OnboardingView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ready when you are.").font(.system(size: 32, weight: .semibold))
                    Text("Keep a useful answer beside your meeting. Speech recognition stays on your Mac. Selected conversation text goes to xAI; images only go when you enable screen context for the current session.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SetupStep(number: 1, title: "Choose exactly what to hear", detail: "Select your microphone and meeting application. A headset reduces speaker bleed; it is not required.", done: model.preferences.audio.applicationBundleID != nil || !model.preferences.audio.systemAudioEnabled) {
                    model.section = .audio
                }
                SetupStep(number: 2, title: "Allow native capture", detail: "Microphone and Screen & System Audio Recording are managed by macOS. Capture starts only when you start a session.", done: model.microphonePermission == .authorized && model.screenPixelPermission) { model.section = .audio }
                SetupStep(number: 3, title: "Connect your Grok subscription", detail: "Use secure browser sign-in for this application's registered xAI integration. An API key is available as an optional connection method.", done: model.connectionReady) { model.section = .ai }
                SetupStep(number: 4, title: "Install local speech recognition", detail: "Download the pinned model (\(ByteCountFormatter.string(fromByteCount: model.modelProgress.totalBytes, countStyle: .file))). Every file is checked before loading.", done: model.modelReady) { model.section = .audio }
                SetupStep(number: 5, title: "Make it yours", detail: "Select a reusable profile, set your answer language, and test the global shortcuts. Meeting notes remain separate from saved profiles.", done: model.preferences.onboardingCompleted) { model.section = .context }
                Toggle("Transcription-only session · do not request automatic Grok answers", isOn: $model.transcriptionOnly)
                    .disabled(model.running || model.preparing)
                HStack {
                    Button("Setup complete") { model.preferences.onboardingCompleted = true; model.notice = "Setup saved. Start a session explicitly when ready." }
                    Button("Review shortcuts") { model.section = .overlay }
                    Spacer()
                    Button("Start session") { model.start() }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                }
                if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                Text("No automatic meeting history. Ending a session clears its transcript, answers, images and session notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
private struct SetupStep: View {
    let number: Int; let title: String; let detail: String; let done: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(done ? Color.teal.opacity(0.15) : Color.secondary.opacity(0.12)).frame(width: 30, height: 30)
                    if done { Image(systemName: "checkmark").foregroundStyle(.teal) } else { Text("\(number)").font(.callout.bold()) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }.buttonStyle(.plain)
    }
}

private struct SessionContentView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                sourceCard(.localUser, icon: "mic.fill")
                sourceCard(.systemAudio, icon: "speaker.wave.2.fill")
            }
            HStack {
                TextField("Type a question or correction, or use current context", text: $model.typedQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                Button("Answer now") { model.answerNow() }.disabled(!model.running)
                Button("Detailed") { model.answerNow(detailed: true) }.disabled(!model.running)
            }
            HStack {
                Picker("Screen context", selection: $model.screenMode) {
                    ForEach(ScreenContextMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(!model.running)
                Button("Analyze screen") { model.answerNow(captureVisual: true) }.disabled(!model.running || model.screenMode == .off)
            }
            if model.screenMode != .off {
                HStack {
                    Picker("Visual source", selection: $model.selectedVisualID) {
                        Text("Choose a display or window").tag("")
                        ForEach(model.visualSources) { Text($0.name).tag($0.id) }
                    }
                    Button("Refresh") { Task { await model.refreshVisualSources() } }
                    Button(model.visualRegion == nil ? "Select region" : "Change region") { model.selectRegion() }
                        .disabled(model.selectedVisual?.kind != .display)
                }
                Text(model.visualRegion == nil ? "Only the selected surface is sent. Each image is captured on demand." : "A display region is selected. Keep essential text inside the outlined crop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Conversation").font(.headline); Spacer(); Button("Export excerpt") { model.exportRetainedTranscript() }.controlSize(.small) }
                    if model.session.transcript.isEmpty {
                        ContentUnavailableView("Waiting for speech", systemImage: "waveform", description: Text("Start the configured session. Silence and unavailable audio are reported separately in diagnostics."))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(model.session.transcript) { segment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(segment.source.label).font(.caption.bold()).foregroundStyle(segment.source == .systemAudio ? Color.teal : Color.secondary)
                                            Text(String(format: "%02d:%02d", Int(segment.startTime) / 60, Int(segment.startTime) % 60)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                            if segment.finality == .partial { Text("draft").font(.caption2).foregroundStyle(.secondary) }
                                        }
                                        Text(segment.text).textSelection(.enabled).font(.callout).foregroundStyle(segment.finality == .partial ? .secondary : .primary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                    if model.session.contextLimited || model.session.gapCount > 0 {
                        Text("\(model.session.gapCount) audio gaps · older context may be compacted. This is a retained excerpt.").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(12).frame(minWidth: 260)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Suggested answer").font(.headline); Spacer(); Button(model.pinned ? "Unpin" : "Pin") { model.setPinned(!model.pinned) } }
                    Text(model.question).font(.callout.bold()).lineLimit(4)
                    NativeAnswerView(text: model.answerPresentation.displayed?.text ?? "Your next answer will appear here.", textSize: model.textSize, interactive: true)
                    HStack {
                        Text(model.generationDiagnostics.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer()
                        Button("Copy") { model.copyAnswer() }
                        Button("Clear") { model.clearAnswer() }
                    }
                    if model.answerPresentation.newAnswerAvailable { Text("New answer available · unpin to show it").font(.caption).foregroundStyle(.teal) }
                }.padding(12).frame(minWidth: 250)
            }.background(.background, in: RoundedRectangle(cornerRadius: 10))
        }.padding(22)
    }
    private func sourceCard(_ source: AudioSource, icon: String) -> some View {
        let metrics = model.session.metrics[source]
        let state = model.session.sources[source] ?? .stopped
        return HStack {
            Image(systemName: icon).foregroundStyle(state == .running ? Color.teal : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.label).font(.callout.bold())
                Text(sourceLabel(state)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(min(1, metrics?.peak ?? 0))).frame(width: 48)
            Button(state == .running ? "Pause" : "Resume") { model.toggleSource(source) }.disabled(!model.running)
        }.padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AISettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Connect Grok") {
                Picker("Connection", selection: $model.preferences.connectionMethod) {
                    ForEach(ConnectionMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(model.running || model.preparing)
                if model.preferences.connectionMethod == .subscription {
                    HStack {
                        Button("Connect Grok subscription") { model.connectSubscription() }
                            .buttonStyle(.borderedProminent).disabled(model.subscription.signingIn || model.running || model.preparing)
                        if model.subscription.signingIn { Button("Cancel sign-in") { model.subscription.cancel() } }
                        if model.subscription.connected {
                            Button("Disconnect") { Task { await model.disconnectSubscription() } }.disabled(model.running || model.preparing)
                        }
                    }
                    Text(model.subscription.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Browser sign-in uses xAI's authorization service. Your password stays in the browser; rotating access tokens are kept in Keychain. Subscription and model access depend on xAI approving this application's integration.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced subscription integration setup") {
                        TextField("Registered Freely client ID", text: $model.preferences.subscriptionClientID)
                            .disabled(model.running || model.preparing || model.subscription.signingIn)
                        LabeledContent("Registered callback", value: "freely://oauth/callback")
                        Text("This build has no provider-issued OAuth client registration. Use only a client registered for Freely; another application's client ID is not a substitute.").font(.caption).foregroundStyle(.secondary)
                        Link("xAI subscription integration information", destination: URL(string: "https://x.ai/news/grok-opencode")!)
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
            Section("Answers") {
                TextField("Model", text: $model.preferences.ai.model).disabled(model.running || model.preparing)
                Picker("Reasoning effort", selection: $model.preferences.ai.reasoningEffort) {
                    ForEach(XAIReasoningEffort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.disabled(model.running || model.preparing)
                Text("Low still performs reasoning. End the session to change the model, request limits or automatic-answer behavior.").font(.caption).foregroundStyle(.secondary)
                TextField("Answer language", text: $model.preferences.ai.answerLanguage)
                Picker("Answer style", selection: $model.preferences.ai.answerStyle) {
                    ForEach(AnswerStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Automatically answer eligible meeting-audio questions", isOn: $model.preferences.ai.automaticAnswers)
                    .disabled(model.running || model.preparing)
                Toggle("Also allow local microphone speech to trigger answers", isOn: $model.preferences.ai.localSpeechTriggersAnswers)
                    .disabled(model.running || model.preparing)
                Stepper("Maximum request starts per minute: \(model.preferences.ai.requestsPerMinute)", value: $model.preferences.ai.requestsPerMinute, in: 1...120)
                    .disabled(model.running || model.preparing)
                Stepper("Normal output token cap: \(model.preferences.ai.normalOutputTokens)", value: $model.preferences.ai.normalOutputTokens, in: 256...32_768, step: 256)
                    .disabled(model.running || model.preparing)
                Stepper("Detailed output token cap: \(model.preferences.ai.detailedOutputTokens)", value: $model.preferences.ai.detailedOutputTokens, in: 256...32_768, step: 256)
                    .disabled(model.running || model.preparing)
                Text("Answers, retries and summaries share the request cap. Cancelled requests may still incur provider charges. No cost estimate is shown without current authoritative pricing.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Experimental") {
                Toggle("Speculative prefix answers", isOn: $model.preferences.ai.experimentalSpeculation)
                    .disabled(model.running || model.preparing)
                Text("Disabled by default. Experimental results are reported separately; ordinary answers do not require speculation.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct AudioSettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Microphone") {
                Toggle("Capture the local microphone", isOn: $model.preferences.audio.microphoneEnabled)
                    .disabled(model.running || model.preparing)
                Picker("Device", selection: $model.preferences.audio.microphoneDeviceUID) {
                    Text("Follow system default").tag(Optional<String>.none)
                    ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(model.preparing || model.session.sources[.localUser] == .running || model.session.sources[.localUser] == .preparing)
                HStack {
                    Text("Permission: \(microphoneLabel(model.microphonePermission))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Request access") { Task { await model.requestMicrophone() } }
                    Button("System Settings") { model.openPermissions(microphone: true) }
                }
                Button("Refresh devices") { model.refreshDevices() }
                Text("Pause a running microphone source before changing its device, then resume to apply the choice.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Meeting audio") {
                Toggle("Capture meeting application audio", isOn: $model.preferences.audio.systemAudioEnabled)
                    .disabled(model.running || model.preparing)
                Picker("Scope", selection: $model.preferences.audio.systemScope) {
                    Text("Selected application").tag(AudioPreferences.SystemScope.application)
                    Text("All system audio").tag(AudioPreferences.SystemScope.allSystemAudio)
                }.disabled(model.preparing || model.session.sources[.systemAudio] == .running || model.session.sources[.systemAudio] == .preparing)
                if model.preferences.audio.systemScope == .application {
                    Picker("Application", selection: $model.preferences.audio.applicationBundleID) {
                        Text("Choose a meeting application").tag(Optional<String>.none)
                        ForEach(model.applications.filter { !$0.bundleID.isEmpty }) { Text($0.name).tag(Optional($0.bundleID)) }
                    }.disabled(model.preparing || model.session.sources[.systemAudio] == .running || model.session.sources[.systemAudio] == .preparing)
                }
                HStack {
                    Button("Refresh applications") { Task { await model.refreshApplications() } }
                    Button("Capture permissions") { model.openPermissions() }
                }
                Text(model.systemPermissionStatus).font(.caption).foregroundStyle(.secondary)
                Text("Application scope includes all its capturable audio. Selecting a browser does not isolate one tab. This app's own audio is excluded. A missing application never falls back to system-wide capture.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pause the source before changing capture scope. Resume explicitly to capture the new selection.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local speech model") {
                LabeledContent("Engine", value: "FluidAudio / Parakeet TDT v3")
                LabeledContent("Speech language", value: "English (v1)")
                Text("Pinned FluidAudio default model variant · downloaded separately from the app").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: model.modelProgress.fraction)
                Text("\(model.modelProgress.phase) · \(ByteCountFormatter.string(fromByteCount: model.modelProgress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.modelProgress.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button(model.modelReady ? "Repair model" : "Download and verify model") { model.installModel() }
                        .disabled(model.modelInstalling || model.running || model.preparing)
                    if model.modelInstalling { Button("Cancel download") { model.cancelModelInstall() } }
                    Button("Run local sanity check") { Task { await model.sanityCheck() } }.disabled(!model.modelReady || model.running || model.preparing)
                }
                Text(model.localSanity).font(.caption).foregroundStyle(.secondary)
                Text("Models are never updated during a meeting. A corrupt or incomplete installation is not loaded; Repair preserves the last verified version until replacement succeeds.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct ContextSettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Reusable context · saved locally") {
                Picker("Active profile", selection: $model.preferences.selectedProfileID) {
                    Text("None — do not send a profile").tag(Optional<UUID>.none)
                    ForEach(model.preferences.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("New profile") { model.addProfile() }
                    Button("Import text / Markdown") { model.importProfile() }.disabled(model.selectedProfileIndex == nil)
                    Button("Delete selected", role: .destructive) { model.removeSelectedProfile() }.disabled(model.selectedProfileIndex == nil)
                }
                Text("Only the explicitly selected profile is eligible for requests. Relevant portions are selected within the context budget; stored profiles are plaintext local files, not encrypted.").font(.caption).foregroundStyle(.secondary)
                if let index = model.selectedProfileIndex {
                    TextField("Profile name", text: $model.preferences.profiles[index].name)
                    TextField("Role", text: $model.preferences.profiles[index].role)
                    TextField("Professional background", text: $model.preferences.profiles[index].professionalBackground, axis: .vertical).lineLimit(2...5)
                    TextField("Technology stack", text: $model.preferences.profiles[index].technologyStack, axis: .vertical).lineLimit(2...4)
                    TextField("Project context", text: $model.preferences.profiles[index].projectContext, axis: .vertical).lineLimit(2...5)
                    TextField("Answer preferences", text: $model.preferences.profiles[index].answerPreferences, axis: .vertical).lineLimit(2...4)
                    TextField("Vocabulary / technical terms", text: $model.preferences.profiles[index].vocabulary, axis: .vertical).lineLimit(2...4)
                    Text("Vocabulary informs answer context. This STT adapter does not apply vocabulary bias or rewrite recognized words.").font(.caption).foregroundStyle(.secondary)
                    TextField("Custom instructions", text: $model.preferences.profiles[index].customInstructions, axis: .vertical).lineLimit(2...5)
                    DisclosureGroup("Imported context") {
                        TextEditor(text: $model.preferences.profiles[index].importedContext).frame(minHeight: 120)
                    }
                }
            }
            Section("Current session only · cleared when it ends") {
                TextField("Session notes", text: $model.sessionNotes, axis: .vertical).lineLimit(3...8)
                TextField("Pinned facts", text: $model.pinnedFacts, axis: .vertical).lineLimit(2...5)
                Text("Actual conversation and prior AI suggestions keep separate provenance. The app does not invent professional experience or achievements.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct OverlaySettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Private companion overlay") {
                Slider(value: $model.preferences.overlay.opacity, in: 0.35...1) { Text("Opacity") }
                Stepper("Text size: \(Int(model.preferences.overlay.textSize)) pt", value: $model.preferences.overlay.textSize, in: 11...32)
                Toggle("Show overlay when a session starts", isOn: $model.preferences.overlay.initiallyVisible)
                Toggle("Click through in passive mode", isOn: $model.preferences.overlay.clickThrough)
                HStack { Button("Show / hide") { model.toggleOverlay?() }; Button("Interact with overlay") { model.focusQuestion?() } }
                Text("Streaming updates do not activate the app. Choose Interact to select text or type a question; Done returns to passive mode. Pinning freezes the displayed answer while capture continues.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Global shortcuts") {
                Text("No Accessibility permission is required. Shortcuts use physical key positions; the labels below follow US positions. Menu alternatives remain available for conflicts.").font(.caption).foregroundStyle(.secondary)
                ForEach($model.preferences.shortcuts) { $binding in
                    ShortcutRow(binding: $binding, status: model.hotkeyStatuses[binding.action] ?? .disabled)
                }
                HStack {
                    Button("Apply shortcuts") { model.applyShortcuts() }
                    Button("Restore defaults") { model.preferences.shortcuts = ShortcutBinding.defaults; model.applyShortcuts() }
                }
            }
        }.formStyle(.grouped)
    }
}
private struct ShortcutRow: View {
    @Binding var binding: ShortcutBinding
    let status: HotkeyRegistrationStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(binding.action.title).frame(width: 185, alignment: .leading)
                Toggle("On", isOn: Binding(get: { binding.chord != nil }, set: { binding.chord = $0 ? ShortcutChord(key: .space, modifiers: [.command, .control, .option]) : nil })).labelsHidden()
                if binding.chord != nil {
                    Picker("Key", selection: Binding(get: { binding.chord?.keyCode ?? 49 }, set: { binding.chord?.keyCode = $0 })) {
                        ForEach(ShortcutKey.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 75)
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

private struct PrivacySettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Where data goes") {
                Label("Microphone and system audio are processed locally and never saved or uploaded.", systemImage: "waveform")
                Label("Selected transcript context, profile excerpts and questions go to the official xAI API.", systemImage: "network")
                Label("Images are sent only with explicit session consent and a selected visual source.", systemImage: "rectangle.dashed")
                Label("No automatic meeting history. Ending a session clears volatile meeting data.", systemImage: "clock.arrow.circlepath")
                Text("Requests set store:false and use bounded client-side context. This does not promise zero provider retention; consult xAI's current data policy and your account agreement. No model tools, browsing, shell or computer-control capabilities are enabled.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Presenter-private behavior") {
                Text("This is a private companion overlay. Visibility in another application's capture depends on the application, macOS version and sharing mode.")
                Text("Selected-window sharing and full-display capture require separate verification. NSWindow.sharingType and exclusion from our own screenshots do not guarantee invisibility. Untested combinations are not verified.").font(.caption).foregroundStyle(.secondary)
                Button("Hide / show overlay now") { model.toggleOverlay?() }
            }
            Section("Clear local data") {
                Toggle("Also remove the installed speech model", isOn: $model.clearModels)
                Button("Clear settings, profiles and Keychain credential…", role: .destructive) { model.showClearConfirmation = true }
                    .disabled(model.running || model.preparing)
                Text("Previously exported, backed-up or transmitted data cannot be recalled. This is not a forensic erasure guarantee.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct DiagnosticsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("State", value: model.status)
                LabeledContent("Retained transcript", value: "\(model.session.transcript.count) segments")
                LabeledContent("Explicit audio gaps", value: "\(model.session.gapCount)")
                LabeledContent("Summary coverage", value: model.session.summaryCoverage)
                LabeledContent("Last teardown", value: duration(model.session.teardownSeconds))
            }
            ForEach(AudioSource.allCases, id: \.self) { source in
                Section(source.label) {
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
            Section("Grok") {
                LabeledContent("Configured model", value: model.preferences.ai.model)
                LabeledContent("Generation", value: model.generationDiagnostics.status)
                LabeledContent("Estimated text input", value: "\(model.generationDiagnostics.inputEstimate) tokens (conservative estimate)")
                LabeledContent("Submission to first text", value: duration(model.generationDiagnostics.firstTextSeconds))
                LabeledContent("Question end to first text", value: duration(model.generationDiagnostics.endToVisibleSeconds))
                LabeledContent("Provider input tokens", value: model.generationDiagnostics.usage?.inputTokens.map(String.init) ?? "Not reported")
                LabeledContent("Provider output tokens", value: model.generationDiagnostics.usage?.outputTokens.map(String.init) ?? "Not reported")
                LabeledContent("Cached input tokens", value: model.generationDiagnostics.usage?.cachedInputTokens.map(String.init) ?? "Not reported")
                Text("Window processing delay is not reference-aligned speech latency. First text is not automatically a useful answer. Benchmarks report those measurements separately; no internet p95 guarantee is implied.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent redacted errors (maximum 30)") {
                if model.recentErrors.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(Array(model.recentErrors.enumerated()), id: \.offset) { _, error in Text(error).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
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
