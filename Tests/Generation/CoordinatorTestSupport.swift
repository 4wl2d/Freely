import FreelyCore
import Foundation
import Testing
@testable import Freely

enum CoordinatorFixtureError: Error { case timeout }

@MainActor
func coordinatorEventually(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard clock.now < deadline else { Issue.record("Coordinator fixture did not reach its expected state"); throw CoordinatorFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}

actor CoordinatorGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let old = waiters; waiters = []
        for continuation in old { continuation.resume() }
    }
}

actor CoordinatorProvider: LLMProviding {
    private(set) var requests: [LLMRequest] = []
    private var streams: [Int: AsyncThrowingStream<LLMEvent, Error>.Continuation] = [:]
    private(set) var maximumActiveStreams = 0
    private(set) var cancellationCalls = 0
    var failure: XAIError?
    let cleanupGate: CoordinatorGate?
    init(failure: XAIError? = nil, cleanupGate: CoordinatorGate? = nil) { self.failure = failure; self.cleanupGate = cleanupGate }
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        try Task.checkCancellation()
        let id = requests.count; requests.append(request)
        if let failure { throw failure }
        let pair = AsyncThrowingStream<LLMEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        streams[id] = pair.continuation
        maximumActiveStreams = max(maximumActiveStreams, streams.count)
        return pair.stream
    }
    func emit(_ event: LLMEvent, request: Int) { streams[request]?.yield(event) }
    func finish(_ request: Int) { streams.removeValue(forKey: request)?.finish() }
    func fail(_ request: Int, error: XAIError) { streams.removeValue(forKey: request)?.finish(throwing: error) }
    func cancelAll() async {
        cancellationCalls += 1
        let old = streams; streams = [:]
        for continuation in old.values { continuation.finish(throwing: CancellationError()) }
        await cleanupGate?.wait()
    }
    var activeStreamCount: Int { streams.count }
}

struct CoordinatorCredential: CredentialStoring {
    func load() async throws -> String? { "test-only-placeholder" }
    func save(_ credential: String) async throws {}
    func delete() async throws {}
}

@MainActor
final class CoordinatorAnswerRecorder {
    var answer = AnswerPresentation()
    var diagnostics = GenerationDiagnostics()
    var texts: [String] = []
    func record(_ answer: AnswerPresentation, _ diagnostics: GenerationDiagnostics) {
        self.answer = answer; self.diagnostics = diagnostics
        if let text = answer.displayed?.text, texts.last != text { texts.append(text) }
    }
}

@MainActor
func makeGenerationFixture(provider: CoordinatorProvider, options: AIPreferences = .init(),
                           screen: NativeScreenCapture = .init(), summaryFixture: Bool = false) async ->
    (GenerationCoordinator, ConversationEngine, CoordinatorAnswerRecorder) {
    let conversation = ConversationEngine(limits: .init(maximumSegments: 8))
    let epoch = SessionEpoch(1), sessionID = SessionID()
    await conversation.begin(sessionID: sessionID, epoch: epoch)
    if summaryFixture {
        for i in 1...6 {
            let segment = TranscriptSegment(source: .systemAudio, sequence: UInt64(i), startTime: Double(i * 4),
                endTime: Double(i * 4 + 1), text: "The durable queue preserves request order \(i)")
            _ = await conversation.apply(.upsert(segment), sessionEpoch: epoch, now: Double(i * 4 + 2))
        }
    }
    let recorder = CoordinatorAnswerRecorder()
    let coordinator = GenerationCoordinator(conversation: conversation, screen: screen, provider: provider,
        rateBudget: SharedRequestBudget(), sessionEpoch: epoch, sessionID: sessionID,
        sessionOrigin: ProcessInfo.processInfo.systemUptime - 30, options: options,
        onChange: recorder.record)
    return (coordinator, conversation, recorder)
}

actor CoordinatorCapture: MicrophoneCapturing, SystemAudioCapturing {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var active = false
    private(set) var deviceIDs: [String?] = []
    private(set) var systemSelections: [SystemAudioSelection] = []
    private var ingress: AudioIngress?
    let startGate: CoordinatorGate?
    let stopGate: CoordinatorGate?
    var failStart = false
    init(startGate: CoordinatorGate? = nil, stopGate: CoordinatorGate? = nil, failStart: Bool = false) {
        self.startGate = startGate; self.stopGate = stopGate; self.failStart = failStart
    }
    func start(deviceID: String?, ingress: AudioIngress) async throws { deviceIDs.append(deviceID); try await start(ingress) }
    func start(selection: SystemAudioSelection, ingress: AudioIngress) async throws { systemSelections.append(selection); try await start(ingress) }
    private func start(_ ingress: AudioIngress) async throws {
        starts += 1
        await startGate?.wait()
        if failStart { throw AudioCaptureError.noDevice }
        // Deliberately emulate a late native start completion; the coordinator must clean it up.
        self.ingress = ingress; active = true
    }
    func stop() async {
        stops += 1; active = false
        ingress?.close(); ingress = nil
        await stopGate?.wait()
    }
    func feed(_ samples: [Float], timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        ingress?.offer(samples: samples, sampleRate: 16_000, timestamp: timestamp)
    }
    func permitStart() { failStart = false }
}

actor CoordinatorTranscriber: SpeechTranscribing {
    private(set) var activeCalls = 0
    private(set) var completedCalls = 0
    private(set) var stops = 0
    private(set) var cleanupOverlappedInference = false
    let suspendInference: Bool
    init(suspendInference: Bool = false) { self.suspendInference = suspendInference }
    func transcribe(_ samples: [Float]) async throws -> SpeechHypothesis {
        activeCalls += 1
        defer { activeCalls -= 1; completedCalls += 1 }
        if suspendInference { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        return SpeechHypothesis(text: "How should we preserve request ordering?", confidence: nil)
    }
    func stop() async { stops += 1; if activeCalls > 0 { cleanupOverlappedInference = true } }
}

actor CoordinatorModels {
    private(set) var sources: [AudioSource] = []
    private(set) var transcribers: [CoordinatorTranscriber] = []
    let gate: CoordinatorGate?
    let suspendInference: Bool
    init(gate: CoordinatorGate? = nil, suspendInference: Bool = false) { self.gate = gate; self.suspendInference = suspendInference }
    func make(_ source: AudioSource) async throws -> any SpeechTranscribing {
        sources.append(source)
        await gate?.wait()
        let transcriber = CoordinatorTranscriber(suspendInference: suspendInference)
        transcribers.append(transcriber)
        return transcriber
    }
}

@MainActor
final class CoordinatorSessionRecorder {
    var latest = SessionViewState()
    var phases: [SessionPhase] = []
    func record(_ value: SessionViewState) { latest = value; if phases.last != value.phase { phases.append(value.phase) } }
}

@MainActor
func makeSessionFixture(models: CoordinatorModels = .init(), microphone: CoordinatorCapture = .init(),
                        system: CoordinatorCapture = .init(), provider: CoordinatorProvider = .init()) ->
    (SessionCoordinator, CoordinatorSessionRecorder) {
    let recorder = CoordinatorSessionRecorder()
    let coordinator = SessionCoordinator(credentials: CoordinatorCredential(), rateBudget: SharedRequestBudget(),
        microphone: microphone, system: system, makeTranscriber: { source in try await models.make(source) },
        makeProvider: { _, _ in provider }, onState: recorder.record, onAnswer: { _, _ in })
    return (coordinator, recorder)
}

func coordinatorPreferences(microphone: Bool = true, system: Bool = false) -> AppPreferences {
    var preferences = AppPreferences()
    preferences.audio.microphoneEnabled = microphone
    preferences.audio.systemAudioEnabled = system
    preferences.audio.systemScope = .allSystemAudio
    return preferences
}
