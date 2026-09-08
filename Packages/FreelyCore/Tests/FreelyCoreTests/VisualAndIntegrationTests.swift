import Foundation
import Testing
@testable import FreelyCore

private func visual(selection: SelectionEpoch, source: String = "window-42", epoch: SessionEpoch = .init(1),
                    question: QuestionState, time: Double = 5, bytes: Int = 32) -> VisualSnapshot {
    .init(sourceSelection: source, captureTime: time, selectionEpoch: selection, sessionEpoch: epoch,
          questionID: question.id, questionRevision: question.revision, width: 1_024, height: 768,
          contentHash: "fixture-content-hash", image: Data(repeating: 0, count: bytes))
}

@Test func screenshotCompletingAfterSelectionChangedCannotCommit() {
    var state = VisualContextState()
    state.configure(mode: .manual, selectedSource: "window-42")
    let question = QuestionState(text: "Explain the selected diagram")
    let pending = visual(selection: state.selectionEpoch, question: question)
    state.configure(mode: .manual, selectedSource: "window-84")
    #expect(state.accept(pending, sessionEpoch: .init(1), question: question, now: 6) == false)
    #expect(state.active == nil)
    let next = visual(selection: state.selectionEpoch, source: "window-84", question: question)
    #expect(state.accept(next, sessionEpoch: .init(1), question: question, now: 6) == true)
    #expect(state.selectedImage(sessionEpoch: .init(1), question: question, now: 36) == nil)
}

@Test func disabledScreenConsentPurgesAndFencesEverything() {
    var state = VisualContextState()
    let question = QuestionState(text: "Explain code on screen")
    state.configure(mode: .automatic, selectedSource: "window-42")
    let snapshot = visual(selection: state.selectionEpoch, question: question)
    #expect(state.accept(snapshot, sessionEpoch: .init(1), question: question, now: 6) == true)
    state.configure(mode: .off, selectedSource: "window-42")
    #expect(state.active == nil)
    #expect(state.accept(snapshot, sessionEpoch: .init(1), question: question, now: 7) == false)
    #expect(state.selectedImage(sessionEpoch: .init(1), question: question, now: 7) == nil)
    state.configure(mode: .manual, selectedSource: "window-42")
    #expect(state.accept(snapshot, sessionEpoch: .init(1), question: question, now: 7) == false)
}

@Test func visualQuestionSessionBytesAndSourceDisappearFences() {
    var state = VisualContextState()
    state.configure(mode: .manual, selectedSource: "window-42")
    let question = QuestionState(text: "Explain this diagram")
    let snapshot = visual(selection: state.selectionEpoch, question: question)
    #expect(state.accept(snapshot, sessionEpoch: .init(2), question: question, now: 6) == false)
    let corrected = QuestionState(id: question.id, revision: 2, text: "Explain only the red arrow")
    #expect(state.accept(snapshot, sessionEpoch: .init(1), question: corrected, now: 6) == false)
    let huge = visual(selection: state.selectionEpoch, question: question, bytes: 4 * 1_024 * 1_024 + 1)
    #expect(state.accept(huge, sessionEpoch: .init(1), question: question, now: 6) == false)
    state.configure(mode: .manual, selectedSource: nil)
    #expect(state.accept(snapshot, sessionEpoch: .init(1), question: question, now: 6) == false)
}

@Test func cropGeometryHandlesBackingScalesRotationsAndBounds() throws {
    let retina = try #require(CropGeometry.pixels(x: 10, y: 20, width: 200, height: 100,
        logicalWidth: 1_000, logicalHeight: 800, pixelWidth: 2_000, pixelHeight: 1_600))
    #expect(retina == PixelCrop(x: 20, y: 40, width: 400, height: 200))
    let normal = try #require(CropGeometry.pixels(x: 10, y: 20, width: 200, height: 100,
        logicalWidth: 1_000, logicalHeight: 800, pixelWidth: 1_000, pixelHeight: 800))
    #expect(normal.width == 200)
    let clipped = try #require(CropGeometry.pixels(x: -10, y: 10, width: 40, height: 50,
        logicalWidth: 80, logicalHeight: 100, pixelWidth: 160, pixelHeight: 200))
    #expect(clipped.x == 0)
    #expect(clipped.width == 60)
    #expect(CropGeometry.pixels(x: 200, y: 10, width: 40, height: 50,
        logicalWidth: 80, logicalHeight: 100, pixelWidth: 160, pixelHeight: 200) == nil)
    #expect(CropGeometry.pixels(x: .nan, y: 10, width: 40, height: 50,
        logicalWidth: 80, logicalHeight: 100, pixelWidth: 160, pixelHeight: 200) == nil)
}

@Test func speculationIsOffByDefaultAndInvalidatesChangedPrefix() throws {
    let question = QuestionState(text: "How should retries work")
    var gate = SpeculationGate()
    #expect(gate.begin(question: question, sessionEpoch: .init(1), highConfidence: true) == nil)
    gate.enabled = true
    #expect(gate.begin(question: question, sessionEpoch: .init(1), highConfidence: false) == nil)
    let first = gate.begin(question: question, sessionEpoch: .init(1), highConfidence: true)
    #expect(first != nil)
    #expect(gate.begin(question: question, sessionEpoch: .init(1), highConfidence: true) == nil)
    let revised = QuestionState(id: question.id, revision: 2, text: "How should retries not work")
    #expect(gate.update(question: revised, sessionEpoch: .init(1)) == false)
    #expect(gate.identity == nil)
}

@Test func audioTimelineUsesSourceDurationAndIndependentStreamState() {
    var timeline = AudioTimeline()
    let samples = [Float](repeating: 0, count: 1_600)
    let first = AudioFrame(source: .systemAudio, epoch: .init(1), sequence: 1, timestamp: 1, samples: samples)
    #expect(first.duration == 0.1)
    #expect(timeline.observe(first) == nil)
    let local = AudioFrame(source: .localUser, epoch: .init(1), sequence: 1, timestamp: 10, samples: samples)
    #expect(timeline.observe(local) == nil)
    let next = AudioFrame(source: .systemAudio, epoch: .init(1), sequence: 2, timestamp: 1.1, samples: samples)
    #expect(timeline.observe(next) == nil)
    let overflow = AudioFrame(source: .systemAudio, epoch: .init(1), sequence: 3, timestamp: 2.2, samples: samples)
    let gap = timeline.observe(overflow)
    #expect(abs((gap?.droppedDuration ?? 0) - 1) < 0.00001)
    #expect(gap?.source == .systemAudio)
    let changed = AudioFrame(source: .systemAudio, epoch: .init(1), streamEpoch: .init(2), sequence: 1, timestamp: 5, samples: samples)
    #expect(timeline.observe(changed) == nil)
}

@Test func diagnosticsRetainOnlyBoundedRecentMeasurements() {
    var metric = BoundedMetric(capacity: 100)
    for value in 1...10_000 { metric.record(Double(value)) }
    metric.record(.infinity); metric.record(-1)
    let result = metric.snapshot
    #expect(result.count == 10_000)
    #expect(result.retainedSamples == 100)
    #expect(result.p50 == 9_950)
    #expect(result.p95 == 9_995)
}

@Test func pinDuringStreamingActuallyFreezesDisplayedText() {
    var view = AnswerPresentation()
    let question = QuestionState(text: "What is durable ordering?")
    let id = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: 1)
    view.begin(identity: id, question: question)
    view.append("Durable", identity: id)
    view.pin()
    #expect(!view.newAnswerAvailable)
    view.append(" ordering", identity: id)
    #expect(view.displayed?.text == "Durable")
    #expect(view.latestReplacement?.text == "Durable ordering")
    view.unpin()
    #expect(view.displayed?.text == "Durable ordering")
}

@Test func technicalOperatorCorrectionIsMaterial() {
    #expect(IntentHeuristics.materialText("Why use x != nil?") != IntentHeuristics.materialText("Why use x == nil?"))
    #expect(IntentHeuristics.materialText("What is foo.bar?") != IntentHeuristics.materialText("What is foobar?"))
    #expect(IntentHeuristics.materialText("Explain StateFlow!") == IntentHeuristics.materialText("explain StateFlow?"))
}

/// Scripted provider exists only in this test target, with explicit chunks instead of network/model claims.
private struct ScriptedProvider: Sendable {
    let chunks: [String]
    func stream(context: ContextSnapshot) -> AsyncStream<String> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

@Test func twoSourceReplayThroughContextAndObservableAnswer() async throws {
    let engine = ConversationEngine()
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    _ = await engine.apply(.upsert(segment("We need crash-safe delivery", source: .localUser, start: 1, end: 2)), sessionEpoch: epoch, now: 2.4)
    _ = await engine.apply(.upsert(segment("How would you implement", sequence: 1, start: 3, end: 3.5, finality: .partial)), sessionEpoch: epoch, now: 3.5)
    let finalID = SegmentID()
    _ = await engine.apply(.upsert(segment("How would you implement", id: finalID, sequence: 2, start: 5, end: 5.5)), sessionEpoch: epoch, now: 5.5)
    let update = await engine.apply(.upsert(segment("retries while preserving ordering", sequence: 3, start: 5.6, end: 6)), sessionEpoch: epoch, now: 6.4)
    let question = try #require(update.newQuestion)
    let context = try await engine.context(for: question)
    #expect(context.provenance.contains { $0.source == .localUser })
    #expect(context.provenance.contains { $0.source == .systemAudio })
    #expect(context.userContext.contains("crash-safe delivery"))
    #expect(context.estimatedTokens <= 16_000)
    var fence = GenerationFence(), view = AnswerPresentation()
    let identity = fence.begin(sessionEpoch: epoch, question: question)
    view.begin(identity: identity, question: question)
    let provider = ScriptedProvider(chunks: ["Persist the request ", "before sending it; ", "retry in sequence."])
    for await text in provider.stream(context: context) {
        #expect(fence.accepts(identity))
        #expect(view.append(text, identity: identity) == true)
    }
    view.finish(identity: identity, lifecycle: .completed)
    #expect(view.displayed?.text == "Persist the request before sending it; retry in sequence.")
    #expect(view.displayed?.lifecycle == .completed)
    await engine.stop(epoch: .init(2)); fence.invalidate(); view.invalidate()
    #expect(view.append("stale", identity: identity) == false)
}
