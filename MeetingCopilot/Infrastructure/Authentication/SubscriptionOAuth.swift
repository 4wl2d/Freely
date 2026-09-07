import AuthenticationServices
import CryptoKit
import Foundation
import Security
import AppKit
import Observation
import Synchronization

public enum ConnectionMethod: String, Codable, CaseIterable, Sendable {
    case subscription = "Grok subscription"
    case apiKey = "API key"
}

/// Values belong to a client registered specifically for this app. No other client's ID,
/// callback or credential is borrowed. The default build has no provider-issued client ID.
struct SubscriptionClientConfiguration: Codable, Equatable, Sendable {
    var clientID: String = ""
    var redirectURI: String = "meetingcopilot://oauth/callback"
    var issuer: String { "https://auth.x.ai" }
    var scopes: [String] { ["api:access", "offline_access"] }
    var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func validate() throws {
        guard isConfigured else { throw OAuthError.registrationRequired }
        guard clientID.utf8.count <= 256,
              clientID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }),
              redirectURI == "meetingcopilot://oauth/callback" else { throw OAuthError.invalidConfiguration }
    }
}

enum OAuthError: Error, LocalizedError, Sendable, Equatable {
    case registrationRequired, invalidConfiguration, randomFailure, invalidDiscovery, invalidCallback
    case denied, malformedResponse, expired, unavailable, clientRejected, scopeUnavailable, disconnected
    case timedOut, localDeletionFailed, revocationUnconfirmed
    var errorDescription: String? {
        switch self {
        case .registrationRequired: "Grok subscription connection needs an xAI OAuth registration for MeetingCopilot. Add the provider-issued client ID in advanced connection settings. No other application's client identity is used."
        case .invalidConfiguration: "The subscription client configuration is invalid. Use this application's registered client ID and callback."
        case .randomFailure: "A secure sign-in challenge could not be generated. Try again."
        case .invalidDiscovery: "xAI's OAuth server metadata did not match the supported secure endpoints. Sign-in was stopped."
        case .invalidCallback: "The sign-in callback did not match this attempt. Start sign-in again."
        case .denied: "Subscription sign-in was denied or cancelled. You can reconnect when ready."
        case .malformedResponse: "xAI returned an unsupported sign-in response. Reconnect or check this app's OAuth registration."
        case .expired: "The subscription session expired. Sign in again."
        case .unavailable: "The xAI authentication service could not be reached. Check the connection and try again."
        case .clientRejected: "xAI rejected this OAuth client. MeetingCopilot needs its own registered native client with the requested access."
        case .scopeUnavailable: "This OAuth registration does not grant inference access. Check the application's approved scopes with xAI."
        case .disconnected: "Connect your Grok subscription, or explicitly choose the optional API-key connection."
        case .timedOut: "Subscription sign-in timed out. Start sign-in again when ready."
        case .localDeletionFailed: "Local subscription credentials could not be removed. Unlock Keychain and retry disconnecting. Subscription use is blocked in this process."
        case .revocationUnconfirmed: "Local sign-in was cleared, but server-side revocation could not be confirmed. Manage connected applications in your xAI account."
        }
    }
}

struct OAuthDiscovery: Decodable, Sendable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let revocation_endpoint: URL?
    let scopes_supported: [String]
    let code_challenge_methods_supported: [String]
    let token_endpoint_auth_methods_supported: [String]
    let grant_types_supported: [String]
    let response_types_supported: [String]
    func validate() throws {
        guard issuer == "https://auth.x.ai",
              authorization_endpoint.absoluteString == "https://auth.x.ai/oauth2/authorize",
              token_endpoint.absoluteString == "https://auth.x.ai/oauth2/token",
              revocation_endpoint == nil || revocation_endpoint?.absoluteString == "https://auth.x.ai/oauth2/revoke",
              scopes_supported.contains("api:access"), scopes_supported.contains("offline_access"),
              code_challenge_methods_supported.contains("S256"),
              token_endpoint_auth_methods_supported.contains("none"),
              grant_types_supported.contains("authorization_code"), grant_types_supported.contains("refresh_token"),
              response_types_supported.contains("code") else {
            throw OAuthError.invalidDiscovery
        }
    }
}
struct OAuthAuthorizationAttempt: Sendable {
    let id: UUID
    let verifier: String
    let state: String
    let configuration: SubscriptionClientConfiguration
    let authorizationURL: URL
    init(configuration: SubscriptionClientConfiguration, discovery: OAuthDiscovery,
         verifier: String? = nil, state: String? = nil) throws {
        try configuration.validate(); try discovery.validate()
        self.id = UUID(); self.configuration = configuration
        self.verifier = try verifier ?? Self.randomToken()
        self.state = try state ?? Self.randomToken()
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard (43...128).contains(self.verifier.count), self.verifier.allSatisfy(unreserved.contains),
              (32...128).contains(self.state.count), self.state.allSatisfy(unreserved.contains) else { throw OAuthError.invalidConfiguration }
        let challenge = Data(SHA256.hash(data: Data(self.verifier.utf8))).base64URLEncodedString
        var components = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: self.state), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components?.url else { throw OAuthError.invalidConfiguration }
        authorizationURL = url
    }
    func authorizationCode(from callback: URL) throws -> String {
        guard callback.absoluteString.utf8.count <= 8_192,
              callback.scheme == "meetingcopilot", callback.host == "oauth", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == "/callback", (components.queryItems?.count ?? 0) <= 16 else { throw OAuthError.invalidCallback }
        let grouped = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        guard grouped["state"]?.count == 1, grouped["state"]?.first?.value == state else { throw OAuthError.invalidCallback }
        for field in ["code", "error", "error_description", "error_uri", "iss"] {
            guard (grouped[field]?.count ?? 0) <= 1 else { throw OAuthError.invalidCallback }
        }
        if let issuer = grouped["iss"]?.first?.value, issuer != configuration.issuer { throw OAuthError.invalidCallback }
        if let errors = grouped["error"] {
            guard grouped["code"] == nil, let error = errors.first?.value, !error.isEmpty else { throw OAuthError.invalidCallback }
            switch error { case "invalid_client", "unauthorized_client": throw OAuthError.clientRejected
            case "invalid_scope": throw OAuthError.scopeUnavailable; default: throw OAuthError.denied }
        }
        guard grouped["code"]?.count == 1, let code = grouped["code"]?.first?.value,
              OAuthStoredTokens.isOpaqueValue(code, limit: 4_096) else { throw OAuthError.invalidCallback }
        return code
    }
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw OAuthError.randomFailure }
        return Data(bytes).base64URLEncodedString
    }
}
private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
struct OAuthStoredTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let clientID: String
    let scope: String
    let refreshAfter: Date?
    init(accessToken: String, refreshToken: String?, expiresAt: Date, clientID: String, scope: String, refreshAfter: Date? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.clientID = clientID; self.scope = scope; self.refreshAfter = refreshAfter
    }
    func validated() throws -> Self {
        guard Self.isOpaqueValue(accessToken, limit: 32_768),
              refreshToken.map({ Self.isOpaqueValue($0, limit: 32_768) }) ?? true,
              !clientID.isEmpty, clientID.utf8.count <= 256,
              expiresAt.timeIntervalSince1970.isFinite,
              refreshAfter.map({ $0.timeIntervalSince1970.isFinite && $0 <= expiresAt }) ?? true,
              scope.utf8.count <= 2_048 else { throw OAuthError.malformedResponse }
        guard scope.split(separator: " ").contains("api:access") else { throw OAuthError.scopeUnavailable }
        return self
    }
    static func isOpaqueValue(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }
}
private struct OAuthTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Double
    let refresh_token: String?
    let scope: String?
}

protocol OAuthTokenStoring: Sendable {
    func load() throws -> OAuthStoredTokens?
    func save(_ value: OAuthStoredTokens) throws
    func delete() throws
}

/// Security operations are synchronous and atomic. OAuthTokenClient is their sole serial application owner,
/// so an epoch check and the following token write cannot be separated by an actor suspension.
struct OAuthTokenStore: OAuthTokenStoring {
    let service: String
    init(service: String = "local.meetingcopilot.subscription") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "oauth-tokens", kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }
    func load() throws -> OAuthStoredTokens? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
        guard let data = result as? Data, data.count <= 64 * 1_024 else { throw OAuthError.malformedResponse }
        do { return try JSONDecoder().decode(OAuthStoredTokens.self, from: data).validated() }
        catch { throw OAuthError.malformedResponse }
    }
    func save(_ value: OAuthStoredTokens) throws {
        let data = try JSONEncoder().encode(value.validated())
        guard data.count <= 64 * 1_024 else { throw OAuthError.malformedResponse }
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var query = query; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status: status) }
    }
}

/// Resolves a callback, cancellation or startup failure exactly once, including cancellation before installation.
final class OAuthResultGate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var resolved = false
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let ready: Result<Value, Error>? = state.withLock {
            if $0.resolved { return $0.result }
            $0.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }
    @discardableResult func resolve(_ result: Result<Value, Error>) -> Bool {
        let response: (Bool, CheckedContinuation<Value, Error>?) = state.withLock {
            guard !$0.resolved else { return (false, nil) }
            $0.resolved = true; $0.result = result
            let continuation = $0.continuation; $0.continuation = nil
            return (true, continuation)
        }
        response.1?.resume(with: result)
        return response.0
    }
}

actor OAuthTokenClient {
    let store: any OAuthTokenStoring
    private let sessionConfiguration: URLSessionConfiguration
    private var configuration = SubscriptionClientConfiguration()
    private var epoch: UInt64 = 0
    private var transitionEpoch: UInt64?
    private var networkTasks: [UUID: Task<Data, Error>] = [:]
    private var allowsStoredSession = true
    private var disconnectJob: (id: UUID, task: Task<Void, Error>)?
    private struct RefreshJob {
        let id: UUID
        let epoch: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: OAuthResultGate<OAuthStoredTokens>]
    }
    private var refresh: RefreshJob?
    init(store: any OAuthTokenStoring = OAuthTokenStore(), sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.store = store; self.sessionConfiguration = sessionConfiguration
    }
    func configure(_ configuration: SubscriptionClientConfiguration) async {
        guard self.configuration != configuration || transitionEpoch != nil else { return }
        epoch &+= 1
        let expected = epoch
        transitionEpoch = expected
        self.configuration = configuration
        let owned = cancelOwnedOperations()
        await awaitTermination(owned)
        if epoch == expected { transitionEpoch = nil }
    }
    func discovery() async throws -> OAuthDiscovery {
        try configuration.validate()
        let expected = epoch
        guard transitionEpoch == nil else { throw CancellationError() }
        let url = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
        let data = try await send(URLRequest(url: url))
        try Task.checkCancellation()
        guard epoch == expected else { throw CancellationError() }
        let result: OAuthDiscovery
        do { result = try JSONDecoder().decode(OAuthDiscovery.self, from: data) }
        catch { throw OAuthError.invalidDiscovery }
        try result.validate(); return result
    }
    func exchange(code: String, attempt: OAuthAuthorizationAttempt) async throws {
        try Task.checkCancellation()
        try configuration.validate()
        guard transitionEpoch == nil, disconnectJob == nil else { throw CancellationError() }
        guard attempt.configuration == configuration, OAuthStoredTokens.isOpaqueValue(code, limit: 4_096) else { throw OAuthError.invalidCallback }
        epoch &+= 1
        let expected = epoch
        transitionEpoch = expected
        let owned = cancelOwnedOperations()
        await awaitTermination(owned)
        defer { if transitionEpoch == expected { transitionEpoch = nil } }
        try Task.checkCancellation()
        guard expected == epoch, attempt.configuration == configuration else { throw CancellationError() }
        let requestedScopes = configuration.scopes.joined(separator: " ")
        let tokens = try await tokenRequest(fields: ["grant_type": "authorization_code", "code": code,
            "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI,
            "code_verifier": attempt.verifier], refreshToken: nil, previousScope: requestedScopes)
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
        try store.save(tokens)
        allowsStoredSession = true
    }
    func hasSession() async throws -> Bool {
        guard allowsStoredSession, transitionEpoch == nil, disconnectJob == nil, configuration.isConfigured,
              let tokens = try store.load()?.validated() else { return false }
        return tokens.clientID == configuration.clientID && (tokens.expiresAt > Date() || tokens.refreshToken != nil)
    }
    func accessToken() async throws -> String {
        try configuration.validate(); try Task.checkCancellation()
        guard transitionEpoch == nil, disconnectJob == nil, allowsStoredSession else { throw OAuthError.disconnected }
        guard let tokens = try store.load()?.validated(), tokens.clientID == configuration.clientID else { throw OAuthError.disconnected }
        let refreshTime = tokens.refreshAfter ?? tokens.expiresAt.addingTimeInterval(-60)
        if Date() < refreshTime || (tokens.refreshToken == nil && tokens.expiresAt > Date()) { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.expired }
        guard (refresh?.waiters.count ?? 0) < 8 else { throw OAuthError.unavailable }
        let expected = epoch
        if refresh == nil {
            let id = UUID()
            let clientID = configuration.clientID
            let task = Task { [self] in
                let result: Result<OAuthStoredTokens, Error>
                do {
                    let value = try await tokenRequest(fields: ["grant_type": "refresh_token", "refresh_token": refreshToken,
                        "client_id": clientID], refreshToken: refreshToken, previousScope: tokens.scope)
                    result = .success(value)
                } catch { result = .failure(error) }
                finishRefresh(id: id, expected: expected, result: result)
            }
            refresh = RefreshJob(id: id, epoch: expected, task: task, waiters: [:])
        }
        guard let refreshID = refresh?.id, refresh?.epoch == expected else { throw CancellationError() }
        let waiterID = UUID()
        let gate = OAuthResultGate<OAuthStoredTokens>()
        refresh?.waiters[waiterID] = gate
        let value: OAuthStoredTokens
        do {
            value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { gate.install($0) }
            } onCancel: { gate.resolve(.failure(CancellationError())) }
        } catch {
            let remainingTask = removeRefreshWaiter(waiterID, refreshID: refreshID)
            await remainingTask?.value
            throw error
        }
        try Task.checkCancellation()
        guard expected == epoch, allowsStoredSession, configuration.clientID == value.clientID else { throw CancellationError() }
        return value.accessToken
    }
    private func finishRefresh(id: UUID, expected: UInt64, result: Result<OAuthStoredTokens, Error>) {
        guard let current = refresh, current.id == id else { return }
        refresh = nil
        let completion: Result<OAuthStoredTokens, Error>
        if epoch != expected || !allowsStoredSession || current.task.isCancelled { completion = .failure(CancellationError()) }
        else {
            do {
                let value = try result.get()
                try store.save(value)
                completion = .success(value)
            } catch {
                if error as? OAuthError == .expired {
                    do { try store.delete() }
                    catch { for waiter in current.waiters.values { waiter.resolve(.failure(OAuthError.localDeletionFailed)) }; return }
                }
                completion = .failure(error)
            }
        }
        for waiter in current.waiters.values { waiter.resolve(completion) }
    }
    private func removeRefreshWaiter(_ waiterID: UUID, refreshID: UUID) -> Task<Void, Never>? {
        guard refresh?.id == refreshID else { return nil }
        refresh?.waiters[waiterID] = nil
        if refresh?.waiters.isEmpty == true {
            let task = refresh?.task
            refresh = nil
            task?.cancel()
            return task
        }
        return nil
    }
    func disconnect() async throws {
        if let disconnectJob { try await disconnectJob.task.value; return }
        epoch &+= 1; transitionEpoch = nil; allowsStoredSession = false
        let owned = cancelOwnedOperations()
        let stored: OAuthStoredTokens?
        let unreadable: Bool
        do { stored = try store.load(); unreadable = false }
        catch { stored = nil; unreadable = true }
        do { try store.delete() }
        catch { await awaitTermination(owned); throw OAuthError.localDeletionFailed }
        let id = UUID()
        let task = Task { [self] in
            await awaitTermination(owned)
            if unreadable { throw OAuthError.revocationUnconfirmed }
            guard let stored else { return }
            var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/revoke")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": stored.refreshToken ?? stored.accessToken,
                "client_id": stored.clientID, "token_type_hint": stored.refreshToken == nil ? "access_token" : "refresh_token"])
            do { _ = try await send(request) }
            catch { throw OAuthError.revocationUnconfirmed }
        }
        disconnectJob = (id, task)
        defer { if disconnectJob?.id == id { disconnectJob = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func cancelPending() async {
        epoch &+= 1
        let expected = epoch
        transitionEpoch = expected
        let owned = cancelOwnedOperations()
        let logout = disconnectJob?.task
        logout?.cancel()
        await awaitTermination(owned)
        _ = await logout?.result
        if epoch == expected { transitionEpoch = nil }
    }
    private func cancelOwnedOperations() -> (refresh: Task<Void, Never>?, network: [Task<Data, Error>]) {
        let previous = refresh
        refresh = nil
        previous?.task.cancel()
        if let previous { for waiter in previous.waiters.values { waiter.resolve(.failure(CancellationError())) } }
        let tasks = Array(networkTasks.values)
        for task in tasks { task.cancel() }
        return (previous?.task, tasks)
    }
    private func awaitTermination(_ owned: (refresh: Task<Void, Never>?, network: [Task<Data, Error>])) async {
        await owned.refresh?.value
        for task in owned.network { _ = await task.result }
    }
    private func tokenRequest(fields: [String: String], refreshToken: String?, previousScope: String) async throws -> OAuthStoredTokens {
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let data = try await send(request)
        let response: OAuthTokenResponse
        do { response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data) }
        catch { throw OAuthError.malformedResponse }
        guard response.token_type.lowercased() == "bearer", OAuthStoredTokens.isOpaqueValue(response.access_token, limit: 32_768),
              response.refresh_token.map({ OAuthStoredTokens.isOpaqueValue($0, limit: 32_768) }) ?? true,
              response.expires_in.isFinite, response.expires_in > 0, response.expires_in <= 31_536_000 else {
            throw OAuthError.malformedResponse
        }
        let scope = response.scope ?? previousScope
        guard scope.split(separator: " ").contains("api:access") else { throw OAuthError.scopeUnavailable }
        let now = Date()
        return try OAuthStoredTokens(accessToken: response.access_token, refreshToken: response.refresh_token ?? refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in), clientID: fields["client_id"] ?? "", scope: scope,
            refreshAfter: now.addingTimeInterval(response.expires_in - min(60, response.expires_in * 0.1))).validated()
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
                ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    private func send(_ input: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        guard networkTasks.count < 4, let config = sessionConfiguration.copy() as? URLSessionConfiguration else { throw OAuthError.unavailable }
        let id = UUID()
        let task = Task { try await Self.perform(input, configuration: config) }
        networkTasks[id] = task
        defer { networkTasks[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func perform(_ input: URLRequest, configuration config: URLSessionConfiguration) async throws -> Data {
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let delegate = OAuthRedirectGuard()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let completion: Result<Data, Error>
        do {
            let data = try await withTaskCancellationHandler {
                var request = input; request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw OAuthError.unavailable }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 64 * 1_024 else { throw OAuthError.malformedResponse }
                    data.append(byte)
                }
                if !(200..<300).contains(http.statusCode) {
                    struct Rejection: Decodable { let error: String }
                    let rejection: Rejection?
                    do { rejection = try JSONDecoder().decode(Rejection.self, from: data) } catch { rejection = nil }
                    switch rejection?.error {
                    case "invalid_grant": throw OAuthError.expired
                    case "invalid_scope": throw OAuthError.scopeUnavailable
                    case "access_denied": throw OAuthError.denied
                    default:
                        if [400, 401, 403].contains(http.statusCode) { throw OAuthError.clientRejected }
                        throw OAuthError.unavailable
                    }
                }
                return data
            } onCancel: { session.invalidateAndCancel() }
            completion = .success(data)
        } catch is CancellationError { completion = .failure(CancellationError()) }
        catch let error as OAuthError { completion = .failure(error) }
        catch { completion = .failure(Task.isCancelled ? CancellationError() : OAuthError.unavailable) }
        session.invalidateAndCancel()
        await delegate.waitForInvalidation()
        return try completion.get()
    }
}
private final class OAuthRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let invalidated = OAuthResultGate<Void>()
    func waitForInvalidation() async {
        // Invalidation is cleanup work and must complete even when the awaiting task is already cancelled.
        do { let _: Void = try await withCheckedThrowingContinuation { invalidated.install($0) } }
        catch { /* This gate is only resolved successfully by URLSession's invalidation callback. */ }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { invalidated.resolve(.success(())) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor PreferredCredentialStore: CredentialStoring {
    private let apiKey: any CredentialStoring
    private let subscription: OAuthTokenClient
    private var method: ConnectionMethod = .subscription
    private var epoch: UInt64 = 0
    init(apiKey: any CredentialStoring, subscription: OAuthTokenClient) { self.apiKey = apiKey; self.subscription = subscription }
    func select(_ method: ConnectionMethod) {
        guard self.method != method else { return }
        epoch &+= 1; self.method = method
    }
    func load() async throws -> String? {
        let expected = epoch
        let credential: String?
        if method == .apiKey { credential = try await apiKey.load() }
        else { credential = try await subscription.accessToken() }
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
        return credential
    }
    func save(_ credential: String) async throws { try await apiKey.save(credential) }
    func delete() async throws { try await apiKey.delete() }
}

@MainActor protocol OAuthWebAuthenticating: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: OAuthWebAuthenticating {}

typealias OAuthWebSessionFactory = @MainActor (URL, @escaping @Sendable (URL?, Error?) -> Void) -> any OAuthWebAuthenticating

@MainActor @Observable
final class SubscriptionAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    var status = "Connect a Grok subscription"
    var connected = false
    var signingIn = false
    private var webSession: (any OAuthWebAuthenticating)?
    private var authorizationGate: OAuthResultGate<URL>?
    private var loginTask: Task<Void, Never>?
    private weak var anchor: NSWindow?
    let tokens: OAuthTokenClient
    private var attemptID: UUID?
    private var loginID: UUID?
    private var configurationID = UUID()
    private var currentConfiguration = SubscriptionClientConfiguration()
    private let webSessionFactory: OAuthWebSessionFactory
    private let authorizationTimeout: Duration
    init(tokens: OAuthTokenClient = OAuthTokenClient(), authorizationTimeout: Duration = .seconds(600),
         webSessionFactory: @escaping OAuthWebSessionFactory = { url, completion in
             ASWebAuthenticationSession(url: url, callbackURLScheme: "meetingcopilot", completionHandler: completion)
         }) {
        self.tokens = tokens; self.authorizationTimeout = authorizationTimeout; self.webSessionFactory = webSessionFactory
        super.init()
    }
    func configure(_ configuration: SubscriptionClientConfiguration) async {
        let id = UUID(); configurationID = id
        if currentConfiguration != configuration {
            let previous = loginTask
            cancel(); currentConfiguration = configuration; connected = false
            await previous?.value
        }
        guard id == configurationID else { return }
        await tokens.configure(configuration)
        guard id == configurationID else { return }
        do {
            let hasSession = try await tokens.hasSession()
            guard id == configurationID else { return }
            connected = hasSession
        } catch { connected = false; if !signingIn { status = Self.message(error) }; return }
        if !signingIn {
            if connected { status = "Subscription connected · inference access not yet verified" }
            else if !configuration.isConfigured { status = OAuthError.registrationRequired.errorDescription ?? "Registration required" }
            else { status = "Connect a Grok subscription · app registration and inference entitlement must be verified" }
        }
    }
    func signIn(configuration: SubscriptionClientConfiguration, anchor: NSWindow?) {
        guard !signingIn else { return }
        do { try configuration.validate() } catch { status = Self.message(error); return }
        self.anchor = anchor
        currentConfiguration = configuration
        configurationID = UUID()
        let id = UUID(); loginID = id
        signingIn = true; status = "Opening secure xAI sign-in"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if loginID == id { signingIn = false; webSession = nil; authorizationGate = nil; attemptID = nil; loginID = nil; loginTask = nil }
            }
            do {
                await tokens.configure(configuration)
                let discovery = try await tokens.discovery()
                try Task.checkCancellation()
                guard loginID == id, currentConfiguration == configuration else { throw CancellationError() }
                let attempt = try OAuthAuthorizationAttempt(configuration: configuration, discovery: discovery)
                attemptID = attempt.id
                let callback = try await authorize(attempt)
                try Task.checkCancellation()
                guard attemptID == attempt.id else { throw CancellationError() }
                let code = try attempt.authorizationCode(from: callback)
                try await tokens.exchange(code: code, attempt: attempt)
                try Task.checkCancellation()
                guard loginID == id, currentConfiguration == configuration else { throw CancellationError() }
                connected = true
                status = "Subscription connected. Test generation to verify this application's model access and entitlement."
            } catch is CancellationError { if loginID == id { status = "Sign-in cancelled" } }
            catch { if loginID == id { status = Self.message(error) } }
        }
    }
    func cancel() {
        attemptID = nil
        authorizationGate?.resolve(.failure(CancellationError()))
        webSession?.cancel()
        loginTask?.cancel()
    }
    @discardableResult func disconnect() async -> Bool {
        cancel(); await loginTask?.value
        signingIn = true
        defer { signingIn = false }
        let localCleared: Bool
        do { try await tokens.disconnect(); status = "Subscription disconnected"; localCleared = true }
        catch { status = Self.message(error); localCleared = error as? OAuthError == .revocationUnconfirmed }
        connected = false
        return localCleared
    }
    func shutdown() async { cancel(); await tokens.cancelPending(); await loginTask?.value }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? NSApp.keyWindow ?? ASPresentationAnchor() }
    private func authorize(_ attempt: OAuthAuthorizationAttempt) async throws -> URL {
        try Task.checkCancellation()
        let gate = OAuthResultGate<URL>()
        authorizationGate = gate
        let deadline = Task { [weak self, authorizationTimeout] in
            do { try await Task.sleep(for: authorizationTimeout) } catch { return }
            guard let self, authorizationGate === gate else { return }
            gate.resolve(.failure(OAuthError.timedOut))
            webSession?.cancel()
        }
        defer {
            deadline.cancel()
            if authorizationGate === gate { authorizationGate = nil; webSession?.cancel(); webSession = nil }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.resolve(.failure(CancellationError())); return }
                let session = webSessionFactory(attempt.authorizationURL) { callback, error in
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { gate.resolve(.failure(CancellationError())) }
                    else if error != nil { gate.resolve(.failure(OAuthError.denied)) }
                    else if let callback { gate.resolve(.success(callback)) }
                    else { gate.resolve(.failure(OAuthError.denied)) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                webSession = session
                if !session.start() { gate.resolve(.failure(OAuthError.unavailable)) }
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
            Task { @MainActor [weak self] in
                if self?.authorizationGate === gate { self?.webSession?.cancel() }
            }
        }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? OAuthError { return error.errorDescription ?? "Subscription connection failed" }
        if let error = error as? CredentialStoreError { return error.errorDescription ?? "Keychain access failed" }
        return "The subscription connection failed. Check the connection and this application's registration, then retry."
    }
}
