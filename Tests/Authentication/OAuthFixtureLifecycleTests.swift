import Foundation
import Synchronization
import Testing
@testable import MeetingCopilot

private final class OAuthFixtureClientRecorder: NSObject, URLProtocolClient, Sendable {
    private let notifications = Mutex(0)
    var count: Int { notifications.withLock { $0 } }
    private func record() { notifications.withLock { $0 += 1 } }
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { record() }
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { record() }
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) { record() }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { record() }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { record() }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { record() }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { record() }
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { record() }
}

struct OAuthFixtureLifecycleTests {
    @Test func cancellationBeforeWorkerInstallationPreventsAllLaterClientNotifications() async throws {
        let (scenario, _) = OAuthFixtureURLProtocol.configuration([
            .init(body: Data("fixture".utf8), delay: .milliseconds(5), beforeWorkerInstallation: { $0.stopLoading() })
        ])
        defer { OAuthFixtureURLProtocol.remove(scenario) }
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.setValue(scenario, forHTTPHeaderField: "X-Test-Scenario")
        let client = OAuthFixtureClientRecorder()
        let loader = OAuthFixtureURLProtocol(request: request, cachedResponse: nil, client: client)
        loader.startLoading()
        try await Task.sleep(for: .milliseconds(30))
        #expect(client.count == 0)
        #expect(OAuthFixtureURLProtocol.record(scenario)?.stops == 1)
        loader.stopLoading()
    }
}
