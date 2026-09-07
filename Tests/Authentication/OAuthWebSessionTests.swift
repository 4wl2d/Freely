import AuthenticationServices
import Foundation
import Testing
@testable import MeetingCopilot

@MainActor struct OAuthWebSessionTests {
    private func waitForSession(_ holder: WebSessionHolder) async throws {
        for _ in 0..<200 { if holder.session != nil { return }; try await Task.sleep(for: .milliseconds(2)) }
    }
    private func waitForCompletion(_ auth: SubscriptionAuthentication) async throws {
        for _ in 0..<200 { if !auth.signingIn { return }; try await Task.sleep(for: .milliseconds(2)) }
    }
    private func callback(_ authorizationURL: URL) throws -> URL {
        let state = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        return try #require(URL(string: "meetingcopilot://oauth/callback?state=\(state)&code=synthetic-authorized-code"))
    }

    @Test func cancelWithoutOSCallbackTerminatesAndAllowsAnotherAttempt() async throws {
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: OAuthFixtures.discoveryData)])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let holder = WebSessionHolder()
        let client = OAuthTokenClient(store: MemoryOAuthTokenStore(), sessionConfiguration: session)
        let auth = SubscriptionAuthentication(tokens: client, webSessionFactory: { url, completion in
            let session = FixtureWebSession(completion: completion); holder.session = session; holder.authorizationURL = url; return session
        })
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForSession(holder)
        #expect(holder.session?.starts == 1)
        let started = ContinuousClock().now
        await auth.shutdown()
        #expect(started.duration(to: ContinuousClock().now) < .milliseconds(300))
        #expect(!auth.signingIn && !auth.connected)
        #expect((holder.session?.cancels ?? 0) > 0)
        holder.session = nil
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForSession(holder)
        #expect(holder.session?.starts == 1)
        await auth.shutdown()
    }

    @Test func failedStartThenLateCallbackResumesOnlyOnce() async throws {
        let store = MemoryOAuthTokenStore()
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: OAuthFixtures.discoveryData)])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let holder = WebSessionHolder()
        let auth = SubscriptionAuthentication(tokens: OAuthTokenClient(store: store, sessionConfiguration: session), webSessionFactory: { url, completion in
            let session = FixtureWebSession(completion: completion); session.startResult = false
            holder.session = session; holder.authorizationURL = url; return session
        })
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForSession(holder)
        try await waitForCompletion(auth)
        let callback = try callback(#require(holder.authorizationURL))
        holder.session?.completion(callback, nil)
        holder.session?.completion(callback, nil)
        try await Task.sleep(for: .milliseconds(10))
        #expect(!auth.connected && !auth.signingIn)
        #expect(store.load() == nil)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 1)
        await auth.shutdown()
    }

    @Test func deadlineClosesAnUnansweredBrowserSession() async throws {
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: OAuthFixtures.discoveryData)])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let holder = WebSessionHolder()
        let auth = SubscriptionAuthentication(tokens: OAuthTokenClient(store: MemoryOAuthTokenStore(), sessionConfiguration: session),
            authorizationTimeout: .milliseconds(40), webSessionFactory: { url, completion in
                let session = FixtureWebSession(completion: completion); holder.session = session; holder.authorizationURL = url; return session
            })
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForCompletion(auth)
        #expect(!auth.signingIn && !auth.connected)
        #expect(auth.status.contains("timed out"))
        #expect((holder.session?.cancels ?? 0) > 0)
    }

    @Test func validPKCECallbackExchangesOnceButDoesNotClaimInferenceEntitlement() async throws {
        let store = MemoryOAuthTokenStore()
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([
            .init(body: OAuthFixtures.discoveryData), .init(body: try OAuthFixtures.tokenResponse())
        ])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let holder = WebSessionHolder()
        let auth = SubscriptionAuthentication(tokens: OAuthTokenClient(store: store, sessionConfiguration: session), webSessionFactory: { url, completion in
            let session = FixtureWebSession(completion: completion); holder.session = session; holder.authorizationURL = url; return session
        })
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForSession(holder)
        let callback = try callback(#require(holder.authorizationURL))
        holder.session?.completion(callback, nil)
        holder.session?.completion(callback, nil)
        try await waitForCompletion(auth)
        #expect(auth.connected && !auth.signingIn)
        #expect(auth.status.contains("verify"))
        #expect(store.saves == 1)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 2)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.last?.url?.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        await auth.shutdown()
    }

    @Test func configChangeWhileBrowserOpenRejectsLateCallback() async throws {
        let store = MemoryOAuthTokenStore()
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: OAuthFixtures.discoveryData)])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let holder = WebSessionHolder()
        let auth = SubscriptionAuthentication(tokens: OAuthTokenClient(store: store, sessionConfiguration: session), webSessionFactory: { url, completion in
            let session = FixtureWebSession(completion: completion); holder.session = session; holder.authorizationURL = url; return session
        })
        auth.signIn(configuration: OAuthFixtures.configuration, anchor: nil)
        try await waitForSession(holder)
        let callback = try callback(#require(holder.authorizationURL))
        await auth.configure(.init(clientID: "different-own-test-client"))
        holder.session?.completion(callback, nil)
        try await waitForCompletion(auth)
        #expect(!auth.connected && store.load() == nil)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 1)
        await auth.shutdown()
    }

    @Test func missingRegistrationNeverLaunchesBrowserOrNetwork() {
        let auth = SubscriptionAuthentication(webSessionFactory: { _, completion in
            Issue.record("Unregistered application must not open sign-in")
            return FixtureWebSession(completion: completion)
        })
        auth.signIn(configuration: .init(), anchor: nil)
        #expect(!auth.signingIn && !auth.connected)
        #expect(auth.status.contains("registration"))
    }

    @Test func disconnectReportsWhetherLocalCredentialsWereActuallyCleared() async throws {
        let locked = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        locked.failDeletion()
        let failed = SubscriptionAuthentication(tokens: OAuthTokenClient(store: locked))
        #expect(await failed.disconnect() == false)
        #expect(failed.status.contains("could not be removed"))
        #expect(locked.load() != nil)
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(status: 503, body: Data())])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let localSuccess = SubscriptionAuthentication(tokens: OAuthTokenClient(store: store, sessionConfiguration: session))
        #expect(await localSuccess.disconnect())
        #expect(localSuccess.status.contains("Local sign-in was cleared"))
        #expect(store.load() == nil)
    }
}

struct OAuthKeychainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGCOPILOT_KEYCHAIN_TEST"] == "1"))
    func syntheticTokenSetRotatesAtomicallyInAnIsolatedKeychainItem() throws {
        let store = OAuthTokenStore(service: "local.meetingcopilot.oauth-test.\(UUID().uuidString)")
        #expect(try store.load() == nil)
        do {
            let initial = OAuthFixtures.oldTokens()
            try store.save(initial)
            #expect(try store.load() == initial)
            let rotated = OAuthStoredTokens(accessToken: "synthetic-rotated-access", refreshToken: "synthetic-rotated-refresh", expiresAt: Date().addingTimeInterval(3_600), clientID: initial.clientID, scope: initial.scope)
            try store.save(rotated)
            #expect(try store.load() == rotated)
            try store.delete()
            #expect(try store.load() == nil)
            try store.delete()
        } catch {
            do { try store.delete() } catch { Issue.record("Synthetic Keychain cleanup failed") }
            throw error
        }
    }
}
