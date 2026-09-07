import CopilotCore
import Foundation
import Testing
@testable import MeetingCopilot

private actor ContextCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor SurfaceRecordingProvider: LLMProviding {
    private(set) var requests: [LLMRequest] = []
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Synthetic fixture answer")); continuation.yield(.completed); continuation.finish()
        }
    }
    func cancelAll() {}
}

@MainActor struct ContextSelectionPrivacyTests {
    @Test func profileDeselectedDuringScreenshotCannotReachOutboundRequestOrLaterHistory() async throws {
        let sessionID = SessionID(), epoch = SessionEpoch(1)
        let conversation = ConversationEngine()
        await conversation.begin(sessionID: sessionID, epoch: epoch)
        let canary = "PRIVATE-PROFILE-CANARY"
        let prior = QuestionState(text: "What is my professional background", triggerReason: .manual)
        await conversation.recordSuggestion(question: prior, text: canary, sessionEpoch: epoch)
        let gate = ContextCaptureGate()
        let screen = NativeScreenCapture(loadImage: { _, _ in
            await gate.wait()
            return .init(captureTime: Date(), width: 10, height: 10, png: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        })
        let provider = SurfaceRecordingProvider()
        let coordinator = GenerationCoordinator(conversation: conversation, screen: screen, provider: provider,
            rateBudget: SharedRequestBudget(), sessionEpoch: epoch, sessionID: sessionID,
            sessionOrigin: ProcessInfo.processInfo.systemUptime, options: .init(), onChange: { _, _ in })
        var profile = UserProfile(name: "Explicitly selected fixture")
        profile.role = canary
        coordinator.configureContext(profile: profile, notes: "", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        await coordinator.setScreenMode(.manual)
        await coordinator.setScreenSelection(.init(source: .init(id: "fixture", kind: .display, nativeID: 1,
            name: "Synthetic screen", application: nil, width: 100, height: 100)))
        coordinator.request(question: prior, manual: true, captureVisual: true)
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.started)
        // This is the exact synchronous boundary called by ApplicationModel's preference observer.
        coordinator.configureContext(profile: nil, notes: "", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        await gate.release()
        for _ in 0..<200 { if coordinator.ownedTaskCount == 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await provider.requests.isEmpty)
        coordinator.request(question: .init(text: "Continue without my saved profile", triggerReason: .manual), manual: true)
        for _ in 0..<200 { if coordinator.ownedTaskCount == 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let requests = await provider.requests
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { !$0.selectedContext.contains(canary) })
        await coordinator.stop()
    }
}
