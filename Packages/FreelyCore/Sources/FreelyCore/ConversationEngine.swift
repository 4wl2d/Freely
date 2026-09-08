import Foundation

public struct ConversationUpdate: Sendable {
    public let segments: [TranscriptSegment]
    public let turns: [ConversationTurn]
    public let newQuestion: QuestionState?
    public let invalidatedQuestionIDs: [QuestionID]
    /// Only the one prepared answer context whose selected finalized source was corrected.
    public let invalidatedContextID: UUID?
    public let revision: UInt64
    public let contextLimited: Bool
    public let gaps: [AudioDiscontinuity]
    public let result: ReconciliationResult
}

public actor ConversationEngine {
    private var sessionID: SessionID?
    private var epoch = SessionEpoch()
    private let limits: TranscriptLimits
    private var store: TranscriptStore
    private var detector = QuestionDetector()
    private var turns: [ConversationTurn] = []
    private var cachedSegments: [TranscriptSegment] = []
    private var reconciledRevision: UInt64?
    private var nextStabilityTime: TimeInterval?
    private var summary: RollingSummary?
    private var pendingSummary: SummaryRequest?
    private var suggestions: [PriorSuggestion] = []
    private var lastSummaryTime: TimeInterval = 0
    private struct GenerationContextWatch {
        let id: UUID
        let references: [SegmentID: SegmentReference]
        let materialText: [SegmentID: String]
        var valid = true
    }
    private var generationContext: GenerationContextWatch?
    public init(limits: TranscriptLimits = .init()) {
        self.limits = limits; self.store = .init(limits: limits)
    }
    public func begin(sessionID: SessionID, epoch: SessionEpoch, triggerLocalSpeech: Bool = false) {
        guard epoch > self.epoch || (self.sessionID == nil && self.epoch.rawValue == 0 && epoch.rawValue == 0) else { return }
        self.sessionID = sessionID; self.epoch = epoch
        store = .init(limits: limits); detector = .init(); detector.triggerLocalSpeech = triggerLocalSpeech
        turns = []; cachedSegments = []; reconciledRevision = nil; nextStabilityTime = nil
        summary = nil; pendingSummary = nil; suggestions = []; lastSummaryTime = 0; generationContext = nil
    }
    public func stop(epoch invalidatedEpoch: SessionEpoch) {
        guard invalidatedEpoch > epoch || (sessionID == nil && invalidatedEpoch == epoch) else { return }
        sessionID = nil; epoch = invalidatedEpoch; store = .init(limits: limits)
        detector = .init(); turns = []; cachedSegments = []; reconciledRevision = nil; nextStabilityTime = nil
        summary = nil; pendingSummary = nil; suggestions = []; generationContext = nil
    }
    public func setSourceEpoch(_ sourceEpoch: SourceEpoch, source: AudioSource, sessionEpoch: SessionEpoch) {
        guard sessionID != nil, sessionEpoch == epoch else { return }
        store.setSourceEpoch(sourceEpoch, source: source)
        pendingSummary = nil
    }
    public func apply(_ event: TranscriptEvent, sessionEpoch: SessionEpoch, now: TimeInterval) -> ConversationUpdate {
        guard sessionID != nil, sessionEpoch == epoch else { return update(result: .wrongEpoch) }
        let result = store.apply(event)
        if result == .accepted || result == .retiredSegment {
            invalidateGenerationContextIfNeeded(event)
            invalidateSummaryIfNeeded(event)
        }
        guard result == .accepted else { return update(result: result) }
        var explicitlyInvalidated: [QuestionID] = []
        if case .retract(let id, _, _, _, _) = event {
            let affected = Set(turns.filter { $0.segmentIDs.contains(id) }.map(\.id))
            explicitlyInvalidated = detector.retract(turnIDs: affected)
        }
        let evicted = store.enforceLimits()
        if !evicted.isEmpty { compactExtractively(evicted) }
        return reconcile(now: now, result: result, invalidated: explicitlyInvalidated)
    }
    public func tick(now: TimeInterval, sessionEpoch: SessionEpoch? = nil) -> ConversationUpdate {
        guard self.sessionID != nil, sessionEpoch == nil || sessionEpoch == epoch else { return update(result: .wrongEpoch) }
        return reconcile(now: now, result: .accepted)
    }
    public func currentUpdate() -> ConversationUpdate { update(result: .accepted) }
    public func recentQuestions() -> [QuestionState] { detector.questions }
    public func rollingSummary() -> RollingSummary? { summary }
    public func context(for question: QuestionState, configuration: ContextConfiguration = .init()) throws -> ContextSnapshot {
        guard let sessionID else {
            throw AppError(domain: .session, category: .unavailable, userAction: "Start a session before requesting an answer.", diagnosticCode: "session_inactive")
        }
        return try ContextBuilder.build(sessionID: sessionID, sessionEpoch: epoch, revision: store.revision,
            question: question, turns: turns, summary: summary, suggestions: suggestions, gaps: store.gaps,
            contextLimited: store.contextLimited, configuration: configuration)
    }
    /// Build selected text and its finalized source dependencies in the same actor operation.
    /// A single foreground owner replaces this bounded watch; ordinary context callers are unchanged.
    public func contextForGeneration(for question: QuestionState, configuration: ContextConfiguration = .init()) throws ->
        (snapshot: ContextSnapshot, contextID: UUID) {
        let snapshot = try context(for: question, configuration: configuration)
        let selectedIDs = Set(snapshot.provenance.flatMap(\.segmentIDs))
        var references: [SegmentID: SegmentReference] = [:]
        var materialText: [SegmentID: String] = [:]
        for id in selectedIDs {
            if let segment = store.segment(id), segment.finality == .final {
                references[id] = SegmentReference(segment)
                materialText[id] = IntentHeuristics.materialText(segment.text)
            }
        }
        // Summary inputs can already be evicted from the transcript while remaining selected context.
        for reference in summary?.references ?? [] where selectedIDs.contains(reference.id) {
            if references[reference.id] == nil { references[reference.id] = reference }
        }
        let id = UUID()
        generationContext = GenerationContextWatch(id: id, references: references, materialText: materialText)
        return (snapshot, id)
    }
    public func generationContextIsCurrent(_ id: UUID) -> Bool {
        sessionID != nil && generationContext?.id == id && generationContext?.valid == true
    }
    public func recordSuggestion(question: QuestionState, text: String, sessionEpoch: SessionEpoch) {
        guard sessionID != nil, sessionEpoch == epoch else { return }
        suggestions.removeAll { $0.question.id == question.id }
        suggestions.append(.init(question: question, text: TokenEstimator.prefix(text, budget: 16_384)))
        while suggestions.count > 20 || suggestions.reduce(0, { $0 + $1.text.utf8.count + $1.question.text.utf8.count }) > 128 * 1_024 {
            suggestions.removeFirst()
        }
    }
    /// Generated suggestions may contain selected profile or user-note details. Changing that
    /// selection purges derived suggestions without erasing actual conversation provenance.
    public func discardSuggestions(sessionEpoch: SessionEpoch) {
        guard sessionID != nil, sessionEpoch == epoch else { return }
        suggestions = []
    }
    /// One pending semantic summary; callers must give foreground answers priority and use the shared request limiter.
    public func prepareSummary(now: TimeInterval) -> SummaryRequest? {
        guard sessionID != nil, pendingSummary == nil else { return nil }
        let segments = store.segments
        guard segments.count >= 4,
              segments.count >= Int(Double(limits.maximumSegments) * 0.75) || now - lastSummaryTime >= 300 else { return nil }
        let older = segments.filter { $0.finality == .final && $0.endTime < now - 30 && !overlapsGap($0) }.prefix(256)
        guard !older.isEmpty else { return nil }
        var included: [TranscriptSegment] = []
        var bytes = 0
        for value in older {
            guard bytes + value.text.utf8.count + 32 <= 8_000 else { break }
            included.append(value); bytes += value.text.utf8.count + 32
        }
        guard !included.isEmpty else { return nil }
        let request = SummaryRequest(id: UUID(), sessionEpoch: epoch, references: included.map(SegmentReference.init),
                                     text: included.map { "[\($0.source.label)] \($0.text)" }.joined(separator: "\n"))
        pendingSummary = request; return request
    }
    @discardableResult public func commitSummary(request: SummaryRequest, facts: String,
        uncertainties: [String] = [], unresolvedTopics: [String] = [], now: TimeInterval) -> Bool {
        guard sessionID != nil, request.sessionEpoch == epoch, pendingSummary?.id == request.id else { return false }
        pendingSummary = nil
        guard store.matches(request.references) else { return false }
        let all = facts + uncertainties.joined() + unresolvedTopics.joined()
        guard all.utf8.count <= 2_000 else { return false }
        summary = .init(references: request.references, facts: facts, uncertainties: uncertainties,
                        unresolvedTopics: unresolvedTopics)
        lastSummaryTime = now; return true
    }
    public func summaryFailed(requestID: UUID) {
        guard pendingSummary?.id == requestID else { return }
        if let request = pendingSummary {
            compactExtractively(request.references.compactMap { store.segment($0.id) })
        }
        pendingSummary = nil
    }
    private func reconcile(now: TimeInterval, result: ReconciliationResult, invalidated: [QuestionID] = []) -> ConversationUpdate {
        if reconciledRevision == store.revision, invalidated.isEmpty,
           nextStabilityTime == nil || now < nextStabilityTime! { return update(result: result) }
        cachedSegments = store.segments
        let rebuilt = TurnBuilder.build(segments: cachedSegments, now: now, gaps: store.gaps, previous: turns)
        let rebuiltIDs = Set(rebuilt.map(\.id)), retainedIDs = Set(cachedSegments.map(\.id))
        let structurallyRemoved = Set(turns.filter { !rebuiltIDs.contains($0.id) && !$0.segmentIDs.allSatisfy({ !retainedIDs.contains($0) }) }.map(\.id))
        let structuralInvalidations = detector.retract(turnIDs: structurallyRemoved)
        turns = rebuilt
        reconciledRevision = store.revision
        nextStabilityTime = turns.filter { $0.isFinal && !$0.isStable }.map { $0.endTime + 0.3 }.min()
        let detection = detector.evaluate(turns)
        return update(result: result, question: detection.question, invalidated: invalidated + structuralInvalidations + detection.invalidated)
    }
    private func update(result: ReconciliationResult, question: QuestionState? = nil, invalidated: [QuestionID] = []) -> ConversationUpdate {
        .init(segments: cachedSegments, turns: turns, newQuestion: question, invalidatedQuestionIDs: invalidated,
              invalidatedContextID: generationContext?.valid == false ? generationContext?.id : nil,
              revision: store.revision, contextLimited: store.contextLimited, gaps: store.gaps, result: result)
    }
    private func invalidateGenerationContextIfNeeded(_ event: TranscriptEvent) {
        guard let watch = generationContext, watch.valid else { return }
        let affected: Bool
        switch event {
        case .upsert(let segment), .insert(let segment), .update(let segment), .finalize(let segment), .revise(let segment):
            if let previous = watch.references[segment.id] {
                affected = segment.finality == .final && segment.source == previous.source && segment.streamEpoch == previous.streamEpoch &&
                    segment.sequence == previous.sequence && segment.revision > previous.revision &&
                    watch.materialText[segment.id].map({ $0 != IntentHeuristics.materialText(segment.text) }) != false
            } else { affected = false }
        case .retract(let id, let source, let epoch, let revision, let sequence):
            if let previous = watch.references[id] {
                affected = source == previous.source && epoch == previous.streamEpoch && revision > previous.revision &&
                    (sequence == nil || sequence == previous.sequence)
            } else { affected = false }
        case .gap(let gap):
            affected = watch.references.values.contains {
                $0.source == gap.source && $0.streamEpoch == gap.streamEpoch && $0.startTime < gap.endTime && $0.endTime > gap.startTime
            }
        }
        if affected { generationContext?.valid = false }
    }
    private func invalidateSummaryIfNeeded(_ event: TranscriptEvent) {
        let id: SegmentID
        let revision: UInt64
        switch event {
        case .upsert(let segment), .insert(let segment), .update(let segment), .finalize(let segment), .revise(let segment):
            id = segment.id; revision = segment.revision
        case .retract(let value, _, _, let rev, _): id = value; revision = rev
        case .gap(let gap):
            func overlaps(_ reference: SegmentReference) -> Bool {
                reference.source == gap.source && reference.streamEpoch == gap.streamEpoch &&
                    reference.startTime < gap.endTime && reference.endTime > gap.startTime
            }
            if pendingSummary?.references.contains(where: overlaps) == true { pendingSummary = nil }
            if summary?.references.contains(where: overlaps) == true {
                summary = .init(references: [], facts: "", uncertainties: ["An earlier summary overlapped a newly reported audio gap; older context is incomplete."], isExtractiveFallback: true)
            }
            return
        }
        if let summary, summary.references.contains(where: { $0.id == id && revision > $0.revision }) {
            // Invalidation is conservative: even a correction to evicted source data must remove obsolete facts.
            self.summary = .init(references: [], facts: "", uncertainties: ["An earlier summary was invalidated by a transcript correction; older context is incomplete."], isExtractiveFallback: true)
        }
    }
    private func compactExtractively(_ segments: [TranscriptSegment]) {
        let stable = segments.filter { $0.finality == .final && !overlapsGap($0) }
        guard !stable.isEmpty else { return }
        var selected: [TranscriptSegment] = []
        var bytes = 0
        for value in stable.reversed() {
            let cost = value.text.utf8.count + value.source.label.utf8.count + 4
            if bytes + cost <= 1_700 { selected.append(value); bytes += cost }
        }
        let ordered = selected.reversed()
        summary = .init(references: ordered.map(SegmentReference.init),
            facts: ordered.map { "[\($0.source.label)] \($0.text)" }.joined(separator: "\n"),
            uncertainties: ["Extractive fallback retains selected recent older statements; earlier context may be missing."],
            isExtractiveFallback: true)
    }
    private func overlapsGap(_ segment: TranscriptSegment) -> Bool {
        store.gaps.contains { gap in
            gap.source == segment.source && gap.streamEpoch == segment.streamEpoch &&
                gap.startTime < segment.endTime && gap.endTime > segment.startTime
        }
    }
}
