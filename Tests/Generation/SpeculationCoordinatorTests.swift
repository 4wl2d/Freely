import CopilotCore
import Foundation
import Testing
@testable import MeetingCopilot

private struct SpeculationFixtureMeasurement: Encodable {
    let mode: String
    let evidence = "scripted-virtual-time-no-live-api"
    let eligibleQuestionToVisibleMilliseconds: Double
    let requestCount: Int
    let speculativeRequests: Int
    let reusedRequests: Int
    let discardedRequests: Int
    let scriptedInputTokens: Int
    let scriptedOutputTokens: Int
}

@MainActor private final class SpeculationPlaybackTimeline {
    var now = 0.0
    var firstVisibleAt: Double?
}

struct SpeculationCoordinatorTests {
    @Test @MainActor func pairedScriptedReplayReportsBenefitAndChangedPrefixCostWithoutClaimingLiveLatency() async throws {
        let disabled = try await replay(enabled: false, changedQualification: false)
        let unchanged = try await replay(enabled: true, changedQualification: false)
        let changed = try await replay(enabled: true, changedQualification: true)
        #expect(disabled.requestCount == 1)
        #expect(disabled.speculativeRequests == 0)
        #expect(disabled.eligibleQuestionToVisibleMilliseconds == 500)
        #expect(unchanged.requestCount == 1)
        #expect(unchanged.reusedRequests == 1)
        #expect(unchanged.eligibleQuestionToVisibleMilliseconds == 0)
        #expect(changed.requestCount == 2)
        #expect(changed.discardedRequests == 1)
        #expect(changed.reusedRequests == 0)
        #expect(changed.eligibleQuestionToVisibleMilliseconds == 500)
        #expect(changed.scriptedInputTokens - disabled.scriptedInputTokens == 100)
        #expect(changed.scriptedOutputTokens - disabled.scriptedOutputTokens == 10)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("SPECULATION_FIXTURE_METRICS " + String(decoding: try encoder.encode([disabled, unchanged, changed]), as: UTF8.self))
    }

    @Test @MainActor func speculativePrefixIsAttemptedAtMostOncePerTurnAndStopsWithSession() async throws {
        var options = AIPreferences(); options.experimentalSpeculation = true
        let provider = CoordinatorProvider()
        let (coordinator, conversation, recorder) = await makeGenerationFixture(provider: provider, options: options)
        let id = SegmentID()
        let initial = TranscriptSegment(id: id, source: .systemAudio, sequence: 1, startTime: 0, endTime: 0.6,
            text: "How should we preserve durable request ordering", finality: .partial)
        let update = await conversation.apply(.upsert(initial), sessionEpoch: .init(1), now: 0.6)
        coordinator.observeTranscript(update, now: 0.6); coordinator.observeTranscript(update, now: 0.91)
        try await coordinatorEventually { await provider.requests.count == 1 }
        await provider.emit(.textDelta("Never reveal an unconfirmed prefix"), request: 0)
        let correction = TranscriptSegment(id: id, source: .systemAudio, sequence: 1, startTime: 0, endTime: 0.8,
            text: "How should we not preserve durable request ordering", finality: .partial, revision: 2)
        let changed = await conversation.apply(.upsert(correction), sessionEpoch: .init(1), now: 1)
        coordinator.observeTranscript(changed, now: 1)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        coordinator.observeTranscript(changed, now: 1.4); coordinator.observeTranscript(changed, now: 1.8)
        #expect(await provider.requests.count == 1)
        #expect(recorder.answer.displayed == nil)
        #expect(coordinator.speculationDiagnostics.discarded == 1)
        await coordinator.stop()
        coordinator.observeTranscript(changed, now: 2)
        #expect(coordinator.ownedTaskCount == 0)
        #expect(await provider.requests.count == 1)
    }

    @MainActor private func replay(enabled: Bool, changedQualification: Bool) async throws -> SpeculationFixtureMeasurement {
        let conversation = ConversationEngine()
        let sessionID = SessionID(), epoch = SessionEpoch(1), provider = CoordinatorProvider()
        await conversation.begin(sessionID: sessionID, epoch: epoch)
        var options = AIPreferences(); options.experimentalSpeculation = enabled
        let timeline = SpeculationPlaybackTimeline()
        let recorder = CoordinatorAnswerRecorder()
        let coordinator = GenerationCoordinator(conversation: conversation, screen: NativeScreenCapture(), provider: provider,
            rateBudget: SharedRequestBudget(), sessionEpoch: epoch, sessionID: sessionID,
            sessionOrigin: ProcessInfo.processInfo.systemUptime, options: options,
            onChange: { answer, diagnostics in
                recorder.record(answer, diagnostics)
                if let text = answer.displayed?.text, !text.isEmpty, timeline.firstVisibleAt == nil { timeline.firstVisibleAt = timeline.now }
            })
        let segmentID = SegmentID()
        let prefix = "How should we preserve durable request ordering"
        let partial = TranscriptSegment(id: segmentID, source: .systemAudio, sequence: 1, startTime: 0,
            endTime: 0.6, text: prefix, finality: .partial)
        let partialUpdate = await conversation.apply(.upsert(partial), sessionEpoch: epoch, now: 0.6)
        coordinator.observeTranscript(partialUpdate, now: 0.6)
        timeline.now = 0.91; coordinator.observeTranscript(partialUpdate, now: timeline.now)
        if enabled {
            try await coordinatorEventually { await provider.requests.count == 1 }
            timeline.now = 0.95
            await provider.emit(.textDelta("Persist before sending."), request: 0)
            await provider.emit(.usage(.init(inputTokens: 100, outputTokens: 10, totalTokens: 110, cachedInputTokens: 0, reasoningTokens: 0)), request: 0)
            await provider.emit(.completed, request: 0); await provider.finish(0)
            try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
            #expect(timeline.firstVisibleAt == nil)
        } else { #expect(await provider.requests.isEmpty) }
        timeline.now = 1
        let finalText = changedQualification ? "How should we not preserve durable request ordering?" : prefix + "?"
        let final = TranscriptSegment(id: segmentID, source: .systemAudio, sequence: 1, startTime: 0,
            endTime: 0.6, text: finalText, finality: .final, revision: 2)
        let finalUpdate = await conversation.apply(.finalize(final), sessionEpoch: epoch, now: timeline.now)
        let question = try #require(finalUpdate.newQuestion)
        coordinator.observeTranscript(finalUpdate, now: timeline.now)
        coordinator.request(question: question, manual: false)
        if !enabled || changedQualification {
            let expected = enabled ? 2 : 1
            try await coordinatorEventually { await provider.requests.count == expected }
            timeline.now = 1.5
            let index = expected - 1
            await provider.emit(.textDelta(changedQualification ? "Clarify the reversed constraint." : "Persist before sending."), request: index)
            await provider.emit(.usage(.init(inputTokens: 100, outputTokens: 10, totalTokens: 110, cachedInputTokens: 0, reasoningTokens: 0)), request: index)
            await provider.emit(.completed, request: index); await provider.finish(index)
        }
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        let shownAt = try #require(timeline.firstVisibleAt)
        if changedQualification { #expect(!recorder.texts.contains("Persist before sending.")) }
        let requests = await provider.requests.count
        let stats = coordinator.speculationDiagnostics
        let result = SpeculationFixtureMeasurement(mode: !enabled ? "disabled" : changedQualification ? "enabled-changed-prefix" : "enabled-unchanged-prefix",
            eligibleQuestionToVisibleMilliseconds: (shownAt - 1) * 1_000, requestCount: requests,
            speculativeRequests: stats.requests, reusedRequests: stats.reused, discardedRequests: stats.discarded,
            scriptedInputTokens: requests * 100, scriptedOutputTokens: requests * 10)
        await coordinator.stop()
        return result
    }
}
