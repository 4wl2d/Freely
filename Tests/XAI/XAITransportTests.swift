import Foundation
import Synchronization
import Testing
@testable import Freely

/// Test-only URLProtocol exercises Foundation's real AsyncBytes bridge without paid requests or actual credentials.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var chunks: [(Duration, Data)] = []
        var end = true
        var error: URLError.Code?
        var errorGate: OAuthResultGate<Void>?
    }
    struct Record: Sendable {
        let fixtures: [Fixture]
        var requests: [URLRequest] = []
        var stops = 0
    }
    static let records = Mutex<[String: Record]>([:])
    private let worker = Mutex<Task<Void, Never>?>(nil)
    private let key = Mutex<String?>(nil)
    static func install(_ fixtures: [Fixture]) -> String {
        let id = UUID().uuidString
        records.withLock { $0[id] = Record(fixtures: fixtures) }
        return id
    }
    static func record(_ id: String) -> Record? { records.withLock { $0[id] } }
    static func remove(_ id: String) { records.withLock { $0[id] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bytes: Data
        if let body = request.httpBody { bytes = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            bytes = data
        } else { bytes = Data() }
        struct Body: Decodable { let prompt_cache_key: String }
        let id: String
        do { id = try JSONDecoder().decode(Body.self, from: bytes).prompt_cache_key }
        catch { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        key.withLock { $0 = id }
        let fixture = Self.records.withLock { records -> Fixture? in
            guard var record = records[id] else { return nil }
            let index = min(record.requests.count, record.fixtures.count - 1)
            record.requests.append(request)
            records[id] = record
            return record.fixtures[index]
        }
        guard let fixture, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let task = Task { @Sendable [self, fixture] in
            do {
                for (delay, data) in fixture.chunks {
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                    client?.urlProtocol(self, didLoad: data)
                }
                if let gate = fixture.errorGate {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { gate.install($0) }
                    } onCancel: { gate.resolve(.failure(CancellationError())) }
                }
                if let error = fixture.error { client?.urlProtocol(self, didFailWithError: URLError(error)) }
                else if fixture.end { client?.urlProtocolDidFinishLoading(self) }
            } catch is CancellationError { /* Deliberate test-server cancellation. */ }
            catch { client?.urlProtocol(self, didFailWithError: URLError(.unknown)) }
        }
        worker.withLock { $0 = task }
    }
    override func stopLoading() {
        worker.withLock { $0?.cancel(); $0 = nil }
        if let id = key.withLock({ $0 }) { Self.records.withLock { $0[id]?.stops += 1 } }
    }
}

private actor TestCredentialStore: CredentialStoring {
    func load() -> String? { "synthetic-test-credential" }
    func save(_ credential: String) {}
    func delete() {}
}

private actor DelayedCredentialStore: CredentialStoring {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var started = false
    func load() async -> String? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: "synthetic-delayed-credential"); continuation = nil }
    func save(_ credential: String) {}
    func delete() {}
}

struct XAITransportTests {
    private let delta = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Answer\"}\n\n".utf8)
    private let completed = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8)
    private func provider(_ configuration: XAIConfiguration = .init()) -> XAILLMProvider {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FixtureURLProtocol.self]
        return XAILLMProvider(credentials: TestCredentialStore(), configuration: configuration, sessionConfiguration: session)
    }
    private func request(_ id: String) -> LLMRequest {
        .init(trustedInstructions: "Test", selectedContext: "Selected fixture", estimatedInputTokens: 20, sessionCacheKey: id)
    }

    @Test func foundationStreamsTextBeforeCompletionAndReportsPrivacyHeader() async throws {
        var fixture = FixtureURLProtocol.Fixture(chunks: [(.zero, delta), (.milliseconds(250), completed)])
        fixture.headers["x-zero-data-retention"] = "false"
        let id = FixtureURLProtocol.install([fixture])
        defer { FixtureURLProtocol.remove(id) }
        let started = ContinuousClock().now
        var first: Duration?
        var events: [LLMEvent] = []
        let outbound = request(id)
        for try await event in try await provider().stream(outbound) {
            events.append(event)
            if case .textDelta = event { first = started.duration(to: ContinuousClock().now) }
        }
        #expect(try #require(first) < .milliseconds(240))
        #expect(events == [.providerPrivacy(zeroDataRetention: false), .textDelta("Answer"), .completed])
        let recorded = try #require(FixtureURLProtocol.record(id)?.requests.first)
        #expect(recorded.url?.absoluteString == "https://api.x.ai/v1/responses")
        #expect(recorded.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-credential")
        let trace = FreelyLog.recorder.snapshot().events.filter { $0.scope.request == outbound.diagnosticRequestID }
        #expect(trace.map(\.name) == [.requestStarted, .responseReceived, .requestFinished])
        #expect(trace.first(where: { $0.name == .responseReceived })?.fields["httpStatus"] == "200")
        let diagnosticJSON = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        #expect(!diagnosticJSON.contains("synthetic-test-credential") && !diagnosticJSON.contains("Selected fixture"))
    }

    @Test func earlyEOFIsInterruptedAndNeverCompleted() async throws {
        let id = FixtureURLProtocol.install([.init(chunks: [(.zero, delta)])])
        defer { FixtureURLProtocol.remove(id) }
        var events: [LLMEvent] = []
        do {
            for try await event in try await provider().stream(request(id)) { events.append(event) }
            Issue.record("Early EOF must throw")
        } catch { #expect(error as? XAIError == .earlyEOF) }
        #expect(events.contains(.textDelta("Answer")))
        #expect(!events.contains(.completed))
        #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
    }

    @Test func temporaryFailureRetriesAtMostTwiceAndAuthorizationNeverRetries() async throws {
        let id = FixtureURLProtocol.install([.init(status: 503)])
        defer { FixtureURLProtocol.remove(id) }
        do {
            for try await _ in try await provider().stream(request(id)) {}
            Issue.record("503 must fail after bounded retries")
        } catch { #expect(error as? XAIError == .server(status: 503)) }
        #expect(FixtureURLProtocol.record(id)?.requests.count == 3)
        for status in [401, 403, 400] {
            let rejectedID = FixtureURLProtocol.install([.init(status: status)])
            defer { FixtureURLProtocol.remove(rejectedID) }
            do { for try await _ in try await provider().stream(request(rejectedID)) {}; Issue.record("Expected HTTP rejection") }
            catch { #expect(error as? XAIError == XAILLMProvider.httpError(status: status, retryAfter: nil)) }
            #expect(FixtureURLProtocol.record(rejectedID)?.requests.count == 1)
        }
    }

    @Test func noRetryAfterAnswerText() async throws {
        // URLProtocol didLoad can race with didFailWithError in Foundation's AsyncBytes bridge.
        // Inject the failure only after the consumer actually observes answer text.
        let gate = OAuthResultGate<Void>()
        let id = FixtureURLProtocol.install([.init(chunks: [(.zero, delta)], error: .networkConnectionLost, errorGate: gate)])
        defer { gate.resolve(.failure(CancellationError())); FixtureURLProtocol.remove(id) }
        var observedText = false
        do {
            for try await event in try await provider().stream(request(id)) {
                if case .textDelta = event { observedText = true; gate.resolve(.success(())) }
            }
            Issue.record("Connection loss must throw")
        } catch { #expect(error as? XAIError == .network) }
        #expect(observedText)
        #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
    }

    @Test func cancellationDuringBackoffDoesNotStartAnotherRequest() async throws {
        let id = FixtureURLProtocol.install([.init(status: 503)])
        defer { FixtureURLProtocol.remove(id) }
        let stream = try await provider().stream(request(id))
        let task = Task {
            do {
                for try await event in stream {
                    if case .retryScheduled = event { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch is CancellationError { }
            catch { Issue.record("Cancellation should not be an application failure") }
        }
        await task.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
    }

    @Test func cancellationStopsUnderlyingURLSessionTask() async throws {
        let id = FixtureURLProtocol.install([.init(chunks: [(.zero, delta)], end: false)])
        defer { FixtureURLProtocol.remove(id) }
        let stream = try await provider().stream(request(id))
        let task = Task {
            do {
                for try await event in stream {
                    if case .textDelta = event { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch is CancellationError { }
            catch { Issue.record("Cancellation should not fail") }
        }
        await task.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(try #require(FixtureURLProtocol.record(id)).stops > 0)
    }

    @Test func watchdogHandlesFirstOutputInactivityAndTotalDeadline() async throws {
        for mode in 0...2 {
            var config = XAIConfiguration()
            config.maxRetries = 0
            config.firstOutputTimeout = mode == 0 ? .milliseconds(40) : .seconds(2)
            config.inactivityTimeout = mode == 1 ? .milliseconds(40) : .seconds(2)
            config.normalDeadline = mode == 2 ? .milliseconds(40) : .seconds(2)
            let id = FixtureURLProtocol.install([.init(chunks: mode == 1 ? [(.zero, delta)] : [], end: false)])
            defer { FixtureURLProtocol.remove(id) }
            do { for try await _ in try await provider(config).stream(request(id)) {}; Issue.record("Expected watchdog timeout") }
            catch {
                let expected: XAIError = switch mode { case 0: .firstOutputTimeout; case 1: .inactivityTimeout; default: .deadlineExceeded }
                #expect(error as? XAIError == expected)
            }
            #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
        }
    }

    @Test func retryAfterBeyondDeadlineCreatesSharedBackoffWithoutAnotherRequest() async throws {
        let id = FixtureURLProtocol.install([.init(status: 429, headers: ["Retry-After": "5"])])
        defer { FixtureURLProtocol.remove(id) }
        var config = XAIConfiguration()
        config.normalDeadline = .seconds(1)
        let client = provider(config)
        for _ in 0...1 {
            do { for try await _ in try await client.stream(request(id)) {}; Issue.record("Expected 429") }
            catch { if case .rateLimited = error as? XAIError { } else { Issue.record("Expected typed rate limit") } }
        }
        #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
    }

    @Test func slowConsumerIsExplicitlyInterruptedAtBound() async throws {
        let body = Data((0..<400).map { _ in String(decoding: delta, as: UTF8.self) }.joined().utf8)
        let id = FixtureURLProtocol.install([.init(chunks: [(.zero, body), (.zero, completed)])])
        defer { FixtureURLProtocol.remove(id) }
        let client = provider()
        let stream = try await client.stream(request(id))
        try await Task.sleep(for: .milliseconds(250))
        var events = 0
        do { for try await _ in stream { events += 1 }; Issue.record("Expected bounded buffer overflow") }
        catch { #expect(error as? XAIError == .outputBufferOverflow) }
        #expect(events <= 256)
        await client.cancelAll()
        #expect(FixtureURLProtocol.record(id)?.requests.count == 1)
    }

    @Test func stopDuringCredentialLoadInvalidatesPendingOutboundWork() async throws {
        let id = FixtureURLProtocol.install([.init(chunks: [(.zero, completed)])])
        defer { FixtureURLProtocol.remove(id) }
        let credentials = DelayedCredentialStore()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FixtureURLProtocol.self]
        let client = XAILLMProvider(credentials: credentials, sessionConfiguration: session)
        let starting = Task { try await client.stream(request(id)) }
        for _ in 0..<100 {
            if await credentials.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await credentials.started)
        await client.cancelAll()
        await credentials.release()
        do { _ = try await starting.value; Issue.record("Start must be invalidated by stop") }
        catch { #expect(error is CancellationError) }
        #expect(FixtureURLProtocol.record(id)?.requests.isEmpty == true)
    }
}
