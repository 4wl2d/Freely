import Foundation

public enum SessionPhase: String, CaseIterable, Sendable { case idle, preparing, running, paused, recovering, stopping }
public enum SourceStatus: Equatable, Sendable { case stopped, preparing, running, paused, failed(AppError) }
/// Synchronous transitions let the native coordinator invalidate identity before its first teardown await.
public struct SessionLifecycle: Sendable {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var sessionID: SessionID?
    public private(set) var epoch = SessionEpoch()
    public private(set) var sources: [AudioSource: SourceStatus] = [:]
    public init() {}
    @discardableResult public mutating func start() -> SessionEpoch? {
        guard phase == .idle else { return nil }
        epoch = epoch.advanced(); sessionID = .init(); phase = .preparing
        sources = [.localUser: .preparing, .systemAudio: .preparing]; return epoch
    }
    @discardableResult public mutating func ready(epoch: SessionEpoch) -> Bool {
        guard self.epoch == epoch, phase == .preparing || phase == .recovering else { return false }
        phase = .running; return true
    }
    @discardableResult public mutating func pause() -> Bool {
        guard phase == .running || phase == .recovering else { return false }
        phase = .paused
        for source in AudioSource.allCases where sources[source] == .running { sources[source] = .paused }
        return true
    }
    @discardableResult public mutating func resume() -> Bool {
        guard phase == .paused else { return false }
        phase = .running
        // The native coordinator must confirm each restarted source. Resuming the
        // session alone must not claim that a paused or disabled input is capturing.
        return true
    }
    @discardableResult public mutating func recovering(epoch: SessionEpoch) -> Bool {
        guard self.epoch == epoch, phase == .running else { return false }
        phase = .recovering; return true
    }
    public mutating func setSource(_ source: AudioSource, status: SourceStatus, epoch: SessionEpoch) {
        guard self.epoch == epoch, phase != .idle, phase != .stopping else { return }
        sources[source] = status
    }
    /// Returns the new invalidating epoch once. Repeated stop is a no-op.
    @discardableResult public mutating func stop() -> SessionEpoch? {
        guard phase != .idle, phase != .stopping else { return nil }
        epoch = epoch.advanced(); phase = .stopping; sessionID = nil
        return epoch
    }
    public mutating func didStop(epoch: SessionEpoch) {
        guard self.epoch == epoch, phase == .stopping else { return }
        sources = [:]; phase = .idle
    }
    public func accepts(_ epoch: SessionEpoch) -> Bool {
        self.epoch == epoch && (phase == .running || phase == .preparing || phase == .recovering)
    }
}

public struct GenerationIdentity: Hashable, Sendable {
    public let sessionEpoch: SessionEpoch
    public let generationID: GenerationID
    public let questionID: QuestionID
    public let questionRevision: UInt64
    public init(sessionEpoch: SessionEpoch, generationID: GenerationID = .init(), questionID: QuestionID,
                questionRevision: UInt64) {
        self.sessionEpoch = sessionEpoch; self.generationID = generationID
        self.questionID = questionID; self.questionRevision = questionRevision
    }
}
public struct GenerationFence: Sendable {
    public private(set) var active: GenerationIdentity?
    public init() {}
    @discardableResult public mutating func begin(sessionEpoch: SessionEpoch, question: QuestionState) -> GenerationIdentity {
        let identity = GenerationIdentity(sessionEpoch: sessionEpoch, questionID: question.id, questionRevision: question.revision)
        active = identity; return identity
    }
    public mutating func invalidate() { active = nil }
    public mutating func invalidate(questionID: QuestionID) {
        if active?.questionID == questionID { active = nil }
    }
    public func accepts(_ identity: GenerationIdentity) -> Bool { active == identity }
}
public struct TokenUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int?
    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedInputTokens = cachedInputTokens
    }
}
public enum AnswerLifecycle: String, Sendable { case waiting, streaming, completed, interrupted, failed, cancelled }
public struct AnswerState: Identifiable, Equatable, Sendable {
    public var id: GenerationID { identity.generationID }
    public let identity: GenerationIdentity
    public let question: QuestionState
    public var text: String
    public var lifecycle: AnswerLifecycle
    public var usage: TokenUsage?
    public var error: AppError?
    public init(identity: GenerationIdentity, question: QuestionState, text: String = "", lifecycle: AnswerLifecycle = .waiting,
                usage: TokenUsage? = nil, error: AppError? = nil) {
        self.identity = identity; self.question = question; self.text = text; self.lifecycle = lifecycle
        self.usage = usage; self.error = error
    }
}
/// UI owners invoke mutations on MainActor. This value performs the final identity check too.
public struct AnswerPresentation: Sendable {
    public private(set) var displayed: AnswerState?
    public private(set) var latestReplacement: AnswerState?
    public private(set) var isPinned = false
    public private(set) var activeIdentity: GenerationIdentity?
    public let maximumAnswerBytes: Int
    public var newAnswerAvailable: Bool { latestReplacement != nil && latestReplacement != displayed }
    public init(maximumAnswerBytes: Int = 128 * 1_024) { self.maximumAnswerBytes = max(128, maximumAnswerBytes) }
    public mutating func begin(identity: GenerationIdentity, question: QuestionState) {
        activeIdentity = identity
        let value = AnswerState(identity: identity, question: question)
        if isPinned, displayed != nil { latestReplacement = value } else { displayed = value; latestReplacement = nil }
    }
    @discardableResult public mutating func append(_ delta: String, identity: GenerationIdentity) -> Bool {
        guard activeIdentity == identity else { return false }
        let limit = maximumAnswerBytes
        return mutate(identity) { state in
            guard state.lifecycle == .waiting || state.lifecycle == .streaming else { return false }
            guard state.text.utf8.count + delta.utf8.count <= limit else {
                state.lifecycle = .interrupted
                state.error = .init(domain: .generation, category: .capacity,
                    userAction: "The answer reached the local display limit. Ask a narrower question.", diagnosticCode: "answer_byte_limit")
                return false
            }
            state.text += delta
            if !delta.isEmpty { state.lifecycle = .streaming }
            return true
        }
    }
    @discardableResult public mutating func finish(identity: GenerationIdentity, lifecycle: AnswerLifecycle,
                                                  usage: TokenUsage? = nil, error: AppError? = nil) -> Bool {
        guard activeIdentity == identity else { return false }
        return mutate(identity) { state in
            guard state.lifecycle == .waiting || state.lifecycle == .streaming else { return false }
            state.lifecycle = lifecycle; state.usage = usage; state.error = error; return true
        }
    }
    public mutating func pin() {
        guard let displayed else { return }
        isPinned = true
        if displayed.identity == activeIdentity, displayed.lifecycle == .waiting || displayed.lifecycle == .streaming {
            latestReplacement = displayed
        }
    }
    public mutating func unpin() {
        isPinned = false
        if let latestReplacement { displayed = latestReplacement; self.latestReplacement = nil }
    }
    public mutating func clear() { displayed = nil; latestReplacement = nil; isPinned = false; activeIdentity = nil }
    public mutating func invalidate() {
        activeIdentity = nil
        if displayed?.lifecycle == .waiting || displayed?.lifecycle == .streaming { displayed?.lifecycle = .cancelled }
        if latestReplacement?.lifecycle == .waiting || latestReplacement?.lifecycle == .streaming { latestReplacement?.lifecycle = .cancelled }
    }
    private mutating func mutate(_ identity: GenerationIdentity, body: (inout AnswerState) -> Bool) -> Bool {
        if latestReplacement?.identity == identity { return body(&latestReplacement!) }
        if displayed?.identity == identity { return body(&displayed!) }
        return false
    }
}

public struct RequestLimiter: Sendable {
    public let startsPerMinute: Int
    private var starts: [TimeInterval] = []
    public private(set) var blockedUntil: TimeInterval = 0
    public init(startsPerMinute: Int = 12) { self.startsPerMinute = max(1, startsPerMinute) }
    public mutating func imposeBackoff(until time: TimeInterval) { blockedUntil = max(blockedUntil, time) }
    /// Shared by foreground answers, retries, classifications, and summaries; manual never bypasses.
    public mutating func acquire(now: TimeInterval) -> Bool {
        starts.removeAll { $0 <= now - 60 }
        guard now.isFinite, now >= blockedUntil, starts.count < startsPerMinute else { return false }
        starts.append(now); return true
    }
    public func nextAllowedTime(now: TimeInterval) -> TimeInterval {
        max(now, blockedUntil, starts.count >= startsPerMinute ? (starts.first ?? now) + 60 : now)
    }
}
public struct PendingIntent: Sendable {
    public let question: QuestionState
    public let manual: Bool
    public let createdAt: TimeInterval
    public init(question: QuestionState, manual: Bool, createdAt: TimeInterval) {
        self.question = question; self.manual = manual; self.createdAt = createdAt
    }
}
public struct IntentArbitrator: Sendable {
    public private(set) var pending: PendingIntent?
    public init() {}
    public mutating func submit(_ intent: PendingIntent) {
        if pending?.manual == true, !intent.manual { return }
        pending = intent
    }
    public mutating func take(now: TimeInterval, maximumAge: TimeInterval = 5) -> PendingIntent? {
        defer { pending = nil }
        guard let pending, now - pending.createdAt <= maximumAge else { return nil }
        return pending
    }
    public mutating func clear() { pending = nil }
}

public enum RetryDecision: Equatable, Sendable { case stop, retry(after: TimeInterval) }
public enum RetryPolicy {
    public static func decision(status: Int?, attempt: Int, hasVisibleOutput: Bool, cancelled: Bool,
                                retryAfter: TimeInterval? = nil, now: TimeInterval, deadline: TimeInterval,
                                jitterUnit: Double = 0.5) -> RetryDecision {
        guard !cancelled, !hasVisibleOutput, attempt < 2 else { return .stop }
        if let status, status != 429, !(500...599).contains(status) { return .stop }
        let exponential = pow(2, Double(max(0, attempt))) * (0.75 + min(1, max(0, jitterUnit)) * 0.5)
        let delay = max(exponential, retryAfter ?? 0)
        guard now + delay < deadline else { return .stop }
        return .retry(after: delay)
    }
}
