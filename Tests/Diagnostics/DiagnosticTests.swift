import FreelyCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import Freely

struct DiagnosticTests {
    @Test func ringRetainsNewestEventsAndAccountsForEviction() {
        let recorder = DiagnosticRecorder(capacity: 3)
        for index in 0..<8 { recorder.record(.debugMarker, fields: [.count: .int(index)]) }
        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.id) == [6, 7, 8])
        #expect(snapshot.events.map { $0.fields["count"] } == ["5", "6", "7"])
        #expect(snapshot.totalRecorded == 8 && snapshot.evicted == 5)
        #expect(snapshot.counts["info"] == 8)
        recorder.clear()
        recorder.record(.debugMarker)
        #expect(recorder.snapshot().events.first?.id == 9)
        #expect(recorder.snapshot().totalRecorded == 1 && recorder.snapshot().evicted == 0)
    }

    @Test func concurrentProducersPreserveUniqueOrderedIDsAndBoundedRetention() async {
        let recorder = DiagnosticRecorder(capacity: 127)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<500 { recorder.record(.debugMarker) }
                }
            }
        }
        let snapshot = recorder.snapshot()
        #expect(snapshot.totalRecorded == 4_000 && snapshot.events.count == 127)
        #expect(snapshot.evicted == 3_873)
        #expect(snapshot.events.map(\.id) == Array(UInt64(3_874)...4_000))
    }

    @Test func suppressedDebugStillMeasuresValidBoundedTimingSamples() {
        let recorder = DiagnosticRecorder()
        for index in 1...300 { recorder.record(.decodeCompleted, level: .debug, duration: Double(index)) }
        for value in [Double.nan, Double.infinity, -1] { recorder.record(.decodeCompleted, level: .debug, duration: value) }
        let snapshot = recorder.snapshot()
        #expect(snapshot.events.isEmpty && snapshot.suppressedDebug == 303)
        #expect(snapshot.timings.first?.count == 300 && snapshot.timings.first?.retainedSamples == 256)
        #expect(snapshot.timings.first?.p50 == 172 && snapshot.timings.first?.p95 == 288)
        #expect(snapshot.timings.first?.maximum == 300)
        recorder.setVerbose(true)
        recorder.record(.decodeCompleted, level: .debug, duration: 0.125)
        #expect(recorder.snapshot().events.count == 1)
        recorder.clear()
        #expect(recorder.snapshot().timings.isEmpty && recorder.snapshot().verbose)
    }

    @Test func errorProjectionAndExportExcludeUntrustedContent() throws {
        let secret = "SECRET-token-email-window-path-transcript"
        let recorder = DiagnosticRecorder()
        let native = NSError(domain: SCStreamErrorDomain, code: -3801,
            userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret])
        recorder.record(.sourceFailed, level: .error, fields: [.failure: .failure(native)])
        recorder.record(.operationFailed, fields: [.failure: .failure(NSError(domain: secret, code: 42))])
        recorder.record(.operationFailed, fields: [.failure: .failure(AudioCaptureError.configuration(secret))])
        recorder.record(.requestFailed, fields: [.failure: .failure(XAIError.unauthorized(status: 401))])
        recorder.record(.debugMarker, fields: [.durationSeconds: .number(.nan)])
        let data = try DiagnosticReport(recording: recorder.snapshot(), state: ["ready": .flag(false)]).json()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(secret))
        #expect(json.contains("-3801") && json.contains("other.42") && json.contains("xai.unauthorized.401"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test func applicationErrorsKeepStableClassifications() {
        #expect(DiagnosticValue.failure(GrokBuildError.incompatibleRuntime).text == "grok_build.incompatible_runtime")
        #expect(DiagnosticValue.failure(GrokBuildError.timedOut).text == "grok_build.timed_out")
        #expect(DiagnosticValue.failure(OAuthError.clientRejected).text == "oauth.client_rejected")
        #expect(DiagnosticValue.failure(ModelInstallError.checksumMismatch).text == "model.checksum_mismatch")
        #expect(DiagnosticValue.failure(ScreenCaptureFailure.stale).text == "screen.stale")
        #expect(DiagnosticValue.failure(AudioCaptureError.configuration("PRIVATE")).text == "audio.configuration")
    }

    @Test func filtersMatchSeverityCategoryAndFullCorrelationID() throws {
        let recorder = DiagnosticRecorder()
        let requestID = UUID()
        recorder.record(.requestFailed, level: .error, scope: .init(request: requestID), fields: [.failure: .failure(XAIError.offline)])
        let event = try #require(recorder.snapshot().events.first)
        #expect(event.matches(search: requestID.uuidString.lowercased(), minimumLevel: .warning, category: "network"))
        #expect(event.matches(search: "offline", minimumLevel: .error, category: ""))
        #expect(!event.matches(search: "", minimumLevel: .debug, category: "audio"))
        #expect(!event.matches(search: "missing", minimumLevel: .debug, category: ""))
    }

    @Test @MainActor func generationCorrelatesProviderRequestAndEventsWithoutContent() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, presentation) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "PRIVATE_QUESTION_SENTINEL"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        let request = try #require(await provider.requests.first)
        #expect(request.diagnosticSessionID != nil)
        #expect(presentation.diagnostics.requestID == request.diagnosticRequestID)
        await provider.emit(.textDelta("PRIVATE_ANSWER_SENTINEL"), request: 0)
        await provider.emit(.completed, request: 0)
        await provider.finish(0)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        let events = FreelyLog.recorder.snapshot().events.filter { $0.scope.request == request.diagnosticRequestID }
        #expect(events.contains { $0.name == .generationStarted })
        #expect(events.contains { $0.name == .generationFirstText })
        #expect(events.contains { $0.name == .generationCompleted })
        #expect(events.allSatisfy { $0.scope.session == request.diagnosticSessionID })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_QUESTION_SENTINEL") && !encoded.contains("PRIVATE_ANSWER_SENTINEL"))
        await coordinator.stop()
    }

    @Test func stoppedSourceKeepsOneSummaryWithFinalIngressCounters() async throws {
        let sessionID = UUID()
        let ingress = AudioIngress(maximumDuration: 0.02)
        for index in 0..<4 {
            ingress.offer(samples: [Float](repeating: 0, count: 320), sampleRate: 16_000, timestamp: Double(index) / 50)
        }
        let expected = ingress.snapshot()
        let pipeline = SourcePipeline(source: .systemAudio, streamEpoch: .init(7), ingress: ingress,
            transcriber: DiagnosticSilentTranscriber(), sessionOrigin: 0, sessionID: sessionID)
        await pipeline.stop()
        await pipeline.stop()
        let summaries = FreelyLog.recorder.snapshot().events.filter { $0.name == .sourceSummary && $0.scope.session == sessionID }
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.fields["frames"] == String(expected.receivedFrames))
        #expect(summary.fields["droppedSeconds"] == String(expected.droppedSeconds))
        #expect(summary.scope.source == .systemAudio)
    }

    @Test @MainActor func reportDoesNotSerializeUserFacingErrorsOrPreferences() throws {
        let model = ApplicationModel()
        let secret = "PRIVATE_PROFILE_AND_ERROR_SENTINEL"
        model.errorMessage = secret; model.recentErrors = [secret]
        model.sessionNotes = secret; model.pinnedFacts = secret; model.apiKeyDraft = secret
        model.preferences.ai.model = secret
        let json = String(decoding: try DiagnosticReport(recording: DiagnosticRecorder().snapshot(), state: model.diagnosticState).json(), as: UTF8.self)
        #expect(!json.contains(secret))
        #expect(json.contains("recentErrorCount") && json.contains("ownedSessionTasks"))
    }
}

private struct DiagnosticSilentTranscriber: SpeechTranscribing {
    func transcribe(_ samples: [Float]) async throws -> SpeechHypothesis { .init(text: "", confidence: nil) }
    func stop() async {}
}
