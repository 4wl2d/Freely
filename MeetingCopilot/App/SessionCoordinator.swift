import AppKit
import CopilotCore
import Foundation
import os

struct SessionViewState: Sendable {
    var phase = SessionPhase.idle
    var sources: [AudioSource: SourceStatus] = [:]
    var metrics: [AudioSource: SourceProcessingMetrics] = [:]
    var transcript: [TranscriptSegment] = []
    var turns: [ConversationTurn] = []
    var contextLimited = false
    var gapCount = 0
    var summaryCoverage = "None"
    var lastQuestion: QuestionState?
    var error: String?
    var teardownSeconds: Double?
}

struct ScreenIntentToken: Sendable, Equatable {
    let sessionEpoch: SessionEpoch
    let revision: UInt64
}

/// Each source has one transition task and one newest desired state. Replacing an intent never
/// loses ownership of a still-cancelling capture/model operation. Epochs fence before any await.
@MainActor
final class SessionCoordinator {
    private var lifecycle = SessionLifecycle()
    private let microphone: any MicrophoneCapturing
    private let system: any SystemAudioCapturing
    private let makeTranscriber: @Sendable (AudioSource) async throws -> any SpeechTranscribing
    private let makeProvider: @Sendable (AIPreferences, SharedRequestBudget) -> any LLMProviding
    let conversation = ConversationEngine()
    let screen: NativeScreenCapture
    private let rateBudget: SharedRequestBudget
    private let onState: @MainActor (SessionViewState) -> Void
    private let onAnswer: @MainActor (AnswerPresentation, GenerationDiagnostics) -> Void
    private var generation: GenerationCoordinator?
    private var state = SessionViewState()
    private var preferences = AppPreferences()
    private var transcriptionOnly = false
    private var sourceEpochs: [AudioSource: UInt64] = [.localUser: 0, .systemAudio: 0]
    private var desiredRunning: [AudioSource: Bool] = [:]
    private var desiredRevision: [AudioSource: UInt64] = [:]
    private var desiredFailure: [AudioSource: String] = [:]
    private var ingresses: [AudioSource: AudioIngress] = [:]
    private var pipelines: [AudioSource: SourcePipeline] = [:]
    private var workers: [AudioSource: Task<Void, Never>] = [:]
    private struct SourceOperation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var sourceOperations: [AudioSource: SourceOperation] = [:]
    private var preparingTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var monitorTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var sessionOrigin = 0.0
    private var lastSourceCheck = 0.0
    private var applicationSelection: SystemAudioSelection?
    private var selectedScreen: ScreenSelection?
    private var pausedAt: [AudioSource: Double] = [:]
    private let logger = Logger(subsystem: "local.meetingcopilot.app", category: "session")

    convenience init(modelCache: LocalSpeechModelCache, credentials: any CredentialStoring,
         rateBudget: SharedRequestBudget,
         microphone: any MicrophoneCapturing = NativeMicrophoneCapture(),
         system: any SystemAudioCapturing = NativeSystemAudioCapture(),
         onState: @escaping @MainActor (SessionViewState) -> Void,
         onAnswer: @escaping @MainActor (AnswerPresentation, GenerationDiagnostics) -> Void) {
        self.init(credentials: credentials, rateBudget: rateBudget, microphone: microphone, system: system,
            makeTranscriber: { source in try await modelCache.transcriber(for: source) },
            onState: onState, onAnswer: onAnswer)
    }
    /// Real composition above supplies the local model cache. Tests substitute only the inference acquisition boundary.
    init(credentials: any CredentialStoring, rateBudget: SharedRequestBudget,
         microphone: any MicrophoneCapturing = NativeMicrophoneCapture(),
         system: any SystemAudioCapturing = NativeSystemAudioCapture(), screen: NativeScreenCapture = .init(),
         makeTranscriber: @escaping @Sendable (AudioSource) async throws -> any SpeechTranscribing,
         makeProvider: (@Sendable (AIPreferences, SharedRequestBudget) -> any LLMProviding)? = nil,
         onState: @escaping @MainActor (SessionViewState) -> Void,
         onAnswer: @escaping @MainActor (AnswerPresentation, GenerationDiagnostics) -> Void) {
        self.makeTranscriber = makeTranscriber; self.rateBudget = rateBudget
        self.microphone = microphone; self.system = system; self.screen = screen
        self.onState = onState; self.onAnswer = onAnswer
        self.makeProvider = makeProvider ?? { options, budget in
            XAILLMProvider(credentials: credentials, configuration: options.transportConfiguration,
                approveRequestStart: { try await budget.acquire() })
        }
    }
    var phase: SessionPhase { lifecycle.phase }
    var activeEpoch: SessionEpoch { lifecycle.epoch }
    var isActive: Bool { lifecycle.phase != .idle && lifecycle.phase != .stopping }
    var ownedTaskCount: Int {
        workers.count + sourceOperations.count + (preparingTask == nil ? 0 : 1) +
        (monitorTask == nil ? 0 : 1) + (stoppingTask == nil ? 0 : 1) + (generation?.ownedTaskCount ?? 0)
    }
    func currentSourceEpoch(_ source: AudioSource) -> SourceEpoch { .init(sourceEpochs[source, default: 0]) }

    func start(preferences: AppPreferences, sessionNotes: String, pinnedFacts: String, transcriptionOnly: Bool) {
        guard lifecycle.phase == .idle, stoppingTask == nil else { return }
        guard preferences.audio.microphoneEnabled || preferences.audio.systemAudioEnabled else {
            state.error = "Select at least one audio source before starting."; publish(); return
        }
        guard let epoch = lifecycle.start(), let sessionID = lifecycle.sessionID else { return }
        self.preferences = preferences; self.transcriptionOnly = transcriptionOnly
        state = SessionViewState(phase: .preparing)
        sessionOrigin = ProcessInfo.processInfo.systemUptime; lastSourceCheck = 0
        applicationSelection = nil; desiredFailure = [:]
        for source in AudioSource.allCases {
            desiredRunning[source] = enabled(source); desiredRevision[source] = 0
            lifecycle.setSource(source, status: enabled(source) ? .preparing : .stopped, epoch: epoch)
        }
        let generator = GenerationCoordinator(conversation: conversation, screen: screen,
            provider: makeProvider(preferences.ai, rateBudget), rateBudget: rateBudget,
            sessionEpoch: epoch, sessionID: sessionID, sessionOrigin: sessionOrigin,
            options: preferences.ai, initialScreenSelection: selectedScreen, onChange: { [weak self] answer, diagnostics in
                guard let self, self.lifecycle.epoch == epoch, self.lifecycle.phase != .stopping else { return }
                self.onAnswer(answer, diagnostics)
            })
        generator.configureContext(profile: preferences.selectedProfile, notes: sessionNotes, pinnedFacts: pinnedFacts,
            answerStyle: preferences.ai.answerStyle, answerLanguage: preferences.ai.answerLanguage)
        generation = generator
        publish()
        let preparation = UUID(); preparationID = preparation
        preparingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if preparationID == preparation { preparingTask = nil; preparationID = nil }
            }
            await conversation.begin(sessionID: sessionID, epoch: epoch,
                triggerLocalSpeech: preferences.ai.localSpeechTriggersAnswers)
            await rateBudget.configure(limit: preferences.ai.requestsPerMinute)
            guard lifecycle.accepts(epoch), !Task.isCancelled else { return }
            var prepared: [AudioSource: any SpeechTranscribing] = [:]
            for source in AudioSource.allCases where enabled(source) {
                do {
                    let transcriber = try await makeTranscriber(source)
                    guard lifecycle.accepts(epoch), !Task.isCancelled else { await transcriber.stop(); break }
                    prepared[source] = transcriber
                } catch is CancellationError { break }
                catch { setSourceFailure(source, message: Self.message(error), epoch: epoch) }
            }
            guard lifecycle.accepts(epoch), !Task.isCancelled else {
                for transcriber in prepared.values { await transcriber.stop() }
                return
            }
            for source in AudioSource.allCases {
                guard let transcriber = prepared[source] else { continue }
                await startSource(source, transcriber: transcriber, epoch: epoch)
            }
            guard lifecycle.accepts(epoch), !Task.isCancelled else { return }
            _ = lifecycle.ready(epoch: epoch)
            if !lifecycle.sources.values.contains(.running) {
                _ = lifecycle.recovering(epoch: epoch)
                state.error = state.error ?? "No selected source could start. Fix the indicated setup issue and resume a source."
            }
            logger.info("Session prepared; active sources=\(self.lifecycle.sources.values.filter { $0 == .running }.count)")
            publish(); startMonitoring(epoch: epoch)
        }
    }

    private func startSource(_ source: AudioSource, transcriber: any SpeechTranscribing, epoch: SessionEpoch) async {
        guard lifecycle.accepts(epoch), desiredRunning[source] == true, !Task.isCancelled else { await transcriber.stop(); return }
        let sourceEpoch = invalidateSource(source)
        await conversation.setSourceEpoch(sourceEpoch, source: source, sessionEpoch: epoch)
        guard lifecycle.accepts(epoch), desiredRunning[source] == true, !Task.isCancelled else { await transcriber.stop(); return }
        let ingress = AudioIngress(); ingresses[source] = ingress
        let pipeline = SourcePipeline(source: source, streamEpoch: sourceEpoch, ingress: ingress,
            transcriber: transcriber, sessionOrigin: sessionOrigin)
        do {
            if source == .localUser {
                try await microphone.start(deviceID: preferences.audio.microphoneDeviceUID, ingress: ingress)
            } else {
                let selection: SystemAudioSelection
                if preferences.audio.systemScope == .allSystemAudio { selection = .allSystemAudio }
                else {
                    guard let bundleID = preferences.audio.applicationBundleID else { throw AudioCaptureError.noApplication }
                    let available = try await NativeSystemAudioCapture.applications()
                    guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue, !Task.isCancelled else { throw CancellationError() }
                    selection = try Self.applicationSelection(bundleID: bundleID, from: available)
                }
                applicationSelection = selection
                try await system.start(selection: selection, ingress: ingress)
            }
            guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue,
                  desiredRunning[source] == true, !Task.isCancelled else { throw CancellationError() }
            pipelines[source] = pipeline; state.metrics[source] = nil
            lifecycle.setSource(source, status: .running, epoch: epoch)
            if let pauseTime = pausedAt.removeValue(forKey: source) {
                await receive(.gap(.init(source: source, streamEpoch: sourceEpoch,
                    startTime: pauseTime, endTime: elapsed, cause: .paused)), source: source, epoch: epoch, sourceEpoch: sourceEpoch)
            }
            guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue, !Task.isCancelled else { throw CancellationError() }
            workers[source] = Task { [weak self, pipeline] in
                await pipeline.run { [weak self] event in
                    await self?.receive(event, source: source, epoch: epoch, sourceEpoch: sourceEpoch)
                }
                guard let self, lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue,
                      !Task.isCancelled else { return }
                let metrics = await pipeline.snapshot()
                guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue, !Task.isCancelled else { return }
                if let failure = metrics.failure {
                    setSourceFailure(source, message: failure, epoch: epoch)
                    await stopNative(source)
                    // run() has returned; decoder cleanup cannot overlap an in-flight prediction.
                    await pipeline.stop()
                    guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue else { return }
                    workers[source] = nil; pipelines[source] = nil; ingresses[source] = nil
                    if !lifecycle.sources.values.contains(.running) { _ = lifecycle.recovering(epoch: epoch) }
                    publish()
                }
            }
        } catch {
            ingress.close(); await stopNative(source); await pipeline.stop()
            if sourceEpochs[source] == sourceEpoch.rawValue { ingresses[source] = nil; pipelines[source] = nil }
            if !(error is CancellationError), !Task.isCancelled, lifecycle.accepts(epoch) {
                setSourceFailure(source, message: Self.message(error), epoch: epoch)
            }
        }
    }
    /// Explicit ingress identity checks also cover callbacks already suspended on the conversation actor.
    func receive(_ event: TranscriptEvent, source: AudioSource, epoch: SessionEpoch, sourceEpoch: SourceEpoch) async {
        guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue else { return }
        let eventSource: AudioSource, eventEpoch: SourceEpoch
        switch event {
        case .upsert(let segment), .insert(let segment), .update(let segment), .finalize(let segment), .revise(let segment):
            eventSource = segment.source; eventEpoch = segment.streamEpoch
        case .retract(_, let source, let stream, _, _): eventSource = source; eventEpoch = stream
        case .gap(let gap): eventSource = gap.source; eventEpoch = gap.streamEpoch
        }
        guard eventSource == source, eventEpoch == sourceEpoch else { return }
        let update = await conversation.apply(event, sessionEpoch: epoch, now: elapsed)
        guard lifecycle.accepts(epoch), sourceEpochs[source] == sourceEpoch.rawValue else { return }
        if update.result == .accepted {
            switch event {
            case .upsert(let segment), .insert(let segment), .update(let segment), .finalize(let segment), .revise(let segment):
                if segment.finality == .final {
                    CopilotLog.transcript.info("Final transcript event; id=\(segment.id.rawValue.uuidString, privacy: .public), source=\(segment.source.rawValue, privacy: .public), revision=\(segment.revision)")
                }
            default: break
            }
        }
        apply(update)
    }
    private func apply(_ update: ConversationUpdate) {
        if let contextID = update.invalidatedContextID { generation?.contextInvalidated(contextID) }
        state.transcript = update.segments; state.turns = update.turns
        state.contextLimited = update.contextLimited; state.gapCount = update.gaps.count
        for questionID in update.invalidatedQuestionIDs { generation?.questionInvalidated(questionID) }
        if !transcriptionOnly { generation?.observeTranscript(update, now: elapsed) }
        if let question = update.newQuestion {
            state.lastQuestion = question
            if preferences.ai.automaticAnswers, !transcriptionOnly { generation?.request(question: question, manual: false) }
        }
        publish()
    }
    private func startMonitoring(epoch: SessionEpoch) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                guard let self, lifecycle.epoch == epoch, lifecycle.phase != .stopping, lifecycle.phase != .idle else { break }
                let snapshot = Array(pipelines)
                for (source, pipeline) in snapshot {
                    let expected = pipeline.streamEpoch.rawValue
                    let value = await pipeline.snapshot()
                    guard lifecycle.epoch == epoch, !Task.isCancelled else { return }
                    if sourceEpochs[source] == expected { state.metrics[source] = value }
                }
                if lifecycle.phase != .paused {
                    let update = await conversation.tick(now: elapsed, sessionEpoch: epoch)
                    guard lifecycle.accepts(epoch), !Task.isCancelled else { continue }
                    if !transcriptionOnly { generation?.observeTranscript(update, now: elapsed) }
                    if update.newQuestion != nil || !update.invalidatedQuestionIDs.isEmpty { apply(update) }
                    if elapsed - lastSourceCheck >= 1 {
                        lastSourceCheck = elapsed
                        if case .application(let pid, _) = applicationSelection,
                           NSRunningApplication(processIdentifier: pid)?.isTerminated != false,
                           lifecycle.sources[.systemAudio] == .running {
                            requestSourceState(.systemAudio, running: false,
                                failure: "The selected meeting application closed. Reopen it and resume system audio.")
                        }
                        if !transcriptionOnly { await generation?.compactIfNeeded(now: elapsed) }
                        guard lifecycle.epoch == epoch, !Task.isCancelled else { return }
                        if let summary = await conversation.rollingSummary() {
                            guard lifecycle.epoch == epoch, !Task.isCancelled else { return }
                            state.summaryCoverage = summary.coveredSequenceRange.map { "Sequences \($0.lowerBound)–\($0.upperBound)" } ?? "Incomplete"
                            if summary.isExtractiveFallback { state.summaryCoverage += " · extractive fallback" }
                        }
                    }
                }
                publish()
            }
        }
    }
    func toggleSource(_ source: AudioSource) {
        guard lifecycle.phase != .idle, lifecycle.phase != .preparing, lifecycle.phase != .stopping else { return }
        let running = sourceOperations[source] == nil ? lifecycle.sources[source] != .running : !(desiredRunning[source] ?? false)
        if running, lifecycle.phase == .paused { _ = lifecycle.resume() }
        requestSourceState(source, running: running)
    }
    private func requestSourceState(_ source: AudioSource, running: Bool, failure: String? = nil) {
        guard lifecycle.phase != .idle, lifecycle.phase != .stopping else { return }
        desiredRunning[source] = running; desiredRevision[source, default: 0] &+= 1
        desiredFailure[source] = failure
        if !running {
            _ = invalidateSource(source)
            sourceOperations[source]?.task.cancel()
            if let failure { setSourceFailure(source, message: failure, epoch: lifecycle.epoch) }
            else { lifecycle.setSource(source, status: .paused, epoch: lifecycle.epoch) }
        } else { lifecycle.setSource(source, status: .preparing, epoch: lifecycle.epoch) }
        if !desiredRunning.values.contains(true), lifecycle.phase == .running || lifecycle.phase == .recovering { _ = lifecycle.pause() }
        if sourceOperations[source] == nil { launchSourceOperation(source, epoch: lifecycle.epoch) }
        publish()
    }
    private func launchSourceOperation(_ source: AudioSource, epoch: SessionEpoch) {
        let id = UUID()
        let preparation = preparingTask
        let operation = Task { [weak self] in
            await preparation?.value
            guard let self else { return }
            let revision = desiredRevision[source, default: 0]
            await releaseSource(source, epoch: epoch)
            if lifecycle.accepts(epoch), desiredRevision[source] == revision, desiredRunning[source] == true, !Task.isCancelled {
                lifecycle.setSource(source, status: .preparing, epoch: epoch); publish()
                do {
                    let transcriber = try await makeTranscriber(source)
                    if lifecycle.accepts(epoch), desiredRevision[source] == revision, desiredRunning[source] == true, !Task.isCancelled {
                        await startSource(source, transcriber: transcriber, epoch: epoch)
                    } else { await transcriber.stop() }
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { setSourceFailure(source, message: Self.message(error), epoch: epoch) }
                }
            }
            guard sourceOperations[source]?.id == id else { return }
            sourceOperations[source] = nil
            guard lifecycle.epoch == epoch, lifecycle.phase != .stopping, lifecycle.phase != .idle else { return }
            if desiredRevision[source] != revision || (Task.isCancelled && desiredRunning[source] == true && lifecycle.phase != .paused) {
                launchSourceOperation(source, epoch: epoch)
            } else if desiredRunning[source] != true {
                if let failure = desiredFailure[source] { setSourceFailure(source, message: failure, epoch: epoch) }
                else { lifecycle.setSource(source, status: .paused, epoch: epoch) }
            }
            if lifecycle.phase == .recovering, lifecycle.sources.values.contains(.running) { _ = lifecycle.ready(epoch: epoch) }
            if lifecycle.phase == .running, !lifecycle.sources.values.contains(.running), desiredRunning.values.contains(true) { _ = lifecycle.recovering(epoch: epoch) }
            publish()
        }
        sourceOperations[source] = SourceOperation(id: id, task: operation)
    }
    @discardableResult private func invalidateSource(_ source: AudioSource) -> SourceEpoch {
        sourceEpochs[source, default: 0] &+= 1
        workers[source]?.cancel(); ingresses[source]?.close()
        return .init(sourceEpochs[source, default: 0])
    }
    private func releaseSource(_ source: AudioSource, epoch: SessionEpoch) async {
        let sourceEpoch = invalidateSource(source)
        pausedAt[source] = pausedAt[source] ?? elapsed
        let worker = workers.removeValue(forKey: source)
        let pipeline = pipelines.removeValue(forKey: source)
        let ingress = ingresses.removeValue(forKey: source)
        worker?.cancel(); ingress?.close()
        await conversation.setSourceEpoch(sourceEpoch, source: source, sessionEpoch: epoch)
        await stopNative(source)
        // Cancellation stops scheduling/iteration. Await prediction quiescence before cleaning model state.
        await worker?.value
        await pipeline?.stop()
    }
    func pauseAllForSystemEvent() async {
        pauseAll()
        let owned = sourceOperations.values.map(\.task)
        for operation in owned { await operation.value }
        if lifecycle.phase == .paused {
            state.error = "Capture paused for sleep or screen lock. Resume explicitly when ready."; publish()
        }
    }
    private func pauseAll() {
        if lifecycle.phase == .preparing {
            _ = lifecycle.ready(epoch: lifecycle.epoch)
            preparingTask?.cancel()
        }
        guard lifecycle.pause() else { return }
        generation?.cancelForeground()
        for source in AudioSource.allCases { requestSourceState(source, running: false) }
        startMonitoring(epoch: lifecycle.epoch)
        publish()
    }
    func pauseOrResume() {
        if lifecycle.phase == .paused {
            _ = lifecycle.resume()
            for source in AudioSource.allCases where enabled(source) { requestSourceState(source, running: true) }
        } else { pauseAll() }
        publish()
    }
    func answerNow(text: String, captureVisual: Bool = false, detailed: Bool = false) {
        guard preparingTask == nil, lifecycle.phase == .running || lifecycle.phase == .recovering else {
            state.error = "Wait for session preparation, or start/resume a session before asking for an answer."; publish(); return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let question: QuestionState
        if !trimmed.isEmpty { question = QuestionState(text: trimmed, triggerReason: .manual) }
        else if let last = state.lastQuestion { question = last }
        else {
            let latestTurns = state.turns.suffix(3)
            guard !latestTurns.isEmpty || captureVisual else { state.error = "Type a question or wait for conversation context."; publish(); return }
            question = QuestionState(supportingTurnIDs: latestTurns.map(\.id),
                text: captureVisual ? "Explain the selected screen and answer the current conversation question." : "What is the most useful response to the current conversation?",
                triggerReason: .manual)
        }
        generation?.request(question: question, manual: true, captureVisual: captureVisual, detailed: detailed)
    }
    func updateContext(profile: UserProfile?, notes: String, pinnedFacts: String, style: AnswerStyle, language: String) {
        generation?.configureContext(profile: profile, notes: notes, pinnedFacts: pinnedFacts, answerStyle: style, answerLanguage: language)
    }
    func updateSourceSettings(_ audio: AudioPreferences) {
        let microphoneStatus = lifecycle.sources[.localUser]
        if microphoneStatus != .running, microphoneStatus != .preparing {
            preferences.audio.microphoneDeviceUID = audio.microphoneDeviceUID
            preferences.audio.microphoneEnabled = audio.microphoneEnabled
        }
        let systemStatus = lifecycle.sources[.systemAudio]
        if systemStatus != .running, systemStatus != .preparing {
            preferences.audio.systemScope = audio.systemScope
            preferences.audio.applicationBundleID = audio.applicationBundleID
            preferences.audio.systemAudioEnabled = audio.systemAudioEnabled
        }
    }
    @discardableResult func prepareScreenConsent(_ mode: ScreenContextMode) -> ScreenIntentToken {
        .init(sessionEpoch: lifecycle.epoch, revision: generation?.prepareScreenMode(mode) ?? 0)
    }
    @discardableResult func prepareScreenSelection(_ selection: ScreenSelection?) -> ScreenIntentToken {
        selectedScreen = selection
        return .init(sessionEpoch: lifecycle.epoch, revision: generation?.prepareScreenSelection(selection) ?? 0)
    }
    func setScreenConsent(_ mode: ScreenContextMode, prepared token: ScreenIntentToken? = nil) async {
        if let token {
            guard token.sessionEpoch == lifecycle.epoch else { return }
            await generation?.setScreenMode(mode, preparedRevision: token.revision)
        } else { await generation?.setScreenMode(mode) }
    }
    func selectScreen(_ selection: ScreenSelection?, prepared token: ScreenIntentToken? = nil) async {
        if let token {
            guard token.sessionEpoch == lifecycle.epoch, selectedScreen == selection else { return }
            if let generation { await generation.setScreenSelection(selection, preparedRevision: token.revision) }
            else if !Task.isCancelled { await screen.select(selection) }
        } else {
            selectedScreen = selection
            if let generation { await generation.setScreenSelection(selection) } else { await screen.select(selection) }
        }
    }
    func pinAnswer(_ pinned: Bool) { if pinned { generation?.pin() } else { generation?.unpin() } }
    func clearAnswer() { generation?.clear() }

    func stop() async {
        if let stoppingTask { await stoppingTask.value; return }
        guard let invalidated = lifecycle.stop() else { return }
        let stopStart = ProcessInfo.processInfo.systemUptime
        let generator = generation, preparation = preparingTask, monitor = monitorTask
        let operations = sourceOperations.values.map(\.task), ownedWorkers = Array(workers.values)
        let ownedPipelines = Array(pipelines.values)
        generator?.invalidateSession(); preparation?.cancel(); monitor?.cancel()
        for operation in operations { operation.cancel() }
        for worker in ownedWorkers { worker.cancel() }
        for ingress in ingresses.values { ingress.close() }
        desiredRunning = [:]
        publish()
        let termination = Task { [self] in
            async let stopMicrophone: Void = microphone.stop()
            async let stopSystem: Void = system.stop()
            await stopMicrophone; await stopSystem
            await preparation?.value
            for operation in operations { await operation.value }
            for worker in ownedWorkers { await worker.value }
            await monitor?.value
            for pipeline in ownedPipelines { await pipeline.stop() }
            await generator?.stop()
            await conversation.stop(epoch: invalidated); await screen.clear()
            preparingTask = nil; preparationID = nil; monitorTask = nil
            workers = [:]; sourceOperations = [:]; pipelines = [:]; ingresses = [:]
            generation = nil; pausedAt = [:]; desiredRevision = [:]; desiredFailure = [:]
            applicationSelection = nil
            lifecycle.didStop(epoch: invalidated)
            state = SessionViewState(teardownSeconds: ProcessInfo.processInfo.systemUptime - stopStart)
            onAnswer(AnswerPresentation(), GenerationDiagnostics(status: "Session ended"))
            logger.info("Session stopped; seconds=\(self.state.teardownSeconds ?? 0)")
            publish(); stoppingTask = nil
        }
        stoppingTask = termination
        await termination.value
    }
    private func stopNative(_ source: AudioSource) async {
        if source == .localUser { await microphone.stop() } else { await system.stop() }
    }
    private func enabled(_ source: AudioSource) -> Bool {
        source == .localUser ? preferences.audio.microphoneEnabled : preferences.audio.systemAudioEnabled
    }
    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - sessionOrigin }
    private func setSourceFailure(_ source: AudioSource, message: String, epoch: SessionEpoch) {
        guard lifecycle.accepts(epoch) else { return }
        lifecycle.setSource(source, status: .failed(AppError(domain: .audio, category: .unavailable,
            userAction: message, diagnosticCode: "source_unavailable")), epoch: epoch)
        state.error = "\(source.label): \(message)"; publish()
    }
    private func publish() {
        state.phase = lifecycle.phase; state.sources = lifecycle.sources; onState(state)
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? AppError { return error.userAction }
        if let error = error as? LocalizedError, let message = error.errorDescription { return message }
        return "The selected source could not start. Check permissions, device and model, then resume."
    }
    static func applicationSelection(bundleID: String, from applications: [AudioApplication]) throws -> SystemAudioSelection {
        let matches = applications.filter { $0.bundleID == bundleID }
        guard !matches.isEmpty else { throw AudioCaptureError.noApplication }
        guard matches.count == 1 else {
            throw AudioCaptureError.configuration("Several running applications share that identifier. Close extra instances and select the intended meeting application again.")
        }
        return .application(pid: matches[0].id, bundleID: bundleID)
    }
}
