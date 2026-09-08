import AppKit
import AVFoundation
import FreelyCore
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ApplicationModel {
    var preferences = AppPreferences() {
        didSet { if preferences != oldValue { savePreferencesDebounced() } }
    }
    var section = AppSection.setup
    var session = SessionViewState() { didSet { sessionPresentationChanged?() } }
    var answerPresentation = AnswerPresentation()
    var generationDiagnostics = GenerationDiagnostics()
    var microphones = NativeMicrophoneCapture.devices()
    var applications: [AudioApplication] = []
    var visualSources: [VisualSource] = []
    var selectedVisualID = "" {
        didSet {
            if selectedVisualID != oldValue { visualRegion = nil; visualSelectionChanged() }
        }
    }
    var visualRegion: CGRect? { didSet { if visualRegion != oldValue { visualSelectionChanged() } } }
    var screenMode = ScreenContextMode.off { didSet { if screenMode != oldValue { screenConsentChanged() } } }
    var microphonePermission = NativeMicrophoneCapture.permission()
    var screenPixelPermission = CGPreflightScreenCaptureAccess()
    var systemPermissionStatus = "Not exercised"
    var errorMessage: String?
    var notice: String?
    var hasAPIKey = false
    var apiKeyDraft = ""
    var apiValidation = "Not tested"
    var validatingAPI = false
    private var credentialBusy = false
    private(set) var connectionUpdating = false
    var modelProgress = ModelInstallProgress(phase: "Checking model", completedBytes: 0, totalBytes: 0)
    var modelReady = false
    var modelInstalling = false
    var localSanity = "Not tested"
    var sanityChecking = false
    private var configuredTranscriptionOnly = false
    var transcriptionOnly: Bool {
        get { configuredTranscriptionOnly }
        set {
            guard newValue == configuredTranscriptionOnly || (!running && !preparing) else {
                showError("End the session before changing transcription-only mode."); return
            }
            configuredTranscriptionOnly = newValue
        }
    }
    var sessionNotes = "" { didSet { if sessionNotes != oldValue { savePreferencesDebounced() } } }
    var pinnedFacts = "" { didSet { if pinnedFacts != oldValue { savePreferencesDebounced() } } }
    var typedQuestion = ""
    var interactive = false
    var overlayVisible = false
    var ready = false
    var clearModels = false
    var showClearConfirmation = false
    var maintenanceBusy = false
    private(set) var isShuttingDown = false
    var recentErrors: [String] = []
    var hotkeyStatuses: [HotkeyAction: HotkeyRegistrationStatus] = [:]
    @ObservationIgnored var toggleOverlay: (() -> Void)?
    @ObservationIgnored var updateOverlay: (() -> Void)?
    @ObservationIgnored var focusQuestion: (() -> Void)?
    @ObservationIgnored var chooseRegion: ((UInt32, @escaping (CGRect?) -> Void) -> Void)?
    @ObservationIgnored var sessionPresentationChanged: (() -> Void)?
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let fetchVisualSources: @Sendable () async throws -> [VisualSource]
    @ObservationIgnored let credentials: any CredentialStoring
    @ObservationIgnored let subscription: SubscriptionAuthentication
    @ObservationIgnored let grokBuild: GrokBuildConnection
    @ObservationIgnored private var connectionCredentials: PreferredCredentialStore?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var lastConnectionSettings = ""
    @ObservationIgnored private var pendingConnection: (SubscriptionClientConfiguration, ConnectionMethod, String)?
    @ObservationIgnored private let rateBudget = SharedRequestBudget()
    @ObservationIgnored private var installer: ModelInstaller?
    @ObservationIgnored private var modelCache: LocalSpeechModelCache?
    @ObservationIgnored private var coordinator: SessionCoordinator?
    @ObservationIgnored private var hotkeys: HotkeyController?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var sanityTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var activeValidationProvider: (any LLMProviding)?
    @ObservationIgnored private var applicationsTask: Task<Void, Never>?
    @ObservationIgnored private var visualSourcesTask: Task<Void, Never>?
    @ObservationIgnored private var screenTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTask: Task<Void, Never>? {
        didSet { credentialBusy = credentialTask != nil }
    }
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var importPanel: NSOpenPanel?
    @ObservationIgnored private var exportPanel: NSSavePanel?
    @ObservationIgnored private var sessionUIEpoch: UInt64 = 0
    @ObservationIgnored private var visualRevision: UInt64 = 0
    @ObservationIgnored private var visualSourcesRevision: UInt64 = 0
    @ObservationIgnored private var importRevision: UInt64 = 0
    @ObservationIgnored private var saveRevision: UInt64 = 0
    @ObservationIgnored private var validationRevision: UInt64 = 0
    @ObservationIgnored private var pendingPreferences: AppPreferences?
    @ObservationIgnored private var persistedPreferences: AppPreferences?
    @ObservationIgnored private var desiredScreenMode = ScreenContextMode.off
    @ObservationIgnored private var desiredScreenSelection: ScreenSelection?
    @ObservationIgnored private var pendingScreenCommit: ScreenCommit?
    private var stopping = false { didSet { sessionPresentationChanged?() } }

    private enum ScreenCommit {
        case consent(ScreenContextMode, ScreenIntentToken)
        case selection(ScreenSelection?, ScreenIntentToken)
    }

    init(store: PreferencesStore = PreferencesStore(), credentials: any CredentialStoring = KeychainCredentialStore(),
         subscription: SubscriptionAuthentication = SubscriptionAuthentication(),
         grokBuild: GrokBuildConnection = GrokBuildConnection(),
         fetchVisualSources: @escaping @Sendable () async throws -> [VisualSource] = NativeScreenCapture.sources) {
        self.store = store; self.credentials = credentials; self.subscription = subscription; self.grokBuild = grokBuild
        self.fetchVisualSources = fetchVisualSources
    }

    var status: String {
        if isShuttingDown { return "Closing Freely" }
        if maintenanceBusy { return "Updating local data" }
        if modelInstalling { return "Downloading and verifying the speech model" }
        if sanityChecking { return "Checking local speech recognition" }
        if stopping { return "Ending session" }
        if connectionUpdating, !transcriptionOnly { return "Updating Grok connection" }
        return switch session.phase {
        case .idle: canStart ? "Ready · capture is off" : (startRequirement ?? "Complete setup to start")
        case .preparing: "Preparing local transcription"
        case .running: transcriptionOnly ? "Transcription only · local audio" : "Listening · automatic answers \(preferences.ai.automaticAnswers ? "on" : "off")"
        case .paused: "Paused · resume explicitly"
        case .recovering: "Capture needs attention"
        case .stopping: "Ending session"
        }
    }
    var running: Bool { session.phase == .running || session.phase == .recovering || session.phase == .paused }
    var preparing: Bool { stopping || session.phase == .preparing || session.phase == .stopping }
    var answer: String { answerPresentation.displayed?.text ?? "Start a session to see answers here." }
    var question: String { answerPresentation.displayed?.question.text ?? session.lastQuestion?.text ?? "Your meeting companion" }
    var pinned: Bool { answerPresentation.isPinned }
    var expanded: Bool { preferences.overlay.expanded }
    var opacity: Double { preferences.overlay.opacity }
    var textSize: Double { preferences.overlay.textSize }
    var clickThrough: Bool { preferences.overlay.clickThrough }
    var canStart: Bool {
        ready && modelReady && !running && !preparing && !stopping && !isShuttingDown && !modelInstalling && !sanityChecking && !maintenanceBusy && !credentialBusy &&
            (connectionReady || transcriptionOnly) && audioSelectionReady &&
            (!preferences.audio.microphoneEnabled || microphonePermission == .authorized)
    }
    var audioSelectionReady: Bool {
        (preferences.audio.microphoneEnabled || preferences.audio.systemAudioEnabled) &&
            (!preferences.audio.systemAudioEnabled || preferences.audio.systemScope == .allSystemAudio || preferences.audio.applicationBundleID != nil)
    }
    var startRequirement: String? {
        if !ready { return "Checking your setup…" }
        if !modelReady { return "Download the speech model in Audio / STT" }
        if !connectionReady && !transcriptionOnly { return "Connect Grok in AI settings, or choose transcription only" }
        if !preferences.audio.microphoneEnabled && !preferences.audio.systemAudioEnabled { return "Choose at least one audio source in Audio / STT" }
        if !audioSelectionReady { return "Choose a meeting application in Audio / STT" }
        if preferences.audio.microphoneEnabled && microphonePermission != .authorized { return "Allow microphone access in Audio / STT" }
        return nil
    }
    var diagnosticState: [String: DiagnosticValue] {
        var result: [String: DiagnosticValue] = [
            "setupReady": .flag(ready), "modelReady": .flag(modelReady), "modelInstalling": .flag(modelInstalling),
            "connectionReady": .flag(connectionReady), "transcriptionOnly": .flag(transcriptionOnly),
            "sessionActive": .flag(running), "sessionPreparing": .flag(preparing),
            "ownedSessionTasks": .int(coordinator?.ownedTaskCount ?? 0),
            "microphonePermission": .int(microphonePermission.rawValue), "screenPixelPermission": .flag(screenPixelPermission),
            "microphoneEnabled": .flag(preferences.audio.microphoneEnabled), "systemAudioEnabled": .flag(preferences.audio.systemAudioEnabled),
            "screenContextEnabled": .flag(screenMode != .off), "contextLimited": .flag(session.contextLimited),
            "retainedSegments": .int(session.transcript.count), "audioGaps": .int(session.gapCount),
            "estimatedInputTokens": .int(generationDiagnostics.inputEstimate),
            "usesVisual": .flag(generationDiagnostics.usesVisual), "overlayVisible": .flag(overlayVisible),
            "overlayInteractive": .flag(interactive), "recentErrorCount": .int(recentErrors.count)
        ]
        if let value = session.teardownSeconds { result["lastTeardownSeconds"] = .number(value) }
        if let value = generationDiagnostics.firstTextSeconds { result["firstVisibleTextSeconds"] = .number(value) }
        for source in AudioSource.allCases {
            let prefix = source == .localUser ? "microphone" : "systemAudio"
            let status: DiagnosticValue
            switch session.sources[source] ?? .stopped {
            case .stopped: status = .state("stopped")
            case .preparing: status = .state("preparing")
            case .running: status = .state("running")
            case .paused: status = .state("paused")
            case .failed: status = .state("failed")
            }
            result[prefix + ".state"] = status
            guard let metrics = session.metrics[source] else { continue }
            result[prefix + ".receivedFrames"] = .int(metrics.receivedFrames)
            result[prefix + ".queuedSeconds"] = .number(metrics.queuedSeconds)
            result[prefix + ".droppedSeconds"] = .number(metrics.droppedSeconds)
            result[prefix + ".peak"] = .number(Double(metrics.peak))
            result[prefix + ".sampleRate"] = .number(metrics.sampleRate)
            result[prefix + ".realTimeFactor"] = .number(metrics.realTimeFactor)
            result[prefix + ".lastInferenceSeconds"] = .number(metrics.lastInferenceSeconds)
            if let last = metrics.lastAudioAt { result[prefix + ".lastAudioAgeSeconds"] = .number(max(0, session.elapsedSeconds - last)) }
        }
        return result
    }
    var usesGrokBuild: Bool { preferences.connectionMethod == .subscription && !subscriptionConfiguration.isConfigured }
    var subscriptionBusy: Bool { usesGrokBuild ? grokBuild.busy : subscription.signingIn }
    var subscriptionConnected: Bool { usesGrokBuild ? grokBuild.connected : subscription.connected }
    var subscriptionStatus: String { usesGrokBuild ? grokBuild.status : subscription.status }
    var connectionReady: Bool { !connectionUpdating && !subscriptionBusy && (preferences.connectionMethod == .apiKey ? hasAPIKey : subscriptionConnected) }
    var subscriptionConfiguration: SubscriptionClientConfiguration {
        var configuration = SubscriptionClientConfiguration()
        configuration.clientID = preferences.subscriptionClientID.isEmpty
            ? (Bundle.main.object(forInfoDictionaryKey: "FreelyOAuthClientID") as? String ?? "")
            : preferences.subscriptionClientID
        return configuration
    }
    var selectedVisual: VisualSource? { visualSources.first { $0.id == selectedVisualID } }
    var selectedProfileIndex: Int? { preferences.profiles.firstIndex { $0.id == preferences.selectedProfileID } }

    func initialize() {
        guard setupTask == nil, !isShuttingDown, !maintenanceBusy else { return }
        setupTask = Task { [weak self] in
            guard let self else { return }
            do { preferences = try await store.load(); persistedPreferences = preferences }
            catch { showError(Self.diagnosticMessage(error)); notice = "Existing settings were preserved. Clear local data explicitly to reset a corrupt configuration." }
            guard !Task.isCancelled else { return }
            do {
                if store.directory == PreferencesStore.defaultDirectory, let keychain = credentials as? KeychainCredentialStore {
                    try await keychain.importLegacyCredentialIfNeeded()
                }
                hasAPIKey = try await credentials.load()?.isEmpty == false
            }
            catch { showError(Self.diagnosticMessage(error)) }
            guard !Task.isCancelled else { return }
            await subscription.configure(subscriptionConfiguration)
            if usesGrokBuild { await grokBuild.restore(enabled: preferences.grokBuildConnected) }
            guard !Task.isCancelled else { return }
            let connection = PreferredCredentialStore(apiKey: credentials, subscription: subscription.tokens)
            await connection.select(preferences.connectionMethod)
            connectionCredentials = connection
            lastConnectionSettings = preferences.connectionMethod.rawValue + "|" + subscriptionConfiguration.clientID
            do {
                guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json") else { throw ModelInstallError.invalidManifest }
                let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
                let installer = try ModelInstaller(root: PreferencesStore.defaultDirectory.appendingPathComponent("Models", isDirectory: true), manifest: manifest)
                self.installer = installer
                modelProgress = ModelInstallProgress(phase: "Not installed", completedBytes: 0, totalBytes: manifest.bytes)
                let cache = LocalSpeechModelCache(installer: installer)
                modelCache = cache
                coordinator = SessionCoordinator(modelCache: cache, credentials: connection, rateBudget: rateBudget,
                    onState: { [weak self] state in
                        self?.session = state
                        if let message = state.error, self?.recentErrors.last != message { self?.showError(message) }
                        if state.sources[.systemAudio] == .running { self?.systemPermissionStatus = "Capture started successfully" }
                    }, onAnswer: { [weak self] answer, diagnostics in
                        self?.answerPresentation = answer; self?.generationDiagnostics = diagnostics
                    })
                do {
                    _ = try await installer.verifiedInstallation(); modelReady = true
                    modelProgress = await installer.progress()
                } catch ModelInstallError.notInstalled {
                    modelProgress = .init(phase: "Download required", completedBytes: 0, totalBytes: manifest.bytes)
                } catch { modelProgress = .init(phase: "Repair required", completedBytes: 0, totalBytes: manifest.bytes); showError(Self.diagnosticMessage(error)) }
            } catch { showError(Self.diagnosticMessage(error)) }
            guard !Task.isCancelled else { return }
            let controller = HotkeyController { [weak self] in self?.handleHotkey($0) }
            hotkeys = controller
            hotkeyStatuses = controller.configure(preferences.shortcuts)
            FreelyLog.record(.appReady, fields: [.ready: .flag(modelReady), .connected: .flag(connectionReady)])
            ready = true
            updateOverlay?()
            if CommandLine.arguments.contains("--install-model") { installModel() }
        }
    }
    func start() {
        guard !isShuttingDown, !maintenanceBusy else { return }
        guard canStart else { showError(startRequirement ?? "Finish setup before starting a session."); return }
        if preferences.audio.microphoneEnabled && NativeMicrophoneCapture.permission() != .authorized {
            showError("Allow microphone access before starting, or disable the microphone for an explicit system-audio-only session."); return
        }
        if preferences.audio.systemAudioEnabled, preferences.audio.systemScope == .application,
           preferences.audio.applicationBundleID == nil {
            showError("Choose a meeting application before starting system audio."); return
        }
        sessionUIEpoch &+= 1; visualRevision &+= 1; visualSourcesRevision &+= 1
        errorMessage = nil; screenMode = .off; visualRegion = nil; selectedVisualID = ""; visualSources = []
        desiredScreenMode = .off; desiredScreenSelection = nil; pendingScreenCommit = nil
        coordinator?.prepareScreenConsent(.off)
        coordinator?.prepareScreenSelection(nil)
        coordinator?.start(preferences: preferences, sessionNotes: sessionNotes, pinnedFacts: pinnedFacts, transcriptionOnly: transcriptionOnly, useGrokBuild: usesGrokBuild)
        if preferences.overlay.initiallyVisible, !overlayVisible { toggleOverlay?() }
        section = .session
    }
    func stop() async {
        if stopping { await coordinator?.stop(); await screenTask?.value; await visualSourcesTask?.value; return }
        stopping = true
        defer { stopping = false }
        sessionUIEpoch &+= 1; visualRevision &+= 1; visualSourcesRevision &+= 1
        let expected = sessionUIEpoch
        screenMode = .off
        screenTask?.cancel(); visualSourcesTask?.cancel(); pendingScreenCommit = nil
        visualSources = []; selectedVisualID = ""; visualRegion = nil
        desiredScreenMode = .off; desiredScreenSelection = nil
        sessionNotes = ""; pinnedFacts = ""; typedQuestion = ""
        coordinator?.prepareScreenConsent(.off)
        coordinator?.prepareScreenSelection(nil)
        await coordinator?.stop()
        await screenTask?.value; await visualSourcesTask?.value
        if expected == sessionUIEpoch { generationDiagnostics = .init(); answerPresentation = .init() }
    }
    func pauseOrResume() { guard !isShuttingDown, !maintenanceBusy, !stopping else { return }; coordinator?.pauseOrResume() }
    func toggleSource(_ source: AudioSource) {
        guard !isShuttingDown, !maintenanceBusy, !stopping, running, !preparing else { return }
        if session.sources[source] != .running, session.sources[source] != .preparing {
            if source == .localUser { preferences.audio.microphoneEnabled = true }
            else { preferences.audio.systemAudioEnabled = true }
        }
        coordinator?.updateSourceSettings(preferences.audio)
        coordinator?.toggleSource(source)
    }
    func pauseForSystemEvent() async { guard !isShuttingDown else { return }; await coordinator?.pauseAllForSystemEvent() }
    func requestMicrophone() async {
        guard !isShuttingDown, !maintenanceBusy else { return }
        _ = await NativeMicrophoneCapture.requestPermission()
        guard !isShuttingDown, !maintenanceBusy else { return }
        microphonePermission = NativeMicrophoneCapture.permission()
        FreelyLog.record(.permissionChecked, scope: .init(source: .localUser), fields: [.state: .int(microphonePermission.rawValue)])
        if microphonePermission != .authorized { showError("Microphone access is denied. Enable Freely in Privacy & Security → Microphone.") }
    }
    func refreshDevices() {
        guard !isShuttingDown else { return }
        microphones = NativeMicrophoneCapture.devices()
        microphonePermission = NativeMicrophoneCapture.permission()
        screenPixelPermission = CGPreflightScreenCaptureAccess()
    }
    func refreshApplications() async {
        guard !isShuttingDown, !maintenanceBusy else { return }
        if let applicationsTask { await applicationsTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { applicationsTask = nil }
            do {
                let available = try await NativeSystemAudioCapture.applications()
                guard !Task.isCancelled, !isShuttingDown, !maintenanceBusy else { return }
                applications = available
                if systemPermissionStatus != "Capture started successfully" {
                    systemPermissionStatus = "Choose an application. macOS will request capture permission when the session starts."
                }
                screenPixelPermission = CGPreflightScreenCaptureAccess()
            } catch {
                guard !Task.isCancelled, !isShuttingDown, !maintenanceBusy else { return }
                FreelyLog.record(.operationFailed, level: .error, fields: [.state: .state("list_audio_sources"), .failure: .failure(error)])
                let diagnostic = Self.captureFailureCode(error)
                systemPermissionStatus = "Source listing failed · \(diagnostic)"
                let native = error as NSError
                if native.domain == SCStreamErrorDomain, native.code == -3801 {
                    showError("macOS denied capture authorization (\(diagnostic)). Allow Freely in Privacy & Security → Screen & System Audio Recording, then quit and reopen the app if macOS requests it.")
                } else {
                    showError("Capture source listing failed (\(diagnostic)). Check display availability and capture permission, then refresh the source list.")
                }
            }
        }
        applicationsTask = task
        await task.value
    }
    func refreshVisualSources() async {
        guard !isShuttingDown, !maintenanceBusy, !stopping else { return }
        guard running, screenMode != .off else { showError("Enable screen context for this session first."); return }
        visualSourcesRevision &+= 1
        let revision = visualSourcesRevision, epoch = sessionUIEpoch
        let previous = visualSourcesTask
        previous?.cancel(); await previous?.value
        guard revision == visualSourcesRevision, epoch == sessionUIEpoch, !Task.isCancelled,
              !isShuttingDown, !maintenanceBusy, running, screenMode != .off else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { visualSourcesTask = nil }
            do {
                let available = try await fetchVisualSources()
                guard !Task.isCancelled, epoch == sessionUIEpoch, revision == visualSourcesRevision,
                      !isShuttingDown, !maintenanceBusy, running, screenMode != .off else { return }
                visualSources = available
                if !selectedVisualID.isEmpty, !available.contains(where: { $0.id == selectedVisualID }) {
                    selectedVisualID = ""
                    notice = "The selected visual source disappeared. Select a new source; capture scope was not widened."
                }
            } catch {
                guard !Task.isCancelled, epoch == sessionUIEpoch, revision == visualSourcesRevision,
                      !isShuttingDown, !maintenanceBusy, running, screenMode != .off else { return }
                showError("Screen sources are unavailable (\(Self.captureFailureCode(error))). Check display availability and capture permission, then refresh.")
            }
        }
        visualSourcesTask = task
        await task.value
    }
    func screenConsentChanged() {
        guard !isShuttingDown, !maintenanceBusy, !stopping else { return }
        let mode = screenMode
        guard mode != desiredScreenMode else { return }
        desiredScreenMode = mode
        visualRevision &+= 1; visualSourcesRevision &+= 1
        visualSourcesTask?.cancel()
        if let token = coordinator?.prepareScreenConsent(mode) { pendingScreenCommit = .consent(mode, token) }
        if mode == .off {
            visualSources = []; selectedVisualID = ""; visualRegion = nil
            notice = "Screen context cleared. Data already transmitted to xAI cannot be recalled."
        }
        launchScreenCommitIfNeeded()
    }
    func visualSelectionChanged() {
        guard !isShuttingDown, !maintenanceBusy, !stopping else { return }
        let selection = selectedVisual.map { ScreenSelection(source: $0, region: visualRegion) }
        guard selection != desiredScreenSelection else { return }
        desiredScreenSelection = selection; visualRevision &+= 1
        if let token = coordinator?.prepareScreenSelection(selection) { pendingScreenCommit = .selection(selection, token) }
        launchScreenCommitIfNeeded()
    }
    private func launchScreenCommitIfNeeded() {
        guard screenTask == nil, pendingScreenCommit != nil, !isShuttingDown, !maintenanceBusy, !stopping else { return }
        let epoch = sessionUIEpoch
        screenTask = Task { [weak self] in
            guard let self else { return }
            defer { screenTask = nil }
            while let commit = pendingScreenCommit, !Task.isCancelled, epoch == sessionUIEpoch, !isShuttingDown, !maintenanceBusy, !stopping {
                pendingScreenCommit = nil
                switch commit {
                case .consent(let mode, let token): await coordinator?.setScreenConsent(mode, prepared: token)
                case .selection(let selection, let token): await coordinator?.selectScreen(selection, prepared: token)
                }
                guard !Task.isCancelled, epoch == sessionUIEpoch, !isShuttingDown, !maintenanceBusy, !stopping else { return }
                if pendingScreenCommit == nil, screenMode != .off, visualSources.isEmpty { await refreshVisualSources() }
            }
        }
    }
    func selectRegion() {
        guard !isShuttingDown, !maintenanceBusy, !stopping, running, screenMode != .off else { return }
        guard let selectedVisual, selectedVisual.kind == .display else { showError("Select a display before choosing a region."); return }
        let epoch = sessionUIEpoch, revision = visualRevision, sourceID = selectedVisual.id
        chooseRegion?(selectedVisual.nativeID) { [weak self] rect in
            guard let self, let rect, !isShuttingDown, !maintenanceBusy, !stopping, running, screenMode != .off,
                  epoch == sessionUIEpoch, revision == visualRevision, selectedVisualID == sourceID else { return }
            visualRegion = rect
        }
    }
    func answerNow(captureVisual: Bool = false, detailed: Bool = false) {
        guard !isShuttingDown, !maintenanceBusy, !stopping else { return }
        if !connectionReady { showError("Connect Grok in AI settings to request answers. Local transcription can continue."); section = .ai; return }
        if captureVisual && screenMode == .off { showError("Enable screen context explicitly for this session before analyzing it."); return }
        coordinator?.answerNow(text: typedQuestion, captureVisual: captureVisual, detailed: detailed)
    }
    func setPinned(_ value: Bool) { guard !isShuttingDown, !maintenanceBusy else { return }; coordinator?.pinAnswer(value) }
    func toggleExpanded() { guard !isShuttingDown, !maintenanceBusy else { return }; preferences.overlay.expanded.toggle(); updateOverlay?(); savePreferencesDebounced() }
    func clearAnswer() { guard !isShuttingDown, !maintenanceBusy else { return }; coordinator?.clearAnswer() }
    func copyAnswer() {
        guard !isShuttingDown, !maintenanceBusy else { return }
        guard let text = answerPresentation.displayed?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        notice = "Answer copied"
    }
    func saveAPIKey() async {
        guard !isShuttingDown, !maintenanceBusy, !running, !preparing, credentialTask == nil else { return }
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { showError(Self.message(XAIError.missingCredential)); return }
        validationRevision &+= 1; validationTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { credentialTask = nil }
            do {
                await activeValidationProvider?.cancelAll(); await validationTask?.value
                try Task.checkCancellation()
                try await credentials.save(key)
                guard !isShuttingDown, !maintenanceBusy else { return }
                apiKeyDraft = ""; hasAPIKey = true; apiValidation = "Saved in Keychain · not yet tested"
            } catch is CancellationError {} catch { if !isShuttingDown, !maintenanceBusy { showError(Self.diagnosticMessage(error)) } }
        }
        credentialTask = task; await task.value
    }
    func deleteAPIKey() async {
        guard !isShuttingDown, !maintenanceBusy, !running, !preparing, credentialTask == nil else { return }
        validationRevision &+= 1; validationTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { credentialTask = nil }
            do {
                await activeValidationProvider?.cancelAll(); await validationTask?.value
                try Task.checkCancellation()
                try await credentials.delete()
                guard !isShuttingDown, !maintenanceBusy else { return }
                hasAPIKey = false; apiKeyDraft = ""; apiValidation = "Not tested"
            } catch is CancellationError {} catch { if !isShuttingDown, !maintenanceBusy { showError(Self.diagnosticMessage(error)) } }
        }
        credentialTask = task; await task.value
    }
    func validateAPI() {
        guard !isShuttingDown, !maintenanceBusy, !validatingAPI, connectionReady, !running, !preparing, credentialTask == nil, let connectionCredentials else { return }
        validationRevision &+= 1
        let revision = validationRevision
        validatingAPI = true; apiValidation = "Testing text streaming · may consume usage"
        validationTask = Task { [weak self] in
            guard let self else { return }
            defer { validatingAPI = false; activeValidationProvider = nil; validationTask = nil }
            await rateBudget.configure(limit: preferences.ai.requestsPerMinute)
            var configuration = preferences.ai.transportConfiguration
            configuration.normalOutputTokens = 256
            let provider = SelectedLLMProvider(credentials: connectionCredentials, useGrokBuild: usesGrokBuild, configuration: configuration,
                approveRequestStart: { [rateBudget] in try await rateBudget.acquire() })
            activeValidationProvider = provider
            do {
                try Task.checkCancellation()
                let stream = try await provider.stream(LLMRequest(trustedInstructions: "Answer the user's short test directly.",
                    selectedContext: "Reply with the word Ready.", estimatedInputTokens: 80, sessionCacheKey: UUID().uuidString))
                var text = ""; var terminal = false
                for try await event in stream {
                    try Task.checkCancellation()
                    if case .textDelta(let delta) = event { text += delta }
                    if case .completed = event { terminal = true }
                }
                guard revision == validationRevision, !isShuttingDown, !maintenanceBusy else { await provider.cancelAll(); return }
                apiValidation = terminal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Text streaming verified for \(configuration.model). Image reasoning requires a separate session test."
                    : "Text stream did not complete. Review model access and API configuration."
            } catch is CancellationError { if revision == validationRevision, !isShuttingDown, !maintenanceBusy { apiValidation = "Test cancelled" } }
            catch { if revision == validationRevision, !isShuttingDown, !maintenanceBusy { apiValidation = Self.diagnosticMessage(error) } }
            await provider.cancelAll()
        }
    }
    func installModel() {
        guard !isShuttingDown, !maintenanceBusy, let installer, !modelInstalling, !running, !preparing, !sanityChecking else { return }
        FreelyLog.record(.modelStarted)
        modelInstalling = true
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { modelInstalling = false; installTask = nil }
            guard !Task.isCancelled, !isShuttingDown, !maintenanceBusy else { return }
            let progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.modelProgress = await installer.progress()
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                }
            }
            do {
                await modelCache?.clear()
                _ = try await installer.install()
                modelReady = true
                notice = "Local model downloaded and verified. Run the sanity check before your first meeting."
            } catch is CancellationError { FreelyLog.record(.modelCancelled); notice = "Model installation cancelled. Previously verified assets were preserved." }
            catch { showError(Self.diagnosticMessage(error)) }
            progressTask.cancel(); await progressTask.value
            modelProgress = await installer.progress()
        }
    }
    func cancelModelInstall() { installTask?.cancel() }
    func sanityCheck() async {
        guard !isShuttingDown, !maintenanceBusy, modelReady, !running, !preparing, !sanityChecking, !modelInstalling, let modelCache else { return }
        sanityChecking = true
        localSanity = "Loading model and checking silence"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { sanityChecking = false; sanityTask = nil }
            do {
                try Task.checkCancellation()
                let transcriber = try await modelCache.transcriber(for: .localUser)
                do {
                    try Task.checkCancellation()
                    let output = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))
                    await transcriber.stop()
                    try Task.checkCancellation()
                    localSanity = output.text.isEmpty ? "Load + silence sanity passed. Speech accuracy is measured separately." : "Model loaded; silence produced text. Review the diagnostic and test speech before relying on answers."
                } catch { await transcriber.stop(); throw error }
            } catch is CancellationError { localSanity = "Sanity check cancelled" }
            catch { localSanity = Self.diagnosticMessage(error) }
        }
        sanityTask = task
        await task.value
    }
    func savePreferencesDebounced() {
        guard ready, !isShuttingDown, !maintenanceBusy, !stopping else { return }
        updateOverlay?()
        updateConnectionIfNeeded()
        coordinator?.updateContext(profile: preferences.selectedProfile, notes: sessionNotes, pinnedFacts: pinnedFacts,
            style: preferences.ai.answerStyle, language: preferences.ai.answerLanguage)
        guard preferences != (pendingPreferences ?? persistedPreferences) else { return }
        pendingPreferences = preferences; saveRevision &+= 1
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saveTask = nil }
            while !Task.isCancelled, !isShuttingDown, !maintenanceBusy {
                let revision = saveRevision
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard revision == saveRevision else { continue }
                guard let snapshot = pendingPreferences, !isShuttingDown, !maintenanceBusy else { return }
                do {
                    try Task.checkCancellation()
                    try await store.save(snapshot)
                    persistedPreferences = snapshot
                    if revision == saveRevision { pendingPreferences = nil; return }
                } catch is CancellationError { return }
                catch {
                    if !isShuttingDown, !maintenanceBusy { showError(Self.diagnosticMessage(error)) }
                    if revision == saveRevision { pendingPreferences = nil; return }
                }
            }
        }
    }
    func applyShortcuts() {
        guard !isShuttingDown, !maintenanceBusy else { return }
        hotkeyStatuses = hotkeys?.configure(preferences.shortcuts) ?? [:]
        savePreferencesDebounced()
    }
    func addProfile() {
        guard !isShuttingDown, !maintenanceBusy else { return }
        guard preferences.profiles.count < 20 else { showError("Up to 20 profiles can be stored."); return }
        let profile = UserProfile()
        preferences.profiles.append(profile); preferences.selectedProfileID = profile.id
        savePreferencesDebounced()
    }
    func removeSelectedProfile() {
        guard !isShuttingDown, !maintenanceBusy else { return }
        guard let id = preferences.selectedProfileID else { return }
        preferences.profiles.removeAll { $0.id == id }; preferences.selectedProfileID = nil
        savePreferencesDebounced()
    }
    func importProfile() {
        guard !isShuttingDown, !maintenanceBusy, importTask == nil, importPanel == nil else { return }
        guard let index = selectedProfileIndex else { showError("Select a profile before importing text."); return }
        let profileID = preferences.profiles[index].id
        importRevision &+= 1
        let revision = importRevision
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Import a text or Markdown copy into the selected profile. The source file is preserved."
        importPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            if importPanel === panel { importPanel = nil }
            guard response == .OK, let url = panel.url, revision == importRevision, !isShuttingDown, !maintenanceBusy else { return }
            importTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { importTask = nil }
                do {
                    let text = try await ProfileTextImporter.read(url: url)
                    try Task.checkCancellation()
                    guard revision == importRevision, !isShuttingDown, !maintenanceBusy,
                          let current = preferences.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                    preferences.profiles[current].importedContext = text
                    savePreferencesDebounced()
                } catch is CancellationError {} catch { if !isShuttingDown, !maintenanceBusy { showError(Self.diagnosticMessage(error)) } }
            }
        }
    }
    func exportRetainedTranscript() {
        guard !isShuttingDown, !maintenanceBusy, exportPanel == nil else { return }
        let retained = session.transcript
        guard !retained.isEmpty else { showError("There is no retained transcript to export."); return }
        let panel = NSSavePanel()
        exportPanel = panel
        panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Retained meeting excerpt.txt"
        let incomplete = session.contextLimited
        panel.begin { [weak self] response in
            guard let self else { return }
            if exportPanel === panel { exportPanel = nil }
            guard response == .OK, let url = panel.url, !isShuttingDown, !maintenanceBusy else { return }
            let header = "Retained meeting excerpt — \(incomplete ? "older context compacted/evicted" : "currently retained transcript; not a complete meeting recording")\n\n"
            let text = header + retained.map { "[\($0.source.label)] \($0.text)" }.joined(separator: "\n")
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { showError("The excerpt could not be exported. Choose a writable location.") }
        }
    }
    func clearLocalData() async {
        guard !isShuttingDown, !running, !preparing, !stopping, !maintenanceBusy else { showError("End the session before clearing local data."); return }
        maintenanceBusy = true
        let removeModels = clearModels
        let task = Task { [weak self] in
            guard let self else { return }
            await performClearLocalData(removeModels: removeModels)
        }
        maintenanceTask = task
        await task.value
    }
    private func performClearLocalData(removeModels: Bool) async {
        defer { maintenanceBusy = false; maintenanceTask = nil }
        let restartSetup = !ready
        sessionUIEpoch &+= 1; visualRevision &+= 1; visualSourcesRevision &+= 1; importRevision &+= 1; validationRevision &+= 1
        importPanel?.cancel(nil); importPanel = nil; exportPanel?.cancel(nil); exportPanel = nil
        pendingScreenCommit = nil; pendingConnection = nil
        let owned = [setupTask, installTask, sanityTask, validationTask, saveTask, credentialTask, importTask, applicationsTask, visualSourcesTask, screenTask, connectionTask].compactMap { $0 }
        for task in owned { task.cancel() }
        await activeValidationProvider?.cancelAll()
        for task in owned { await task.value }
        setupTask = nil; pendingPreferences = nil
        do {
            try await store.clearConfiguration()
            preferences = AppPreferences(); persistedPreferences = preferences
            sessionNotes = ""; pinnedFacts = ""; typedQuestion = ""
            visualSources = []; selectedVisualID = ""; visualRegion = nil; screenMode = .off
            desiredScreenMode = .off; desiredScreenSelection = nil
            try await credentials.delete()
            hasAPIKey = false; apiKeyDraft = ""
            await grokBuild.disconnect()
            guard await subscription.disconnect() else { throw OAuthError.localDeletionFailed }
            await modelCache?.clear()
            if removeModels { try await installer?.removeInstalledModel(); modelReady = false }
            recentErrors = []; errorMessage = nil
            apiValidation = "Not tested"; localSanity = "Not tested"
            await subscription.configure(subscriptionConfiguration)
            await connectionCredentials?.select(preferences.connectionMethod)
            lastConnectionSettings = preferences.connectionMethod.rawValue + "|" + subscriptionConfiguration.clientID
            hotkeyStatuses = hotkeys?.configure(preferences.shortcuts) ?? [:]
            notice = "Local settings, profiles and credential cleared. Previously exported or transmitted data is not recalled."
            if restartSetup, !isShuttingDown { maintenanceBusy = false; initialize() }
        } catch { showError(Self.diagnosticMessage(error)) }
    }
    func openPermissions(microphone: Bool = false) {
        guard !isShuttingDown, !maintenanceBusy else { return }
        let pane = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        FreelyLog.record(.appStopping)
        isShuttingDown = true
        importRevision &+= 1; validationRevision &+= 1; visualSourcesRevision &+= 1; visualRevision &+= 1
        hotkeys?.unregisterAll()
        importPanel?.cancel(nil); importPanel = nil; exportPanel?.cancel(nil); exportPanel = nil
        pendingScreenCommit = nil; pendingConnection = nil
        let latestPreferences = preferences
        let shouldPersist = ready && !maintenanceBusy && (pendingPreferences != nil || persistedPreferences != preferences)
        let owned = [setupTask, installTask, validationTask, sanityTask, saveTask, credentialTask, importTask, applicationsTask, visualSourcesTask, screenTask, connectionTask, maintenanceTask].compactMap { $0 }
        for task in owned { task.cancel() }
        let task = Task { [self] in
            await grokBuild.shutdown()
            await subscription.shutdown()
            await activeValidationProvider?.cancelAll()
            await stop()
            for task in owned { await task.value }
            if shouldPersist {
                do { try await store.save(latestPreferences); persistedPreferences = latestPreferences }
                catch { showError(Self.diagnosticMessage(error)) }
            }
            pendingPreferences = nil; apiKeyDraft = ""
            FreelyLog.record(.appStopped)
        }
        shutdownTask = task
        await task.value
    }
    func connectSubscription() {
        guard !isShuttingDown, !maintenanceBusy, !running, !preparing else { showError("End the session before changing its Grok connection."); return }
        if usesGrokBuild {
            grokBuild.connect(configuration: preferences.ai.transportConfiguration) { [weak self] connected in
                guard let self, !isShuttingDown else { return }
                preferences.grokBuildConnected = connected
                apiValidation = connected ? "Text streaming verified through your Grok subscription." : "Connection needs attention."
            }
        } else {
            subscription.signIn(configuration: subscriptionConfiguration, anchor: NSApp.keyWindow)
        }
    }
    func cancelSubscriptionConnection() {
        if usesGrokBuild { grokBuild.cancel() } else { subscription.cancel() }
    }
    func disconnectSubscription() async {
        guard !isShuttingDown, !running, !preparing, !maintenanceBusy else { showError("End the session before disconnecting Grok."); return }
        maintenanceBusy = true
        validationRevision &+= 1
        validationTask?.cancel(); connectionTask?.cancel(); pendingConnection = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { maintenanceBusy = false; maintenanceTask = nil }
            await activeValidationProvider?.cancelAll(); await validationTask?.value; await connectionTask?.value
            if usesGrokBuild {
                await grokBuild.disconnect(); preferences.grokBuildConnected = false
            } else { _ = await subscription.disconnect() }
            apiValidation = "Not tested"
        }
        maintenanceTask = task; await task.value
    }
    private func updateConnectionIfNeeded() {
        guard ready, !isShuttingDown, !maintenanceBusy else { return }
        let configuration = subscriptionConfiguration
        let method = preferences.connectionMethod
        let key = method.rawValue + "|" + configuration.clientID
        guard key != lastConnectionSettings else { return }
        lastConnectionSettings = key
        pendingConnection = (configuration, method, key)
        validationRevision &+= 1; validationTask?.cancel()
        apiValidation = "Not tested for the selected connection"
        guard connectionTask == nil else { return }
        connectionUpdating = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { connectionTask = nil; connectionUpdating = false }
            await activeValidationProvider?.cancelAll(); await validationTask?.value
            while let (configuration, method, key) = pendingConnection, !Task.isCancelled, !isShuttingDown, !maintenanceBusy {
                pendingConnection = nil
                await subscription.configure(configuration)
                guard !Task.isCancelled, !isShuttingDown, !maintenanceBusy else { return }
                guard key == lastConnectionSettings else { continue }
                await connectionCredentials?.select(method)
            }
        }
    }
    func showError(_ message: String) {
        FreelyLog.record(.errorPresented, level: .warning)
        errorMessage = message
        if recentErrors.last != message { recentErrors.append(message) }
        if recentErrors.count > 30 { recentErrors.removeFirst(recentErrors.count - 30) }
    }
    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .startStopSession: if running || preparing { Task { await stop() } } else { start() }
        case .toggleOverlay: toggleOverlay?()
        case .answerNow: answerNow()
        case .captureAnalyze: answerNow(captureVisual: true)
        case .expandCollapse: toggleExpanded()
        case .clearAnswer: clearAnswer()
        case .pinUnpin: setPinned(!pinned)
        case .pauseResumeMicrophone: toggleSource(.localUser)
        case .pauseResumeSystemAudio: toggleSource(.systemAudio)
        case .endSession: Task { await stop() }
        }
    }
    private static func diagnosticMessage(_ error: Error, operation: StaticString = #function) -> String {
        FreelyLog.record(.operationFailed, level: .error, fields: [.state: .state(operation), .failure: .failure(error)])
        return message(error)
    }
    static func message(_ error: Error) -> String {
        if let value = error as? AppError { return value.userAction }
        if let value = error as? LocalizedError, let message = value.errorDescription { return message }
        return "The operation could not complete. Review setup and retry."
    }
    /// Only fixed native domains and numeric codes enter diagnostics; descriptions/userInfo can contain private window titles or paths.
    static func captureFailureCode(_ error: Error) -> String {
        let native = error as NSError
        let allowed: Set<String> = [SCStreamErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain]
        let domain = allowed.contains(native.domain) ? native.domain : "OtherNativeError"
        return "\(domain) (\(native.code))"
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case setup = "Setup", session = "Session", ai = "AI", audio = "Audio / STT", context = "Context", overlay = "Overlay / Shortcuts", privacy = "Privacy", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: "checklist"
        case .session: "waveform"
        case .ai: "sparkle"
        case .audio: "mic"
        case .context: "person.text.rectangle"
        case .overlay: "rectangle.on.rectangle"
        case .privacy: "hand.raised"
        case .diagnostics: "gauge.with.dots.needle.33percent"
        }
    }
}
