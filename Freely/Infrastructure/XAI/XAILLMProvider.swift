import Foundation

public actor XAILLMProvider: LLMProviding {
    private let credentials: any CredentialStoring
    private let configuration: XAIConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let approveRequestStart: (@Sendable () async throws -> Void)?
    private var starts: [ContinuousClock.Instant] = []
    private var backoffUntil: ContinuousClock.Instant?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var operationEpoch: UInt64 = 0
    private var tearingDown = false

    public init(credentials: any CredentialStoring, configuration: XAIConfiguration = .init(),
                sessionConfiguration: URLSessionConfiguration = .ephemeral,
                approveRequestStart: (@Sendable () async throws -> Void)? = nil) {
        self.credentials = credentials
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
        self.approveRequestStart = approveRequestStart
    }

    public func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        try Task.checkCancellation()
        guard !tearingDown else { throw CancellationError() }
        guard jobs.count < 2 else { throw XAIError.localRateLimited }
        let requestedEpoch = operationEpoch
        let body = try JSONEncoder().encode(ResponsesRequest(request: request, configuration: configuration))
        guard let credential = try await credentials.load(), !credential.isEmpty else { throw XAIError.missingCredential }
        guard !credential.contains("\n"), !credential.contains("\r") else { throw XAIError.missingCredential }
        try Task.checkCancellation()
        // Credential lookup is an actor suspension point: recheck capacity before owning a new stream.
        guard !tearingDown, requestedEpoch == operationEpoch else { throw CancellationError() }
        guard jobs.count < 2 else { throw XAIError.localRateLimited }
        let jobID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    try await self.perform(body: body, credential: credential, detailed: request.detailed, continuation: continuation)
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError { continuation.finish(throwing: CancellationError()) }
                    else { continuation.finish(throwing: Self.redacted(error)) }
                }
                self.removeJob(jobID)
            }
            jobs[jobID] = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Session teardown awaits native transport and retry timers, not only the consumer's stream task.
    public func cancelAll() async {
        operationEpoch &+= 1
        let endingEpoch = operationEpoch
        tearingDown = true
        let owned = Array(jobs.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
        if operationEpoch == endingEpoch { tearingDown = false }
    }

    private func removeJob(_ id: UUID) { jobs[id] = nil }

    private func perform(body: Data, credential: String, detailed: Bool,
                         continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: detailed ? configuration.detailedDeadline : configuration.normalDeadline)
        let progress = StreamProgress()
        for attempt in 0...configuration.maxRetries {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw XAIError.deadlineExceeded }
            if let backoffUntil, clock.now < backoffUntil { throw XAIError.rateLimited(retryAfter: clock.now.duration(to: backoffUntil).seconds) }
            starts.removeAll { $0.duration(to: clock.now) >= .seconds(60) }
            guard starts.count < configuration.requestStartsPerMinute else { throw XAIError.localRateLimited }
            try await approveRequestStart?()
            try Task.checkCancellation()
            guard clock.now < deadline else { throw XAIError.deadlineExceeded }
            if let backoffUntil, clock.now < backoffUntil { throw XAIError.rateLimited(retryAfter: clock.now.duration(to: backoffUntil).seconds) }
            starts.removeAll { $0.duration(to: clock.now) >= .seconds(60) }
            guard starts.count < configuration.requestStartsPerMinute else { throw XAIError.localRateLimited }
            starts.append(clock.now)
            await progress.beginAttempt()
            do {
                try await attemptStream(body: body, credential: credential, deadline: deadline, progress: progress, continuation: continuation)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let failure = Self.redacted(error)
                let visible = await progress.emittedText
                if case .rateLimited(let after) = failure {
                    backoffUntil = clock.now.advanced(by: .seconds(after ?? 2))
                }
                guard !visible, attempt < configuration.maxRetries, Self.isRetryable(failure) else { throw failure }
                let delay = Self.retryDelay(failure: failure, attempt: attempt, jitter: Double.random(in: 0.8...1.2))
                guard clock.now.advanced(by: .seconds(delay)) < deadline else { throw failure }
                try Self.emit(.retryScheduled(attempt: attempt + 1, delaySeconds: delay), to: continuation)
                try await clock.sleep(for: .seconds(delay))
            }
        }
    }

    private func attemptStream(body: Data, credential: String, deadline: ContinuousClock.Instant, progress: StreamProgress,
                               continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        guard let endpoint = URL(string: "https://api.x.ai/v1/responses") else { throw XAIError.invalidConfiguration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = configuration.inactivityTimeout.seconds
        guard let config = sessionConfiguration.copy() as? URLSessionConfiguration else { throw XAIError.invalidConfiguration }
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = configuration.inactivityTimeout.seconds
        config.timeoutIntervalForResource = max(1, ContinuousClock().now.duration(to: deadline).seconds)
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let firstTimeout = configuration.firstOutputTimeout
        let inactiveTimeout = configuration.inactivityTimeout
        let immutableRequest = request
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: immutableRequest)
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse else { throw XAIError.network }
                    guard (200..<300).contains(http.statusCode) else {
                        throw Self.httpError(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    }
                    guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else { throw XAIError.malformedStream }
                    let zdr = http.value(forHTTPHeaderField: "x-zero-data-retention").flatMap { value -> Bool? in
                        switch value.lowercased() { case "true": true; case "false": false; default: nil }
                    }
                    try Self.emit(.providerPrivacy(zeroDataRetention: zdr), to: continuation)
                    var parser = SSEParser()
                    var decoder = ResponsesStreamDecoder()
                    var totalBytes = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        totalBytes += 1
                        guard totalBytes <= 4 * 1_024 * 1_024 else { throw XAIError.malformedStream }
                        // One actor hop per line, not per byte. Heartbeats count for inactivity, never first-answer time.
                        if byte == 10 || byte == 13 { await progress.activity() }
                        if let event = try parser.append(byte) {
                            for output in try decoder.decode(event) {
                                if case .textDelta(let text) = output { await progress.text(text) }
                                try Self.emit(output, to: continuation)
                            }
                            if decoder.terminal { return }
                        }
                    }
                    try parser.finish()
                    throw XAIError.earlyEOF
                }
                group.addTask {
                    let clock = ContinuousClock()
                    while true {
                        try await clock.sleep(for: .milliseconds(100))
                        if clock.now >= deadline { throw XAIError.deadlineExceeded }
                        if let timeout = await progress.timeout(now: clock.now, first: firstTimeout, inactive: inactiveTimeout) { throw timeout }
                    }
                }
                defer { group.cancelAll(); session.invalidateAndCancel() }
                _ = try await group.next()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private nonisolated static func emit(_ event: LLMEvent, to continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped: throw XAIError.outputBufferOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw XAIError.outputBufferOverflow
        }
    }

    static func httpError(status: Int, retryAfter: String?, now: Date = Date()) -> XAIError {
        switch status {
        case 401, 403: .unauthorized(status: status)
        case 429: .rateLimited(retryAfter: parseRetryAfter(retryAfter, now: now))
        case 500...599: .server(status: status)
        default: .rejected(status: status)
        }
    }

    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, 86_400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(86_400, max(0, date.timeIntervalSince(now)))
    }

    static func isRetryable(_ error: XAIError) -> Bool {
        switch error { case .server, .network, .rateLimited, .firstOutputTimeout, .inactivityTimeout: true; default: false }
    }

    static func retryDelay(failure: XAIError, attempt: Int, jitter: Double) -> Double {
        let base = min(4, pow(2, Double(attempt))) * min(1.2, max(0.8, jitter))
        if case .rateLimited(let retryAfter) = failure { return max(retryAfter ?? 2, base) }
        return base
    }

    private nonisolated static func redacted(_ error: any Error) -> XAIError {
        if let error = error as? XAIError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .timedOut: return .inactivityTimeout
            default: return .network
            }
        }
        return .network
    }
}

private actor StreamProgress {
    private var began = ContinuousClock().now
    private var lastActivity = ContinuousClock().now
    private var hasFirstOutput = false
    private(set) var emittedText = false
    func beginAttempt() { began = ContinuousClock().now; lastActivity = began; hasFirstOutput = false }
    func activity() { lastActivity = ContinuousClock().now }
    func text(_ text: String) {
        emittedText = true
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasFirstOutput = true }
    }
    func timeout(now: ContinuousClock.Instant, first: Duration, inactive: Duration) -> XAIError? {
        if !hasFirstOutput && began.duration(to: now) >= first { return .firstOutputTimeout }
        if lastActivity.duration(to: now) >= inactive { return .inactivityTimeout }
        return nil
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
