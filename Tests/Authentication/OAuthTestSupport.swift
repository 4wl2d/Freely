import AuthenticationServices
import Foundation
import Synchronization
@testable import Freely

final class MemoryOAuthTokenStore: OAuthTokenStoring {
    private struct State { var tokens: OAuthStoredTokens?; var saves = 0; var deleteFails = false }
    private let state = Mutex(State())
    init(_ tokens: OAuthStoredTokens? = nil) { state.withLock { $0.tokens = tokens } }
    func load() -> OAuthStoredTokens? { state.withLock { $0.tokens } }
    func save(_ value: OAuthStoredTokens) throws { _ = try value.validated(); state.withLock { $0.tokens = value; $0.saves += 1 } }
    func delete() throws {
        try state.withLock { if $0.deleteFails { throw CredentialStoreError.keychain(status: -25291) }; $0.tokens = nil }
    }
    var saves: Int { state.withLock { $0.saves } }
    func failDeletion() { state.withLock { $0.deleteFails = true } }
}

final class UnreadableOAuthTokenStore: OAuthTokenStoring {
    private let removed = Mutex(false)
    func load() throws -> OAuthStoredTokens? { if removed.withLock({ $0 }) { return nil }; throw OAuthError.malformedResponse }
    func save(_ value: OAuthStoredTokens) {}
    func delete() { removed.withLock { $0 = true } }
    var deleted: Bool { removed.withLock { $0 } }
}

final class OAuthFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body: Data
        var delay: Duration = .zero
        var finish = true
        var headers: [String: String] = ["Content-Type": "application/json"]
        var beforeWorkerInstallation: (@Sendable (OAuthFixtureURLProtocol) -> Void)?
    }
    struct Record: Sendable { let responses: [Response]; var requests: [URLRequest] = []; var stops = 0 }
    static let records = Mutex<[String: Record]>([:])
    // Client callbacks may synchronously re-enter stopLoading. One recursive lock serializes
    // that terminal transition with worker installation and notification delivery.
    private let lifecycle = NSRecursiveLock()
    private var worker: Task<Void, Never>?
    private var scenario: String?
    private var stopped = false
    static func configuration(_ responses: [Response]) -> (String, URLSessionConfiguration) {
        let id = UUID().uuidString
        records.withLock { $0[id] = Record(responses: responses) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixtureURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Scenario": id]
        return (id, config)
    }
    static func record(_ id: String) -> Record? { records.withLock { $0[id] } }
    static func remove(_ id: String) { records.withLock { $0[id] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopped else { return }
        guard let id = request.value(forHTTPHeaderField: "X-Test-Scenario") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        scenario = id
        let fixture = Self.records.withLock { records -> Response? in
            guard var record = records[id], !record.responses.isEmpty else { return nil }
            let response = record.responses[min(record.requests.count, record.responses.count - 1)]
            record.requests.append(request); records[id] = record
            return response
        }
        guard let fixture, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        fixture.beforeWorkerInstallation?(self)
        guard !stopped else { return }
        let task = Task { @Sendable [self, fixture] in
            do {
                try await Task.sleep(for: fixture.delay)
                try Task.checkCancellation()
                if !fixture.body.isEmpty {
                    guard notifyClient({ client?.urlProtocol(self, didLoad: fixture.body) }) else { return }
                }
                if fixture.finish { _ = notifyClient { client?.urlProtocolDidFinishLoading(self) } }
            } catch { /* Test-only server honors cancellation without late native delivery. */ }
        }
        // The task cannot notify a client until this same lock releases after registration.
        worker = task
        // Keep the initial response on the URL loading thread; body delivery starts
        // only after registration and this header callback release the lifecycle lock.
        _ = notifyClient { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
    }
    override func stopLoading() {
        lifecycle.lock()
        guard !stopped else { lifecycle.unlock(); return }
        stopped = true
        let owned = worker, id = scenario
        worker = nil
        // Publish stop observation before cancellation can wake the awaiting request/test.
        if let id { Self.records.withLock { $0[id]?.stops += 1 } }
        lifecycle.unlock()
        owned?.cancel()
    }
    private func notifyClient(_ body: () -> Void) -> Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopped, !Task.isCancelled else { return false }
        body()
        return !stopped
    }
}

enum OAuthFixtures {
    enum Failure: Error {
        case requestStartTimeout(expected: Int, observed: Int)
        case requestStopTimeout(expected: Int, observed: Int)
    }
    static var configuration: SubscriptionClientConfiguration { .init(clientID: "freely-test-only") }
    static let discoveryData = Data("""
    {"issuer":"https://auth.x.ai","authorization_endpoint":"https://auth.x.ai/oauth2/authorize","token_endpoint":"https://auth.x.ai/oauth2/token","revocation_endpoint":"https://auth.x.ai/oauth2/revoke","scopes_supported":["api:access","offline_access"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"],"grant_types_supported":["authorization_code","refresh_token"],"response_types_supported":["code"]}
    """.utf8)
    static var discovery: OAuthDiscovery { get throws { try JSONDecoder().decode(OAuthDiscovery.self, from: discoveryData) } }
    static func oldTokens(clientID: String = configuration.clientID, refresh: String? = "synthetic-old-refresh") -> OAuthStoredTokens {
        .init(accessToken: "synthetic-old-access", refreshToken: refresh, expiresAt: Date().addingTimeInterval(-1), clientID: clientID, scope: "api:access offline_access")
    }
    static func tokenResponse(access: String = "synthetic-new-access", refresh: String? = "synthetic-new-refresh", expires: Double = 3_600, scope: String? = nil) throws -> Data {
        var value: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expires]
        if let refresh { value["refresh_token"] = refresh }
        if let scope { value["scope"] = scope }
        return try JSONSerialization.data(withJSONObject: value)
    }
    static func waitForRequests(_ count: Int, scenario: String) async throws {
        for _ in 0..<200 {
            if (OAuthFixtureURLProtocol.record(scenario)?.requests.count ?? 0) >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure.requestStartTimeout(expected: count, observed: OAuthFixtureURLProtocol.record(scenario)?.requests.count ?? 0)
    }
    static func waitForStops(_ count: Int, scenario: String) async throws {
        for _ in 0..<200 {
            if (OAuthFixtureURLProtocol.record(scenario)?.stops ?? 0) >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure.requestStopTimeout(expected: count, observed: OAuthFixtureURLProtocol.record(scenario)?.stops ?? 0)
    }
}

@MainActor final class FixtureWebSession: OAuthWebAuthenticating {
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var prefersEphemeralWebBrowserSession = false
    var startResult = true
    private(set) var starts = 0
    private(set) var cancels = 0
    let completion: @Sendable (URL?, Error?) -> Void
    init(completion: @escaping @Sendable (URL?, Error?) -> Void) { self.completion = completion }
    func start() -> Bool { starts += 1; return startResult }
    func cancel() { cancels += 1 } // Deliberately no callback: the application must resolve cancellation itself.
}
@MainActor final class WebSessionHolder { var session: FixtureWebSession?; var authorizationURL: URL? }
