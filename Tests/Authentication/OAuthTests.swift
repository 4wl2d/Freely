import AuthenticationServices
import Foundation
import Testing
@testable import MeetingCopilot

struct OAuthTests {
    @Test func missingRegistrationFailsClosedAndPKCEMatchesRFCVector() throws {
        #expect(throws: OAuthError.registrationRequired) { try SubscriptionClientConfiguration().validate() }
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let attempt = try OAuthAuthorizationAttempt(configuration: OAuthFixtures.configuration, discovery: OAuthFixtures.discovery,
            verifier: verifier, state: String(repeating: "s", count: 43))
        let parameters = try #require(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(parameters.first { $0.name == "code_challenge" }?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(parameters.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(parameters.first { $0.name == "client_id" }?.value == OAuthFixtures.configuration.clientID)
        #expect(parameters.first { $0.name == "code_verifier" } == nil)
        #expect(throws: OAuthError.invalidConfiguration) {
            try OAuthAuthorizationAttempt(configuration: OAuthFixtures.configuration, discovery: OAuthFixtures.discovery,
                verifier: String(repeating: "💥", count: 43), state: String(repeating: "s", count: 43))
        }
        let randomA = try OAuthAuthorizationAttempt.randomToken()
        let randomB = try OAuthAuthorizationAttempt.randomToken()
        #expect(randomA.count == 43 && randomB.count == 43 && randomA != randomB)
    }

    @Test func callbackRejectsWrongStateDuplicateParametersIssuerAndAmbiguousPath() throws {
        let state = String(repeating: "s", count: 43)
        let attempt = try OAuthAuthorizationAttempt(configuration: OAuthFixtures.configuration, discovery: OAuthFixtures.discovery,
            verifier: String(repeating: "v", count: 43), state: state)
        let valid = try #require(URL(string: "meetingcopilot://oauth/callback?state=\(state)&code=synthetic-code"))
        #expect(try attempt.authorizationCode(from: valid) == "synthetic-code")
        for text in [
            "meetingcopilot://oauth/callback?state=wrong&code=code", "meetingcopilot://other/callback?state=\(state)&code=code",
            "meetingcopilot://oauth/callback?state=\(state)&state=\(state)&code=code",
            "meetingcopilot://oauth/callback?state=\(state)&code=one&code=two",
            "meetingcopilot://oauth/callback?state=\(state)&code=one&error=access_denied",
            "meetingcopilot://oauth/callback?state=\(state)&code=one&iss=https://wrong.example",
            "meetingcopilot://oauth/%63allback?state=\(state)&code=one",
            "meetingcopilot://oauth/callback?state=\(state)&code=one#fragment"
        ] {
            let callback = try #require(URL(string: text))
            #expect(throws: OAuthError.invalidCallback) { try attempt.authorizationCode(from: callback) }
        }
    }

    @Test func callbackGateResolvesCancellationBeforeInstallationAndIgnoresDuplicates() async throws {
        let cancelled = OAuthResultGate<URL>()
        #expect(cancelled.resolve(.failure(CancellationError())))
        do { let _: URL = try await withCheckedThrowingContinuation { cancelled.install($0) }; Issue.record("Expected cancelled continuation") }
        catch { #expect(error is CancellationError) }
        #expect(!cancelled.resolve(.success(URL(string: "meetingcopilot://oauth/callback")!)))
        let completed = OAuthResultGate<String>()
        let task = Task { try await withCheckedThrowingContinuation { completed.install($0) } }
        #expect(completed.resolve(.success("synthetic-result")))
        #expect(!completed.resolve(.failure(OAuthError.denied)))
        #expect(try await task.value == "synthetic-result")
    }

    @Test func concurrentRefreshRotatesOnceAndPersistsBeforeReturning() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(), delay: .milliseconds(40))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        async let a = client.accessToken()
        async let b = client.accessToken()
        #expect(try await a == "synthetic-new-access")
        #expect(try await b == "synthetic-new-access")
        #expect(store.load()?.refreshToken == "synthetic-new-refresh")
        #expect(store.load()?.scope == "api:access offline_access")
        #expect(store.saves == 1)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 1)
    }

    @Test func cancellingOneRefreshWaiterPreservesTheOther() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(), delay: .milliseconds(100))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let cancelled = Task { try await client.accessToken() }
        let continuing = Task { try await client.accessToken() }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Expected waiter cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try await continuing.value == "synthetic-new-access")
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 1)
        #expect(store.saves == 1)
    }

    @Test func cancellingLastWaiterCancelsUnderlyingRefreshAndDoesNotSave() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: Data(), finish: false)])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let task = Task { try await client.accessToken() }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(store.saves == 0)
        // Foundation may acknowledge session invalidation before the test server's
        // stopLoading callback reaches this recorder. Await that distinct observation.
        try await OAuthFixtures.waitForStops(1, scenario: scenario)
        #expect((OAuthFixtureURLProtocol.record(scenario)?.stops ?? 0) > 0)
    }

    @Test func configurationChangeFencesRefreshAndItsJoiners() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(), delay: .seconds(2))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let first = Task { try await client.accessToken() }
        let second = Task { try await client.accessToken() }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        await client.configure(.init(clientID: "another-meetingcopilot-test-client"))
        for task in [first, second] {
            do { _ = try await task.value; Issue.record("Obsolete refresh must not return tokens") }
            catch { #expect(error is CancellationError || error as? OAuthError == .disconnected) }
        }
        #expect(store.saves == 0)
        #expect(try await client.hasSession() == false)
    }

    @Test func logoutDuringRefreshDeletesLocallyAndNeverRestoresOldTokens() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([
            .init(body: try OAuthFixtures.tokenResponse(), delay: .seconds(2)), .init(body: Data())
        ])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let pending = Task { try await client.accessToken() }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        try await client.disconnect()
        do { _ = try await pending.value; Issue.record("Logged-out refresh must cancel") }
        catch { #expect(error is CancellationError) }
        #expect(store.load() == nil)
        #expect(store.saves == 0)
        #expect(try await client.hasSession() == false)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.last?.url?.path == "/oauth2/revoke")
    }

    @Test func revocationFailureAndLocalDeletionFailureHaveHonestDistinctOutcomes() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(status: 503, body: Data())])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        do { try await client.disconnect(); Issue.record("Expected unconfirmed revocation") }
        catch { #expect(error as? OAuthError == .revocationUnconfirmed) }
        #expect(store.load() == nil)
        let locked = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        locked.failDeletion()
        let lockedClient = OAuthTokenClient(store: locked, sessionConfiguration: session)
        await lockedClient.configure(OAuthFixtures.configuration)
        do { try await lockedClient.disconnect(); Issue.record("Expected local deletion failure") }
        catch { #expect(error as? OAuthError == .localDeletionFailed) }
        #expect(locked.load() != nil)
        #expect(try await lockedClient.hasSession() == false)
    }

    @Test func invalidGrantExpiresSessionAndMalformedTokensNeverPersist() async throws {
        for (response, expected) in [
            (OAuthFixtureURLProtocol.Response(status: 400, body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"secret-provider-detail\"}".utf8)), OAuthError.expired),
            (.init(body: try OAuthFixtures.tokenResponse(access: "contains\nnewline")), .malformedResponse),
            (.init(body: try OAuthFixtures.tokenResponse(refresh: "")), .malformedResponse),
            (.init(body: try OAuthFixtures.tokenResponse(scope: "profile")), .scopeUnavailable),
            (.init(body: Data(repeating: 120, count: 65_537)), .malformedResponse)
        ] {
            let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
            let (scenario, session) = OAuthFixtureURLProtocol.configuration([response])
            defer { OAuthFixtureURLProtocol.remove(scenario) }
            let client = OAuthTokenClient(store: store, sessionConfiguration: session)
            await client.configure(OAuthFixtures.configuration)
            do { _ = try await client.accessToken(); Issue.record("Expected token rejection") }
            catch { #expect(error as? OAuthError == expected); #expect(!error.localizedDescription.contains("secret-provider-detail")) }
            #expect(store.saves == 0)
            if expected == .expired { #expect(store.load() == nil) }
        }
    }

    @Test func shortLivedRefreshedTokenDoesNotTriggerAnotherImmediateRefresh() async throws {
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(expires: 30))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        #expect(try await client.accessToken() == "synthetic-new-access")
        #expect(try await client.accessToken() == "synthetic-new-access")
        #expect(OAuthFixtureURLProtocol.record(scenario)?.requests.count == 1)
    }

    @Test func corruptStoredTokenSetCanStillBeDeletedWithoutClaimingRevocation() async throws {
        let store = UnreadableOAuthTokenStore()
        let client = OAuthTokenClient(store: store)
        await client.configure(OAuthFixtures.configuration)
        do { try await client.disconnect(); Issue.record("Unknown remote token cannot be confirmed revoked") }
        catch { #expect(error as? OAuthError == .revocationUnconfirmed) }
        #expect(store.deleted)
        #expect(try await client.hasSession() == false)
    }

    @Test func logoutCancelsAuthorizationCodeExchangeBeforeItCanRestoreTokens() async throws {
        let store = MemoryOAuthTokenStore()
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(), delay: .seconds(1))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let attempt = try OAuthAuthorizationAttempt(configuration: OAuthFixtures.configuration, discovery: OAuthFixtures.discovery)
        let exchange = Task { try await client.exchange(code: "synthetic-code", attempt: attempt) }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        try await client.disconnect()
        do { try await exchange.value; Issue.record("Logged-out exchange must cancel") }
        catch { #expect(error is CancellationError) }
        #expect(store.load() == nil && store.saves == 0)
    }

    @Test func preferredConnectionSwitchRejectsCredentialFromPreviousMethod() async throws {
        actor APIKeyFixture: CredentialStoring {
            func load() -> String? { "synthetic-optional-api-key" }
            func save(_ credential: String) {}
            func delete() {}
        }
        let store = MemoryOAuthTokenStore(OAuthFixtures.oldTokens())
        let (scenario, session) = OAuthFixtureURLProtocol.configuration([.init(body: try OAuthFixtures.tokenResponse(), delay: .milliseconds(50))])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        let client = OAuthTokenClient(store: store, sessionConfiguration: session)
        await client.configure(OAuthFixtures.configuration)
        let preferred = PreferredCredentialStore(apiKey: APIKeyFixture(), subscription: client)
        let old = Task { try await preferred.load() }
        try await OAuthFixtures.waitForRequests(1, scenario: scenario)
        await preferred.select(.apiKey)
        do { _ = try await old.value; Issue.record("Previous connection credential must be fenced") }
        catch { #expect(error is CancellationError) }
        #expect(try await preferred.load() == "synthetic-optional-api-key")
    }

    @Test func formEncodingPreservesReservedCharactersWithoutHeaderCredentials() {
        let body = String(decoding: OAuthTokenClient.form(["code": "a+b&c=d ?", "client_id": "own-client"]), as: UTF8.self)
        #expect(body == "client_id=own-client&code=a%2Bb%26c%3Dd%20%3F")
    }
}
