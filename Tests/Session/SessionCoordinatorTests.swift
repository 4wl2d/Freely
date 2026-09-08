import FreelyCore
import Foundation
import Testing
@testable import Freely

struct SessionCoordinatorTests {
    @Test @MainActor func deferredConsentFromAnEndedSessionCannotEnableTheNewSession() async throws {
        let (coordinator, _) = makeSessionFixture()
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        let old = coordinator.prepareScreenConsent(.manual)
        await coordinator.stop()
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        await coordinator.setScreenConsent(.manual, prepared: old)
        do { _ = try await coordinator.screen.capture(manual: true); Issue.record("Old consent must not cross a session boundary") }
        catch { if case ScreenCaptureFailure.disabled = error {} else { Issue.record("Expected screen context to remain off") } }
        await coordinator.stop()
    }

    @Test @MainActor func ambiguousApplicationInstancesAreRejectedInsteadOfChoosingAnArbitraryProcess() throws {
        let apps = [AudioApplication(id: 100, bundleID: "test.meeting", name: "First"),
                    AudioApplication(id: 200, bundleID: "test.meeting", name: "Second")]
        #expect(throws: AudioCaptureError.self) { try SessionCoordinator.applicationSelection(bundleID: "test.meeting", from: apps) }
        let selected = try SessionCoordinator.applicationSelection(bundleID: "test.meeting", from: [apps[0]])
        if case .application(let pid, let bundle) = selected { #expect(pid == 100); #expect(bundle == "test.meeting") }
        else { Issue.record("Application selection must never widen to system audio") }
    }

    @Test @MainActor func sourceSettingsChangeOnlyWhilePausedAndResumeUsesTheSelectedDevice() async throws {
        let microphone = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(microphone: microphone)
        var settings = coordinatorPreferences(); settings.audio.microphoneDeviceUID = "device-A"
        coordinator.start(preferences: settings, sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        var changed = settings.audio; changed.microphoneDeviceUID = "device-B"
        coordinator.updateSourceSettings(changed) // Running source must keep its current selection.
        coordinator.toggleSource(.localUser)
        try await coordinatorEventually { await microphone.active == false }
        coordinator.pauseOrResume()
        try await coordinatorEventually { let starts = await microphone.starts; return starts == 2 && recorder.latest.sources[.localUser] == .running }
        #expect(await microphone.deviceIDs == ["device-A", "device-A"])
        coordinator.toggleSource(.localUser)
        try await coordinatorEventually { await microphone.active == false }
        coordinator.updateSourceSettings(changed)
        coordinator.pauseOrResume()
        try await coordinatorEventually { let starts = await microphone.starts; return starts == 3 && recorder.latest.sources[.localUser] == .running }
        #expect(await microphone.deviceIDs.last == "device-B")
        await coordinator.stop()
    }

    @Test @MainActor func failedApplicationScopeCanBeExplicitlyChangedWithoutEndingConversation() async throws {
        let system = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(system: system)
        var settings = coordinatorPreferences(system: true)
        settings.audio.systemScope = .application; settings.audio.applicationBundleID = nil
        coordinator.start(preferences: settings, sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        if case .failed = recorder.latest.sources[.systemAudio] {} else { Issue.record("Expected missing application selection") }
        var recovered = settings.audio; recovered.systemScope = .allSystemAudio
        coordinator.updateSourceSettings(recovered); coordinator.toggleSource(.systemAudio)
        try await coordinatorEventually { recorder.latest.sources[.systemAudio] == .running }
        let selection = await system.systemSelections.last
        if case .allSystemAudio = selection {} else { Issue.record("Expected the explicit recovered scope") }
        #expect(coordinator.activeEpoch.rawValue == 1)
        await coordinator.stop()
    }

    @Test @MainActor func immediatePauseResumeBeforePreparationRunsStillCreatesAnswerServices() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, recorder) = makeSessionFixture(provider: provider)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        coordinator.pauseOrResume(); coordinator.pauseOrResume()
        try await coordinatorEventually { recorder.latest.sources[.localUser] == .running }
        coordinator.answerNow(text: "Explain the manual request after immediate pause")
        try await coordinatorEventually { await provider.requests.count == 1 }
        await coordinator.stop()
        #expect(coordinator.ownedTaskCount == 0)
    }

    @Test @MainActor func twoSourcesStartIndependentlyAndRepeatedStopLeavesNoOwnedWork() async throws {
        let models = CoordinatorModels(), microphone = CoordinatorCapture(), system = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(models: models, microphone: microphone, system: system)
        coordinator.start(preferences: coordinatorPreferences(system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        #expect(recorder.latest.sources[.localUser] == .running)
        #expect(recorder.latest.sources[.systemAudio] == .running)
        #expect(await models.sources == [.localUser, .systemAudio])
        #expect(await microphone.starts == 1); #expect(await system.starts == 1)
        async let first: Void = coordinator.stop()
        async let second: Void = coordinator.stop()
        await first; await second
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownedTaskCount == 0)
        #expect(await microphone.active == false); #expect(await system.active == false)
        for transcriber in await models.transcribers {
            #expect(await transcriber.stops >= 1)
            #expect(await transcriber.cleanupOverlappedInference == false)
        }
        #expect(recorder.latest.transcript.isEmpty)
        #expect(recorder.latest.metrics.isEmpty)
        #expect(recorder.latest.error == nil)
    }

    @Test @MainActor func stopDuringModelPreparationWaitsForLateResultAndNeverStartsCapture() async throws {
        let gate = CoordinatorGate(), models = CoordinatorModels(gate: gate), microphone = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { await models.sources.count == 1 }
        let stopping = Task { await coordinator.stop() }
        try await coordinatorEventually { coordinator.phase == .stopping }
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        #expect(await microphone.starts == 0)
        await gate.open(); await stopping.value
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownedTaskCount == 0)
        #expect(await microphone.starts == 0)
        #expect(await models.transcribers.first?.stops == 1)
        #expect(recorder.latest.error == nil)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        #expect(coordinator.activeEpoch.rawValue == 3)
        await coordinator.stop()
    }

    @Test @MainActor func stopDuringNativeStartCleansUpTheLateCaptureCompletion() async throws {
        let gate = CoordinatorGate(), microphone = CoordinatorCapture(startGate: gate), models = CoordinatorModels()
        let (coordinator, _) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { await microphone.starts == 1 }
        let stopping = Task { await coordinator.stop() }
        try await coordinatorEventually { coordinator.phase == .stopping }
        await gate.open(); await stopping.value
        #expect(await microphone.active == false)
        #expect(await microphone.stops >= 2)
        #expect(await models.transcribers.first?.stops == 1)
        #expect(coordinator.ownedTaskCount == 0)
    }

    @Test @MainActor func rapidPauseResumeKeepsNewestSourceIntentAndDoesNotLoseTheOldTask() async throws {
        let stopGate = CoordinatorGate(), microphone = CoordinatorCapture(stopGate: stopGate), models = CoordinatorModels()
        let (coordinator, recorder) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        coordinator.toggleSource(.localUser)
        try await coordinatorEventually { await microphone.stops == 1 }
        #expect(coordinator.phase == .paused)
        coordinator.pauseOrResume()
        #expect(coordinator.ownedTaskCount <= 4)
        await stopGate.open()
        try await coordinatorEventually { recorder.latest.sources[.localUser] == .running && coordinator.phase == .running }
        #expect(await microphone.starts == 2)
        #expect(await models.sources.count == 2)
        #expect(await microphone.active)
        await coordinator.stop()
        #expect(coordinator.ownedTaskCount == 0)
    }

    @Test @MainActor func pauseAndResumeWhilePreparingCannotActivateObsoleteCapture() async throws {
        let gate = CoordinatorGate(), models = CoordinatorModels(gate: gate), microphone = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { await models.sources.count == 1 }
        coordinator.pauseOrResume()
        #expect(coordinator.phase == .paused)
        coordinator.pauseOrResume()
        await gate.open()
        try await coordinatorEventually { recorder.latest.sources[.localUser] == .running }
        #expect(await microphone.starts == 1)
        #expect(await models.sources.count == 2)
        #expect(await models.transcribers.first?.stops == 1)
        await coordinator.stop()
        #expect(coordinator.ownedTaskCount == 0)
    }

    @Test @MainActor func wrongSourceAndObsoleteEpochCallbacksCannotMutateSessionPresentation() async throws {
        let (coordinator, recorder) = makeSessionFixture()
        coordinator.start(preferences: coordinatorPreferences(system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        let epoch = coordinator.activeEpoch
        let localEpoch = coordinator.currentSourceEpoch(.localUser), remoteEpoch = coordinator.currentSourceEpoch(.systemAudio)
        let accepted = TranscriptSegment(source: .systemAudio, streamEpoch: remoteEpoch, sequence: 1,
            startTime: 0, endTime: 0.1, text: "Known meeting evidence")
        await coordinator.receive(.upsert(accepted), source: .systemAudio, epoch: epoch, sourceEpoch: remoteEpoch)
        #expect(recorder.latest.transcript.count == 1)
        let forged = TranscriptSegment(source: .systemAudio, streamEpoch: remoteEpoch, sequence: 2,
            startTime: 0.2, endTime: 0.3, text: "Wrong callback source must be rejected")
        await coordinator.receive(.upsert(forged), source: .localUser, epoch: epoch, sourceEpoch: localEpoch)
        await coordinator.receive(.upsert(forged), source: .systemAudio, epoch: .init(), sourceEpoch: remoteEpoch)
        #expect(recorder.latest.transcript.count == 1)
        coordinator.toggleSource(.systemAudio)
        await coordinator.receive(.upsert(forged), source: .systemAudio, epoch: epoch, sourceEpoch: remoteEpoch)
        #expect(recorder.latest.transcript.count == 1)
        await coordinator.stop()
        coordinator.start(preferences: coordinatorPreferences(system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        await coordinator.receive(.upsert(forged), source: .systemAudio, epoch: epoch, sourceEpoch: remoteEpoch)
        #expect(recorder.latest.transcript.isEmpty)
        await coordinator.stop()
    }

    @Test @MainActor func failedSourceCanResumeWithoutRestartingHealthySource() async throws {
        let microphone = CoordinatorCapture(), system = CoordinatorCapture(failStart: true)
        let (coordinator, recorder) = makeSessionFixture(microphone: microphone, system: system)
        coordinator.start(preferences: coordinatorPreferences(system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        #expect(recorder.latest.sources[.localUser] == .running)
        if case .failed = recorder.latest.sources[.systemAudio] {} else { Issue.record("Expected per-source failure") }
        await system.permitStart(); coordinator.toggleSource(.systemAudio)
        try await coordinatorEventually { recorder.latest.sources[.systemAudio] == .running }
        #expect(await microphone.starts == 1)
        #expect(await system.starts == 2)
        await coordinator.stop()
    }

    @Test @MainActor func stopCancelsInferenceAndAwaitsQuiescenceBeforeDecoderCleanup() async throws {
        let models = CoordinatorModels(suspendInference: true), microphone = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        let transcriber = try #require(await models.transcribers.first)
        await microphone.feed(Array(repeating: 0.2, count: 8_000))
        try await coordinatorEventually { await transcriber.activeCalls == 1 }
        await coordinator.stop()
        #expect(await transcriber.activeCalls == 0)
        #expect(await transcriber.completedCalls == 1)
        #expect(await transcriber.stops == 1)
        #expect(await transcriber.cleanupOverlappedInference == false)
        #expect(coordinator.ownedTaskCount == 0)
        #expect(recorder.latest.error == nil)
    }

    @Test @MainActor func stopDuringSourceTransitionDropsQueuedResumeAndPreventsPostStopWork() async throws {
        let gate = CoordinatorGate(), microphone = CoordinatorCapture(stopGate: gate), models = CoordinatorModels()
        let (coordinator, _) = makeSessionFixture(models: models, microphone: microphone)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        coordinator.toggleSource(.localUser)
        try await coordinatorEventually { await microphone.stops >= 1 }
        coordinator.pauseOrResume()
        let stopping = Task { await coordinator.stop() }
        try await coordinatorEventually { coordinator.phase == .stopping }
        await gate.open(); await stopping.value
        #expect(await microphone.starts == 1)
        #expect(await models.sources.count == 1)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownedTaskCount == 0)
    }

    @Test @MainActor func answerNowThreadsDetailedFlagThroughRealCoordinatorBoundary() async throws {
        let provider = CoordinatorProvider()
        let (coordinator, _) = makeSessionFixture(provider: provider)
        coordinator.start(preferences: coordinatorPreferences(), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { coordinator.phase == .running }
        coordinator.answerNow(text: "Show a detailed code implementation", detailed: true)
        try await coordinatorEventually { await provider.requests.count == 1 }
        #expect(await provider.requests[0].detailed)
        await coordinator.stop()
    }
    @Test @MainActor func sessionResumeNeverReportsDisabledMicrophoneAsCapturing() async throws {
        let microphone = CoordinatorCapture(), system = CoordinatorCapture()
        let (coordinator, recorder) = makeSessionFixture(microphone: microphone, system: system)
        coordinator.start(preferences: coordinatorPreferences(microphone: false, system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: true)
        try await coordinatorEventually { recorder.latest.sources[.systemAudio] == .running }
        #expect(recorder.latest.sources[.localUser] == .stopped)
        coordinator.pauseOrResume()
        #expect(recorder.latest.sources[.localUser] == .stopped)
        coordinator.pauseOrResume()
        try await coordinatorEventually { recorder.latest.sources[.systemAudio] == .running }
        #expect(recorder.latest.sources[.localUser] == .stopped)
        #expect(await microphone.starts == 0)
        await coordinator.stop()
    }

}
