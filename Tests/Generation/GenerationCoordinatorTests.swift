import FreelyCore
import Foundation
import Testing
@testable import Freely

struct GenerationCoordinatorTests {
    @Test @MainActor func synchronousScreenIntentFencesBeforeDeferredNativeCommitAndOldCommitsCannotRollBack() async throws {
        let provider = CoordinatorProvider()
        let screen = NativeScreenCapture(loadImage: { selection, _ in
            PreparedScreenImage(captureTime: Date(), width: 256, height: 256, png: Data([UInt8(selection.source.nativeID)]))
        })
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider, screen: screen)
        await coordinator.setScreenSelection(selection(1)); await coordinator.setScreenMode(.manual)
        coordinator.request(question: .init(text: "Explain the selected diagram"), manual: true, captureVisual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        await provider.emit(.textDelta("Earlier visual content"), request: 0)
        try await coordinatorEventually { recorder.answer.displayed?.text == "Earlier visual content" }
        let disabled = coordinator.prepareScreenMode(.off)
        #expect(recorder.answer.displayed == nil) // No MainActor Task/native actor hop was needed to fence it.
        let selected = coordinator.prepareScreenSelection(selection(2))
        let reenabled = coordinator.prepareScreenMode(.manual)
        await coordinator.setScreenMode(.off, preparedRevision: disabled)
        await coordinator.setScreenSelection(selection(2), preparedRevision: selected)
        // Submit before the latest UI commit; the generation must synchronize the desired pair itself.
        coordinator.request(question: .init(text: "Explain the new selected diagram"), manual: true, captureVisual: true)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].image?.bytes == Data([2]))
        await coordinator.setScreenMode(.manual, preparedRevision: reenabled)
        await coordinator.stop()
    }

    @Test @MainActor func identicalContextDoesNotCancelButMaterialNotesChangeDoes() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "Explain an active question"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.configureContext(profile: nil, notes: "", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        await provider.emit(.textDelta("Still valid"), request: 0)
        try await coordinatorEventually { recorder.answer.displayed?.text == "Still valid" }
        coordinator.configureContext(profile: nil, notes: "Use only local persistence", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        await provider.emit(.textDelta("Obsolete constraints"), request: 0)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(recorder.answer.displayed == nil)
        #expect(!recorder.texts.contains { $0.contains("Obsolete constraints") })
        coordinator.request(question: .init(text: "Explain the updated constraint"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].selectedContext.contains("Use only local persistence"))
        await coordinator.stop()
    }

    @Test @MainActor func deselectionPurgesDerivedSuggestionsWithoutErasingObservedConversation() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, conversation, _) = await makeGenerationFixture(provider: provider)
        var profile = UserProfile(name: "Selected profile"); profile.professionalBackground = "UNSELECTED_EMPLOYER_SECRET"
        coordinator.configureContext(profile: profile, notes: "", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        let original = QuestionState(text: "How would you implement a queue?")
        await conversation.recordSuggestion(question: original, text: "I did this at UNSELECTED_EMPLOYER_SECRET", sessionEpoch: .init(1))
        _ = await conversation.apply(.upsert(.init(source: .systemAudio, sequence: 1, startTime: 1, endTime: 2,
            text: "Shared queues preserve the observed ordering requirement")), sessionEpoch: .init(1), now: 3)
        coordinator.configureContext(profile: nil, notes: "", pinnedFacts: "", answerStyle: .concise, answerLanguage: "English")
        let followup = QuestionState(text: "Would that approach scale?", triggerReason: .followUp,
            relatedPriorQuestion: original.id, antecedent: original.text)
        coordinator.request(question: followup, manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        let context = await provider.requests[0].selectedContext
        #expect(!context.contains("UNSELECTED_EMPLOYER_SECRET"))
        #expect(context.contains("observed ordering requirement"))
        await coordinator.stop()
    }

    @Test @MainActor func pendingManualIntentCannotBeReplacedByAutomaticSpeechDuringCleanup() async throws {
        let gate = CoordinatorGate(), provider = CoordinatorProvider(cleanupGate: gate)
        let (coordinator, _, _) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "Explain the original automatic request"), manual: false)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.request(question: .init(text: "Explicit manual intent must win"), manual: true)
        for i in 0..<30 { coordinator.request(question: .init(text: "Explain automatic replacement \(i)"), manual: false) }
        #expect(coordinator.ownedTaskCount == 1)
        await gate.open()
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].selectedContext.contains("Explicit manual intent must win"))
        await coordinator.stop()
    }

    @Test @MainActor func rapidSupersessionRetainsOneTaskAndOnlyNewestIntent() async throws {
        let cleanup = CoordinatorGate(), provider = CoordinatorProvider(cleanupGate: cleanup)
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "How does the original request work?"), manual: false)
        try await coordinatorEventually { await provider.requests.count == 1 }
        await provider.emit(.textDelta("Original answer"), request: 0)
        try await coordinatorEventually { recorder.answer.displayed?.text == "Original answer" }
        for i in 0..<100 { coordinator.request(question: .init(text: "How does option \(i) work?"), manual: false) }
        #expect(coordinator.ownedTaskCount == 1)
        #expect(coordinator.hasPendingIntent)
        #expect(await provider.requests.count == 1)
        await cleanup.open()
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests.last?.selectedContext.contains("option 99") == true)
        await provider.emit(.textDelta("Late original must not appear"), request: 0)
        await provider.emit(.textDelta("Newest answer"), request: 1)
        await provider.emit(.completed, request: 1); await provider.finish(1)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(recorder.answer.displayed?.text == "Newest answer")
        #expect(recorder.answer.displayed?.lifecycle == .completed)
        #expect(!recorder.texts.contains { $0.contains("Late original") })
        #expect(await provider.maximumActiveStreams == 1)
        await coordinator.stop()
    }

    @Test @MainActor func manualRequestHasPriorityAndKeepsOnlyLatestAutomaticQuestion() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "Explain my explicit manual question"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.request(question: .init(text: "How does discarded automatic B work?"), manual: false)
        coordinator.request(question: .init(text: "How does newest automatic C work?"), manual: false)
        await provider.emit(.textDelta("Manual answer"), request: 0)
        try await coordinatorEventually { recorder.answer.displayed?.text == "Manual answer" }
        #expect(await provider.requests.count == 1)
        await provider.emit(.completed, request: 0); await provider.finish(0)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests.last?.selectedContext.contains("newest automatic C") == true)
        #expect(await provider.requests.last?.selectedContext.contains("discarded automatic B") == false)
        await provider.emit(.textDelta("C wins"), request: 1)
        await provider.emit(.completed, request: 1); await provider.finish(1)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(await provider.maximumActiveStreams == 1)
        await coordinator.stop()
    }

    @Test @MainActor func clearReleasesOwnershipSoBackgroundCompactionCanRunAgain() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, conversation, recorder) = await makeGenerationFixture(provider: provider, summaryFixture: true)
        coordinator.request(question: .init(text: "Explain the foreground request"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.clear()
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(recorder.answer.displayed == nil)
        await coordinator.compactIfNeeded(now: 310)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests.last?.trustedInstructions.hasPrefix("Summarize") == true)
        await provider.emit(.textDelta("The durable queue preserves order."), request: 1)
        await provider.emit(.completed, request: 1); await provider.finish(1)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(await conversation.rollingSummary()?.isExtractiveFallback == false)
        await coordinator.stop()
    }

    @Test @MainActor func foregroundCancelsAndAwaitsSummaryBeforeStartingProvider() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, _) = await makeGenerationFixture(provider: provider, summaryFixture: true)
        await coordinator.compactIfNeeded(now: 310)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.request(question: .init(text: "Answer the new foreground question"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests.last?.selectedContext.contains("new foreground") == true)
        #expect(await provider.maximumActiveStreams == 1)
        await provider.emit(.textDelta("Foreground answer"), request: 1)
        await provider.emit(.completed, request: 1); await provider.finish(1)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        await coordinator.stop()
    }

    @Test @MainActor func offlineSummaryFailureDoesNotCreatePeriodicRetryStorm() async throws {
        let provider = CoordinatorProvider(failure: .offline)
        let (coordinator, conversation, _) = await makeGenerationFixture(provider: provider, summaryFixture: true)
        await coordinator.compactIfNeeded(now: 310)
        try await coordinatorEventually { let count = await provider.requests.count; return coordinator.ownedTaskCount == 0 && count == 1 }
        for i in 1...40 { await coordinator.compactIfNeeded(now: 310 + Double(i)) }
        #expect(await provider.requests.count == 1)
        #expect(await conversation.rollingSummary()?.isExtractiveFallback == true)
        await coordinator.stop()
    }

    @Test @MainActor func unknownUsageStaysUnknownAndExplicitDetailedRequestReachesTransport() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "Show a detailed implementation"), manual: true, detailed: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        #expect(await provider.requests[0].detailed)
        await provider.emit(.textDelta("Implementation"), request: 0)
        await provider.emit(.usage(.init(inputTokens: 12, outputTokens: nil, totalTokens: nil, cachedInputTokens: nil, reasoningTokens: nil)), request: 0)
        await provider.emit(.completed, request: 0); await provider.finish(0)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(recorder.answer.displayed?.usage == nil)
        #expect(recorder.diagnostics.usage?.inputTokens == 12)
        #expect(recorder.diagnostics.usage?.outputTokens == nil)
        coordinator.configureContext(profile: nil, notes: "", pinnedFacts: "", answerStyle: .code, answerLanguage: "English")
        coordinator.request(question: .init(text: "Write the code"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].detailed)
        await coordinator.stop()
    }

    @Test @MainActor func selectionChangeWhileCaptureSuspendsNeverStartsAnUpload() async throws {
        let gate = CoordinatorGate()
        let screen = NativeScreenCapture(loadImage: { _, _ in
            await gate.wait()
            return PreparedScreenImage(captureTime: Date(), width: 256, height: 256, png: Data([1, 2, 3]))
        })
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider, screen: screen)
        await coordinator.setScreenSelection(selection(1))
        await coordinator.setScreenMode(.manual)
        coordinator.request(question: .init(text: "Explain this diagram"), manual: true, captureVisual: true)
        try await coordinatorEventually { recorder.diagnostics.status == "Capturing selected screen" }
        await coordinator.setScreenSelection(selection(2))
        await gate.open()
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(await provider.requests.isEmpty)
        #expect(recorder.answer.displayed?.text.isEmpty != false)
        await coordinator.stop()
    }

    @Test @MainActor func consentRevocationPurgesVisualAnswerAndRejectsLateChunks() async throws {
        let screen = NativeScreenCapture(loadImage: { _, _ in
            PreparedScreenImage(captureTime: Date(), width: 256, height: 256, png: Data([1, 2, 3]))
        })
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider, screen: screen)
        await coordinator.setScreenSelection(selection(1)); await coordinator.setScreenMode(.manual)
        coordinator.request(question: .init(text: "Explain this diagram"), manual: true, captureVisual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        #expect(await provider.requests[0].image != nil)
        await provider.emit(.textDelta("Visual-only content"), request: 0)
        try await coordinatorEventually { recorder.answer.displayed?.text == "Visual-only content" }
        await coordinator.setScreenMode(.off)
        await provider.emit(.textDelta("Late visual content"), request: 0)
        try await coordinatorEventually { coordinator.ownedTaskCount == 0 }
        #expect(recorder.answer.displayed == nil)
        #expect(!recorder.diagnostics.usesVisual)
        coordinator.request(question: .init(text: "Explain ordinary text context"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].image == nil)
        await coordinator.stop()
    }

    @Test @MainActor func repeatedStopTerminatesOwnedWorkAndBlocksNewRequests() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _, recorder) = await makeGenerationFixture(provider: provider)
        coordinator.request(question: .init(text: "Explain an active request"), manual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        async let first: Void = coordinator.stop()
        async let second: Void = coordinator.stop()
        await first; await second
        #expect(coordinator.ownedTaskCount == 0)
        #expect(await provider.activeStreamCount == 0)
        coordinator.request(question: .init(text: "Must never run after stop"), manual: true)
        #expect(await provider.requests.count == 1)
        #expect(recorder.answer.displayed == nil)
    }

    @Test @MainActor func visualRevocationPreservesAnAlreadyQueuedExplicitTextRequest() async throws {
        let gate = CoordinatorGate(), provider = CoordinatorProvider(cleanupGate: gate)
        let screen = NativeScreenCapture(loadImage: { _, _ in
            PreparedScreenImage(captureTime: Date(), width: 256, height: 256, png: Data([1, 2, 3]))
        })
        let (coordinator, _, _) = await makeGenerationFixture(provider: provider, screen: screen)
        await coordinator.setScreenSelection(selection(1)); await coordinator.setScreenMode(.manual)
        coordinator.request(question: .init(text: "Explain this diagram"), manual: true, captureVisual: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        coordinator.request(question: .init(text: "Now answer only the typed text"), manual: true)
        await coordinator.setScreenMode(.off)
        await gate.open()
        try await coordinatorEventually { await provider.requests.count == 2 }
        #expect(await provider.requests[1].image == nil)
        #expect(await provider.requests[1].selectedContext.contains("only the typed text"))
        await coordinator.stop()
        await coordinator.setScreenMode(.manual)
        do { _ = try await screen.capture(manual: true); Issue.record("Stopped generation cannot re-enable screen consent") }
        catch { #expect(error is ScreenCaptureFailure) }
    }

    @Test func requestBudgetSurvivesConfigurationChanges() async throws {
        let budget = SharedRequestBudget()
        await budget.configure(limit: 1)
        try await budget.acquire()
        await budget.configure(limit: 1)
        do { try await budget.acquire(); Issue.record("Configuration must not reset the request budget") }
        catch { #expect(error as? XAIError == .localRateLimited) }
        await budget.backoff(for: 30)
        do { try await budget.acquire(); Issue.record("Manual calls cannot bypass provider backoff") }
        catch { if case XAIError.rateLimited = error {} else { Issue.record("Expected provider backoff") } }
    }

    private func selection(_ id: UInt32) -> ScreenSelection {
        ScreenSelection(source: VisualSource(id: "fixture-\(id)", kind: .display, nativeID: id,
            name: "Fixture display \(id)", application: nil, width: 256, height: 256), region: nil)
    }
}
