import FreelyCore
import Foundation
import os

actor SharedRequestBudget {
    private var limit = 12
    func configure(limit: Int) {
        // Rate history survives settings changes; a new session cannot reset this app-wide budget.
        self.limit = max(1, min(120, limit))
    }
    private var starts: [Double] = []
    private var backoffUntil = 0.0
    func acquire() throws {
        let now = ProcessInfo.processInfo.systemUptime
        starts.removeAll { $0 <= now - 60 }
        guard now >= backoffUntil else { throw XAIError.rateLimited(retryAfter: backoffUntil - now) }
        guard starts.count < limit else { throw XAIError.localRateLimited }
        starts.append(now)
    }
    func backoff(for seconds: Double) { backoffUntil = max(backoffUntil, ProcessInfo.processInfo.systemUptime + seconds) }
}

struct GenerationDiagnostics: Sendable {
    var requestID: UUID?
    var status = "Idle"
    var inputEstimate = 0
    /// Submission precedes credential lookup and request-budget approval; this is not HTTP start.
    var submittedAt: Double?
    var firstTextSeconds: Double?
    var endToVisibleSeconds: Double?
    var usage: LLMUsage?
    var usesVisual = false
    var contextLimited = false
}

struct SpeculationDiagnostics: Sendable {
    var requests = 0
    var reused = 0
    var discarded = 0
    var reportedInputTokens = 0
    var reportedOutputTokens = 0
    var usageSamples = 0
}

/// MainActor owns only arbitration and presentation. Context building, image encoding and
/// native network transport remain in their actors. One foreground task is cancelled and awaited
/// before its replacement starts, including the underlying URLSession producer.
@MainActor
final class GenerationCoordinator {
    private let conversation: ConversationEngine
    private let screen: NativeScreenCapture
    private let provider: any LLMProviding
    private let rateBudget: SharedRequestBudget
    private let sessionEpoch: SessionEpoch
    private let sessionID: SessionID
    private let sessionOrigin: Double
    private let onChange: @MainActor (AnswerPresentation, GenerationDiagnostics) -> Void
    private var fence = GenerationFence()
    private var presentation = AnswerPresentation()
    private var diagnostics = GenerationDiagnostics()
    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryID: UUID?
    private struct Intent {
        let question: QuestionState
        let manual: Bool
        let visual: Bool
        let detailed: Bool
        let speculative: Bool
        let createdAt: Double
    }
    private var pending: Intent?
    private var runningIdentity: GenerationIdentity?
    private var nextSummaryAttemptAt = 0.0
    private var summaryFailures = 0
    private var screenSelection: ScreenSelection?
    private var screenIntentRevision: UInt64 = 0
    private var speculation = SpeculationGate()
    private var speculativeQuestion: QuestionState?
    private var speculationConfirmed = false
    private var speculativeText = ""
    private var speculativeUsage: LLMUsage?
    private var speculativeCompleted = false
    private var lastSpeculatedTurnID: TurnID?
    private var prefixCandidate: (id: TurnID, material: String, since: Double)?
    private(set) var speculationDiagnostics = SpeculationDiagnostics()
    private var activeManual = false
    private var activeVisual = false
    private var active = true
    private var contextConfiguration = ContextConfiguration()
    private var contextHistoryNeedsPurge = false
    private var profile: UserProfile?
    private var screenMode = ScreenContextMode.off
    private var options: AIPreferences
    private var outputPending = ""
    private var outputIdentity: GenerationIdentity?
    private var lastUIUpdate = 0.0
    private var activeQuestionEnd: Double?
    private var activeContextID: UUID?
    private func trace(_ name: DiagnosticName, _ identity: GenerationIdentity, level: DiagnosticLevel = .info,
                       fields: [DiagnosticField: DiagnosticValue] = [:], duration: Double? = nil) {
        FreelyLog.record(name, level: level, scope: .init(session: sessionID.rawValue, request: identity.generationID.rawValue), fields: fields, duration: duration)
    }

    init(conversation: ConversationEngine, screen: NativeScreenCapture, provider: any LLMProviding,
         rateBudget: SharedRequestBudget, sessionEpoch: SessionEpoch, sessionID: SessionID,
         sessionOrigin: Double, options: AIPreferences, initialScreenSelection: ScreenSelection? = nil,
         onChange: @escaping @MainActor (AnswerPresentation, GenerationDiagnostics) -> Void) {
        self.conversation = conversation; self.screen = screen; self.provider = provider
        self.rateBudget = rateBudget; self.sessionEpoch = sessionEpoch; self.sessionID = sessionID
        self.sessionOrigin = sessionOrigin; self.options = options; self.onChange = onChange
        self.screenSelection = initialScreenSelection
        self.speculation.enabled = options.experimentalSpeculation
        self.contextConfiguration = ContextConfiguration(answerStyle: options.answerStyle,
            answerLanguage: options.answerLanguage, modelContextLimit: options.modelContextLimit,
            outputReserve: options.normalOutputTokens)
    }
    func configureContext(profile: UserProfile?, notes: String, pinnedFacts: String,
                          answerStyle: AnswerStyle, answerLanguage: String) {
        guard active else { return }
        let changed = self.profile != profile || contextConfiguration.sessionNotes != notes ||
            contextConfiguration.pinnedFacts != pinnedFacts || contextConfiguration.answerStyle != answerStyle ||
            contextConfiguration.answerLanguage != answerLanguage
        guard changed else { return }
        // A deselected profile or edited instruction cannot survive inside a previously prepared payload.
        let hadAnswer = task != nil || pending != nil || presentation.displayed != nil || speculativeQuestion != nil
        invalidateForeground(clearPending: true)
        presentation.clear()
        if hadAnswer { diagnostics = .init(status: "Context changed · request an updated answer") }
        contextHistoryNeedsPurge = true
        self.profile = profile
        contextConfiguration = ContextConfiguration(sessionNotes: notes, pinnedFacts: pinnedFacts,
            answerStyle: answerStyle, answerLanguage: answerLanguage,
            modelContextLimit: options.modelContextLimit, outputReserve: options.normalOutputTokens)
        publish()
    }
    var ownedTaskCount: Int { (task == nil ? 0 : 1) + (summaryTask == nil ? 0 : 1) }
    var hasPendingIntent: Bool { pending != nil }

    /// Prefix experiments use the same serialized provider owner and remain off by default.
    /// No prefix text becomes visible until the final question confirms its exact material revision.
    func observeTranscript(_ update: ConversationUpdate, now: Double) {
        guard active, options.experimentalSpeculation, options.automaticAnswers else { return }
        if let speculativeQuestion, !speculationConfirmed {
            guard let turn = update.turns.first(where: { speculativeQuestion.supportingTurnIDs.contains($0.id) }),
                  update.turns.last(where: { $0.source == .systemAudio })?.id == turn.id,
                  IntentHeuristics.materialText(turn.text) == IntentHeuristics.materialText(speculativeQuestion.text),
                  !turn.hasAudioGap else { cancelForeground(); return }
            if turn.isFinal { activeQuestionEnd = turn.endTime }
            if let candidate = prefixCandidate, now - candidate.since > 10 { cancelForeground() }
            return
        }
        guard task == nil, pending == nil, !activeManual,
              let turn = update.turns.last(where: { $0.source == .systemAudio }), !turn.isFinal, !turn.hasAudioGap,
              now - turn.endTime <= 2,
              turn.id != lastSpeculatedTurnID, !Self.needsScreen(turn.text),
              turn.text.split(whereSeparator: \.isWhitespace).count >= 6,
              IntentHeuristics.classify(turn.text, hasAntecedent: false) != nil else { return }
        let material = IntentHeuristics.materialText(turn.text)
        guard let candidate = prefixCandidate, candidate.id == turn.id, candidate.material == material else {
            prefixCandidate = (turn.id, material, now); return
        }
        guard now - candidate.since >= 0.3 else { return }
        let question = QuestionState(id: .init(turn.id.rawValue), revision: 1, supportingTurnIDs: [turn.id],
            text: turn.text, triggerReason: .speculative, source: .systemAudio)
        guard speculation.begin(question: question, sessionEpoch: sessionEpoch, highConfidence: true) != nil else { return }
        lastSpeculatedTurnID = turn.id; speculativeQuestion = question; speculationConfirmed = false
        speculativeText = ""; speculativeUsage = nil; speculativeCompleted = false
        speculationDiagnostics.requests += 1
        pending = Intent(question: question, manual: false, visual: false, detailed: false, speculative: true,
                         createdAt: ProcessInfo.processInfo.systemUptime)
        summaryTask?.cancel(); startPendingIfPossible()
    }
    private func confirmSpeculation(_ question: QuestionState) -> Bool {
        guard speculativeQuestion != nil, !speculationConfirmed, let identity = fence.active,
              speculation.update(question: question, sessionEpoch: sessionEpoch) else { return false }
        speculationConfirmed = true; speculativeQuestion = question
        speculationDiagnostics.reused += 1
        presentation.begin(identity: identity, question: question)
        if !speculativeText.isEmpty {
            _ = presentation.append(speculativeText, identity: identity)
            markFirstPublication(identity)
        }
        speculativeText = ""
        if speculativeCompleted {
            _ = presentation.finish(identity: identity, lifecycle: .completed, usage: speculativeUsage.flatMap(Self.coreUsage))
            diagnostics.status = "Completed"
            if task == nil {
                runningIdentity = identity
                task = Task { [weak self] in
                    guard let self else { return }
                    if let answer = presentation.latestReplacement ?? presentation.displayed,
                       accepts(identity), answer.identity == identity {
                        await conversation.recordSuggestion(question: question, text: answer.text, sessionEpoch: sessionEpoch)
                    }
                    clearSpeculation(discarded: false)
                    await finishOwnedAttempt(identity)
                }
            }
        } else { diagnostics.status = "Streaming" }
        publish(); return true
    }
    private func clearSpeculation(discarded: Bool = true) {
        if speculativeQuestion != nil, !speculationConfirmed, discarded { speculationDiagnostics.discarded += 1 }
        speculation.cancel(); speculativeQuestion = nil; speculationConfirmed = false
        speculativeText = ""; speculativeUsage = nil; speculativeCompleted = false
    }

    @discardableResult func prepareScreenMode(_ mode: ScreenContextMode) -> UInt64 {
        guard active, screenMode != mode else { return screenIntentRevision }
        screenMode = mode; screenIntentRevision &+= 1
        if pending?.visual == true { pending = nil }
        if activeVisual { cancelVisualForeground() }
        if mode == .off, diagnostics.usesVisual {
            presentation.clear(); diagnostics.usesVisual = false; publish()
        }
        return screenIntentRevision
    }
    @discardableResult func prepareScreenSelection(_ selection: ScreenSelection?) -> UInt64 {
        guard active, screenSelection != selection else { return screenIntentRevision }
        screenSelection = selection; screenIntentRevision &+= 1
        if pending?.visual == true { pending = nil }
        if activeVisual { cancelVisualForeground() }
        return screenIntentRevision
    }
    func setScreenMode(_ mode: ScreenContextMode, preparedRevision: UInt64? = nil) async {
        let revision = preparedRevision ?? prepareScreenMode(mode)
        guard mode == screenMode else { return }
        await commitScreenConfiguration(revision: revision)
    }
    func setScreenSelection(_ selection: ScreenSelection?, preparedRevision: UInt64? = nil) async {
        let revision = preparedRevision ?? prepareScreenSelection(selection)
        guard selection == screenSelection else { return }
        await commitScreenConfiguration(revision: revision)
    }
    private func commitScreenConfiguration(revision: UInt64) async {
        guard active, revision == screenIntentRevision, !Task.isCancelled else { return }
        await screen.configure(mode: screenMode, selection: screenSelection)
    }
    private func cancelVisualForeground() {
        let textIntent = pending?.visual == false ? pending : nil
        invalidateForeground(clearPending: true)
        pending = textIntent
        diagnostics.status = "Visual request cancelled"; publish()
        startPendingIfPossible()
    }
    func questionInvalidated(_ id: QuestionID) {
        if fence.active?.questionID == id { cancelForeground() }
        if pending?.question.id == id { pending = nil }
    }
    func contextInvalidated(_ id: UUID) {
        guard activeContextID == id else { return }
        if let identity = runningIdentity { trace(.contextInvalidated, identity, level: .warning, fields: [.contextID: .id(id)]) }
        invalidateForeground(clearPending: false)
        contextHistoryNeedsPurge = true
        diagnostics.status = "Selected conversation was corrected · request an updated answer"
        publish()
    }
    func request(question: QuestionState, manual: Bool, captureVisual: Bool = false, detailed: Bool = false) {
        guard active, manual || options.automaticAnswers else { return }
        if !manual, pending?.manual == true { return }
        if !manual, confirmSpeculation(question) { return }
        let intent = Intent(question: question, manual: manual,
            visual: captureVisual || (screenMode == .automatic && Self.needsScreen(question.text)),
            detailed: detailed || contextConfiguration.answerStyle == .code, speculative: false,
            createdAt: ProcessInfo.processInfo.systemUptime)
        if activeManual, !manual, task != nil {
            pending = intent // One newest automatic question waits behind the explicit manual request.
            return
        }
        pending = intent
        invalidateForeground(clearPending: false)
        summaryTask?.cancel()
        startPendingIfPossible()
    }
    private func startPendingIfPossible() {
        guard active, task == nil, let intent = pending else { return }
        pending = nil
        guard intent.manual || ProcessInfo.processInfo.systemUptime - intent.createdAt <= 5 else { return }
        let identity = fence.begin(sessionEpoch: sessionEpoch, question: intent.question)
        runningIdentity = identity
        activeManual = intent.manual; activeVisual = intent.visual
        outputIdentity = identity; outputPending = ""; activeQuestionEnd = nil
        if !intent.speculative { presentation.begin(identity: identity, question: intent.question) }
        diagnostics = GenerationDiagnostics(requestID: identity.generationID.rawValue, status: intent.speculative ? "Experimental speculation" : "Preparing context")
        trace(.generationStarted, identity, fields: [.questionID: .id(intent.question.id.rawValue), .revision: .int(intent.question.revision), .manual: .flag(intent.manual), .visual: .flag(intent.visual), .speculative: .flag(intent.speculative)])
        publish()
        let previousSummary = summaryTask
        previousSummary?.cancel()
        task = Task { [weak self] in
            await previousSummary?.value
            guard let self else { return }
            if self.accepts(identity), !Task.isCancelled {
                await self.run(question: intent.question, identity: identity, visual: intent.visual,
                    manual: intent.manual, detailed: intent.detailed, speculative: intent.speculative)
            }
            await self.finishOwnedAttempt(identity)
        }
    }
    private func finishOwnedAttempt(_ identity: GenerationIdentity) async {
        // No replacement stream starts before the old native producer and retry timers terminate.
        await provider.cancelAll()
        guard runningIdentity == identity else { return }
        task = nil; runningIdentity = nil; activeManual = false; activeVisual = false
        if accepts(identity) { publish() }
        startPendingIfPossible()
    }
    private func run(question: QuestionState, identity: GenerationIdentity, visual: Bool, manual: Bool, detailed: Bool, speculative: Bool) async {
        var flushTask: Task<Void, Never>?
        var usage: LLMUsage?
        do {
            try Task.checkCancellation()
            guard accepts(identity) else { throw CancellationError() }
            var config = contextConfiguration
            config.outputReserve = detailed ? options.detailedOutputTokens : options.normalOutputTokens
            let selection = try await Self.selectProfile(profile, question: question.text)
            try Task.checkCancellation()
            guard accepts(identity) else { throw CancellationError() }
            config.selectedProfile = selection?.text ?? ""
            if contextHistoryNeedsPurge {
                await conversation.discardSuggestions(sessionEpoch: sessionEpoch)
                guard accepts(identity), !Task.isCancelled else { throw CancellationError() }
                contextHistoryNeedsPurge = false
            }
            let selectedContext = try await conversation.contextForGeneration(for: question, configuration: config)
            try Task.checkCancellation()
            guard accepts(identity) else { throw CancellationError() }
            let snapshot = selectedContext.snapshot
            activeContextID = selectedContext.contextID
            guard await conversation.generationContextIsCurrent(selectedContext.contextID) else {
                contextInvalidated(selectedContext.contextID); throw CancellationError()
            }
            trace(.contextPrepared, identity, fields: [.contextID: .id(selectedContext.contextID), .revision: .int(snapshot.revision), .inputTokens: .int(snapshot.estimatedTokens)])
            let observed = await conversation.currentUpdate()
            guard accepts(identity), !Task.isCancelled else { throw CancellationError() }
            activeQuestionEnd = !manual && question.source == .systemAudio
                ? observed.turns.filter { question.supportingTurnIDs.contains($0.id) }.map(\.endTime).max() : nil
            diagnostics.inputEstimate = snapshot.estimatedTokens
            diagnostics.contextLimited = !snapshot.limitations.isEmpty || selection?.isLimited == true
            var captured: CapturedVisual?
            if visual {
                let revision = screenIntentRevision
                await commitScreenConfiguration(revision: revision)
                try Task.checkCancellation()
                guard accepts(identity), revision == screenIntentRevision else { throw CancellationError() }
                diagnostics.status = "Capturing selected screen"; publish()
                captured = try await screen.capture(manual: manual)
                try Task.checkCancellation()
                guard accepts(identity), let captured, await screen.isCurrent(captured) else { throw ScreenCaptureFailure.stale }
            }
            let image = captured.map { LLMImage(bytes: $0.png, format: .png) }
            diagnostics.usesVisual = image != nil
            guard await conversation.generationContextIsCurrent(selectedContext.contextID) else {
                contextInvalidated(selectedContext.contextID); throw CancellationError()
            }
            guard accepts(identity), !Task.isCancelled else { throw CancellationError() }
            diagnostics.status = "Waiting for Grok"
            diagnostics.submittedAt = ProcessInfo.processInfo.systemUptime
            publish()
            let request = LLMRequest(trustedInstructions: snapshot.trustedInstructions,
                selectedContext: snapshot.userContext, estimatedInputTokens: snapshot.estimatedTokens,
                sessionCacheKey: sessionID.rawValue.uuidString, image: image, detailed: detailed, diagnosticSessionID: sessionID.rawValue, diagnosticRequestID: identity.generationID.rawValue)
            let events = try await provider.stream(request)
            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
                    guard let self, self.accepts(identity) else { break }
                    self.flush(identity)
                }
            }
            var terminal = false
            for try await event in events {
                try Task.checkCancellation()
                guard accepts(identity) else { throw CancellationError() }
                if let captured, !(await screen.isCurrent(captured)) { throw CancellationError() }
                guard accepts(identity), !Task.isCancelled else { throw CancellationError() }
                switch event {
                case .textDelta(let text):
                    if speculative, !speculationConfirmed {
                        guard speculativeText.utf8.count + text.utf8.count <= 128 * 1_024 else { throw XAIError.outputBufferOverflow }
                        speculativeText += text
                        continue
                    }
                    guard outputPending.utf8.count + text.utf8.count <= 128 * 1_024 else { throw XAIError.outputBufferOverflow }
                    outputPending += text
                    if ProcessInfo.processInfo.systemUptime - lastUIUpdate >= 0.04 { flush(identity) }
                case .usage(let value):
                    usage = value; diagnostics.usage = value
                    if speculative { speculativeUsage = value }
                case .completed:
                    var completionFields: [DiagnosticField: DiagnosticValue] = [:]
                    if let input = usage?.inputTokens { completionFields[.inputTokens] = .int(input) }
                    if let output = usage?.outputTokens { completionFields[.outputTokens] = .int(output) }
                    trace(.generationCompleted, identity, fields: completionFields, duration: diagnostics.submittedAt.map { ProcessInfo.processInfo.systemUptime - $0 })
                    if speculative, !speculationConfirmed {
                        speculativeCompleted = true; terminal = true
                        diagnostics.status = "Speculative answer buffered"; continue
                    }
                    flush(identity)
                    _ = presentation.finish(identity: identity, lifecycle: .completed, usage: usage.flatMap(Self.coreUsage))
                    diagnostics.status = "Completed"; terminal = true
                case .incomplete(let reason):
                    trace(.generationIncomplete, identity, level: .warning)
                    if speculative, !speculationConfirmed { throw XAIError.earlyEOF }
                    flush(identity)
                    _ = presentation.finish(identity: identity, lifecycle: .interrupted, usage: usage.flatMap(Self.coreUsage))
                    diagnostics.status = reason == .outputLimit ? "Output limit reached · partial answer" : "Interrupted · partial answer"
                    terminal = true
                case .retryScheduled(let attempt, let delay):
                    diagnostics.status = "Retry \(attempt) in \(Int(ceil(delay)))s"; publish()
                case .providerPrivacy: break // Do not turn a provider header into a blanket retention promise.
                }
            }
            try Task.checkCancellation()
            guard accepts(identity) else { throw CancellationError() }
            guard terminal else { throw XAIError.earlyEOF }
            if speculative, let usage, let input = usage.inputTokens, let output = usage.outputTokens {
                speculationDiagnostics.reportedInputTokens += input
                speculationDiagnostics.reportedOutputTokens += output
                speculationDiagnostics.usageSamples += 1
            }
            if !visual, let answer = presentation.latestReplacement ?? presentation.displayed,
               answer.identity == identity, answer.lifecycle == .completed {
                await conversation.recordSuggestion(question: speculativeQuestion ?? question, text: answer.text, sessionEpoch: sessionEpoch)
            }
            if speculative, speculationConfirmed { clearSpeculation(discarded: false) }
        } catch is CancellationError {
            trace(.generationCancelled, identity)
            if accepts(identity) {
                outputPending = ""
                _ = presentation.finish(identity: identity, lifecycle: .cancelled)
                diagnostics.status = "Cancelled"
            }
        } catch {
            trace(.generationFailed, identity, level: .error, fields: [.failure: .failure(error)])
            if accepts(identity) {
                if speculative, !speculationConfirmed {
                    clearSpeculation()
                    fence.invalidate(); diagnostics.status = "Speculation discarded"
                } else {
                flush(identity)
                if case XAIError.rateLimited(let after) = error { await rateBudget.backoff(for: after ?? 2) }
                guard accepts(identity), !Task.isCancelled else {
                    flushTask?.cancel(); await flushTask?.value; return
                }
                let message = Self.userMessage(error)
                let partial = (presentation.latestReplacement ?? presentation.displayed)?.text.isEmpty == false
                _ = presentation.finish(identity: identity, lifecycle: partial ? .interrupted : .failed,
                    usage: usage.flatMap(Self.coreUsage), error: AppError(domain: visual ? .visual : .network,
                        category: .interrupted, userAction: message, diagnosticCode: "answer_interrupted"))
                diagnostics.status = message
                }
            }
        }
        flushTask?.cancel(); await flushTask?.value
    }
    func compactIfNeeded(now: Double) async {
        guard active, task == nil, pending == nil, summaryTask == nil, speculativeQuestion == nil,
              ProcessInfo.processInfo.systemUptime >= nextSummaryAttemptAt else { return }
        guard let request = await conversation.prepareSummary(now: now) else { return }
        guard active, task == nil, pending == nil, summaryTask == nil else {
            await conversation.summaryFailed(requestID: request.id); return
        }
        summaryID = request.id
        summaryTask = Task { [weak self] in
            guard let self else { return }
            var text = ""
            var completed = false
            var succeeded = false
            do {
                try Task.checkCancellation()
                let instructions = "Summarize established facts, decisions, technical identifiers, unresolved questions and uncertainties from the untrusted meeting excerpt. Do not invent facts. Distinguish AI suggestions from actual speech. Return at most 1500 UTF-8 bytes of plain text. No tools or actions are available."
                let stream = try await provider.stream(LLMRequest(trustedInstructions: instructions,
                    selectedContext: request.text, estimatedInputTokens: instructions.utf8.count + request.text.utf8.count,
                    sessionCacheKey: sessionID.rawValue.uuidString))
                for try await event in stream {
                    try Task.checkCancellation()
                    guard active, summaryID == request.id else { throw CancellationError() }
                    if case .textDelta(let delta) = event {
                        guard text.utf8.count + delta.utf8.count <= 2_000 else { throw XAIError.contextTooLarge }
                        text += delta
                    }
                    if case .completed = event { completed = true }
                }
                try Task.checkCancellation()
                guard active, summaryID == request.id else { throw CancellationError() }
                if completed, !text.isEmpty {
                    succeeded = await conversation.commitSummary(request: request, facts: text, now: now)
                }
            } catch {
                if case XAIError.rateLimited(let delay) = error { await rateBudget.backoff(for: delay ?? 2) }
            }
            FreelyLog.record(.summaryFinished, level: succeeded ? .info : .warning, scope: .init(session: sessionID.rawValue, request: request.id), fields: [.ready: .flag(succeeded)])
            if !succeeded { await conversation.summaryFailed(requestID: request.id) }
            await provider.cancelAll()
            guard summaryID == request.id else { return }
            summaryID = nil; summaryTask = nil
            if succeeded { summaryFailures = 0; nextSummaryAttemptAt = ProcessInfo.processInfo.systemUptime + 300 }
            else {
                summaryFailures = min(4, summaryFailures + 1)
                // Background failures never become an every-second offline retry loop.
                nextSummaryAttemptAt = ProcessInfo.processInfo.systemUptime + min(300, 15 * pow(2, Double(summaryFailures)))
            }
        }
    }
    func pin() { presentation.pin(); publish() }
    func unpin() {
        presentation.unpin()
        if let displayed = presentation.displayed, !displayed.text.isEmpty { markFirstPublication(displayed.identity) }
        publish()
    }
    func clear() { cancelForeground(); presentation.clear(); diagnostics = .init(); publish() }
    func cancelForeground() {
        invalidateForeground(clearPending: true)
        diagnostics.status = "Cancelled"
        publish()
    }
    private func invalidateForeground(clearPending: Bool) {
        fence.invalidate(); outputIdentity = nil; outputPending = ""; activeContextID = nil
        if clearPending { pending = nil }
        task?.cancel(); presentation.invalidate()
        clearSpeculation()
        // Keep ownership until cleanup finishes. A new request only replaces the single pending intent.
    }
    func invalidateSession() {
        active = false
        invalidateForeground(clearPending: true)
        summaryTask?.cancel()
    }
    func stop() async {
        invalidateSession()
        let owned = task, summary = summaryTask
        await screen.clear()
        await provider.cancelAll()
        await owned?.value; await summary?.value
        task = nil; runningIdentity = nil; summaryTask = nil; summaryID = nil
        activeManual = false; activeVisual = false; presentation.clear()
        diagnostics = .init(status: "Session ended")
        publish()
    }
    private func accepts(_ identity: GenerationIdentity) -> Bool {
        active && identity.sessionEpoch == sessionEpoch && fence.accepts(identity)
    }
    private func flush(_ identity: GenerationIdentity) {
        guard accepts(identity), outputIdentity == identity, !outputPending.isEmpty else { return }
        let chunk = outputPending; outputPending = ""
        if !presentation.append(chunk, identity: identity) { task?.cancel() }
        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { markFirstPublication(identity) }
        diagnostics.status = "Streaming"
        lastUIUpdate = ProcessInfo.processInfo.systemUptime
        publish()
    }
    private func markFirstPublication(_ identity: GenerationIdentity) {
        guard accepts(identity), !presentation.isPinned, diagnostics.firstTextSeconds == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        diagnostics.firstTextSeconds = diagnostics.submittedAt.map { max(0, now - $0) }
        trace(.generationFirstText, identity, duration: diagnostics.firstTextSeconds)
        diagnostics.endToVisibleSeconds = activeQuestionEnd.map { max(0, now - sessionOrigin - $0) }
    }
    private func publish() { onChange(presentation, diagnostics) }
    static func needsScreen(_ question: String) -> Bool {
        let lower = question.lowercased()
        return ["screen", "diagram", "this code", "shown", "chart", "screenshot", "slide", "highlighted"].contains { lower.contains($0) }
    }
    private static func coreUsage(_ usage: LLMUsage) -> TokenUsage? {
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: usage.cachedInputTokens)
    }
    private nonisolated static func selectProfile(_ profile: UserProfile?, question: String) async throws -> ProfileContextSelection? {
        // Large imported profile text is selected on a structured child task, never formatted on MainActor.
        try await withThrowingTaskGroup(of: ProfileContextSelection?.self) { group in
            group.addTask {
                try Task.checkCancellation()
                let selection = profile?.selectedContext(for: question, maximumBytes: 2_000)
                try Task.checkCancellation()
                return selection
            }
            return try await group.next() ?? nil
        }
    }
    private static func userMessage(_ error: Error) -> String {
        if let error = error as? AppError { return error.userAction }
        if let error = error as? LocalizedError, let message = error.errorDescription { return message }
        return "The answer was interrupted. Retry when ready; local transcription can continue."
    }
}
