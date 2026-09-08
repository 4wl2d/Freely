import Foundation

actor GrokBuildProvider: LLMProviding {
    let runtime: GrokBuildRuntime
    let configuration: XAIConfiguration
    private let approveRequestStart: @Sendable () async throws -> Void
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var stopping = false
    private var stopEpoch: UInt64 = 0

    init(runtime: GrokBuildRuntime, configuration: XAIConfiguration = .init(),
         approveRequestStart: @escaping @Sendable () async throws -> Void = {}) {
        self.runtime = runtime; self.configuration = configuration; self.approveRequestStart = approveRequestStart
    }
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        guard jobs.count < 2 else { throw XAIError.localRateLimited }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<LLMEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let task = Task { [runtime, configuration, approveRequestStart] in
            do {
                try await approveRequestStart()
                try Task.checkCancellation()
                try await runtime.generate(request, configuration: configuration) { event in
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw XAIError.outputBufferOverflow
                    case .terminated: throw CancellationError()
                    @unknown default: throw XAIError.outputBufferOverflow
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            self.remove(id)
        }
        jobs[id] = task
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }
    func cancelAll() async {
        stopEpoch &+= 1
        let epoch = stopEpoch
        stopping = true
        let owned = Array(jobs.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
        if stopEpoch == epoch { stopping = false }
    }
    private func remove(_ id: UUID) { jobs[id] = nil }
}

/// One explicit connection choice is captured for the lifetime of each provider.
/// No subscription failure falls back to an API key.
actor SelectedLLMProvider: LLMProviding {
    private let credentials: any CredentialStoring
    private let useGrokBuild: Bool
    private let configuration: XAIConfiguration
    private let approveRequestStart: @Sendable () async throws -> Void
    private var provider: (any LLMProviding)?
    init(credentials: any CredentialStoring, useGrokBuild: Bool, configuration: XAIConfiguration,
         approveRequestStart: @escaping @Sendable () async throws -> Void) {
        self.credentials = credentials; self.useGrokBuild = useGrokBuild; self.configuration = configuration
        self.approveRequestStart = approveRequestStart
    }
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        if provider == nil {
            provider = useGrokBuild
                ? GrokBuildProvider(runtime: try .installed(), configuration: configuration, approveRequestStart: approveRequestStart)
                : XAILLMProvider(credentials: credentials, configuration: configuration, approveRequestStart: approveRequestStart)
        }
        return try await provider!.stream(request)
    }
    func cancelAll() async { await provider?.cancelAll() }
}
