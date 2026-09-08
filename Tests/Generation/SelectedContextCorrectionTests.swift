import FreelyCore
import Foundation
import Testing
@testable import Freely

@MainActor struct SelectedContextCorrectionTests {
    @Test func finalLocalCorrectionInvalidatesAnActiveUnchangedRemoteQuestion() async throws {
        let provider = CoordinatorProvider(), microphone = CoordinatorCapture(), system = CoordinatorCapture()
        let models = CoordinatorModels(), answers = CoordinatorAnswerRecorder(), state = CoordinatorSessionRecorder()
        let session = SessionCoordinator(credentials: CoordinatorCredential(), rateBudget: SharedRequestBudget(),
            microphone: microphone, system: system, makeTranscriber: { try await models.make($0) },
            makeProvider: { _, _ in provider }, onState: state.record, onAnswer: answers.record)
        session.start(preferences: coordinatorPreferences(microphone: true, system: true), sessionNotes: "", pinnedFacts: "", transcriptionOnly: false)
        try await coordinatorEventually { session.phase == .running }
        let epoch = session.activeEpoch
        let localEpoch = session.currentSourceEpoch(.localUser), remoteEpoch = session.currentSourceEpoch(.systemAudio)
        let fact = TranscriptSegment(source: .localUser, streamEpoch: localEpoch, sequence: 1,
            startTime: 0, endTime: 0.05, text: "Our production database is PostgreSQL.", finality: .final, revision: 1)
        let question = TranscriptSegment(source: .systemAudio, streamEpoch: remoteEpoch, sequence: 1,
            startTime: 0.1, endTime: 0.2, text: "How would you choose a database for our application?", finality: .final, revision: 1)
        await session.receive(.finalize(fact), source: .localUser, epoch: epoch, sourceEpoch: localEpoch)
        await session.receive(.finalize(question), source: .systemAudio, epoch: epoch, sourceEpoch: remoteEpoch)
        try await coordinatorEventually { await provider.requests.count == 1 }
        #expect(await provider.requests[0].selectedContext.contains("Our production database is PostgreSQL."))
        await provider.emit(.textDelta("Using PostgreSQL, "), request: 0)
        try await coordinatorEventually { answers.answer.displayed?.text == "Using PostgreSQL, " }
        let unchangedQuestion = try #require(state.latest.lastQuestion)
        let corrected = TranscriptSegment(id: fact.id, source: .localUser, streamEpoch: localEpoch, sequence: fact.sequence,
            startTime: fact.startTime, endTime: fact.endTime, text: "Our production database is NOT PostgreSQL; it is SQLite.", finality: .final, revision: 2)
        await session.receive(.revise(corrected), source: .localUser, epoch: epoch, sourceEpoch: localEpoch)
        #expect(state.latest.lastQuestion == unchangedQuestion)
        #expect(answers.answer.displayed?.lifecycle == .cancelled)
        await provider.emit(.textDelta("POSTGRES-ONLY-LATE"), request: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!answers.texts.contains { $0.contains("POSTGRES-ONLY-LATE") })
        await session.stop()
    }

    @Test func ordinaryPartialsUnselectedCorrectionsAndStaleRevisionsDoNotInvalidateSelectedContext() async throws {
        let conversation = ConversationEngine()
        let epoch = SessionEpoch(1)
        await conversation.begin(sessionID: .init(), epoch: epoch)
        let selected = TranscriptSegment(source: .localUser, sequence: 1, startTime: 0, endTime: 1,
            text: "The selected database fact is SQLite.", finality: .final)
        let omitted = TranscriptSegment(source: .localUser, sequence: 2, startTime: 100, endTime: 101,
            text: "OMITTED-LONG-TURN " + String(repeating: "background ", count: 800), finality: .final)
        _ = await conversation.apply(.finalize(selected), sessionEpoch: epoch, now: 2)
        _ = await conversation.apply(.finalize(omitted), sessionEpoch: epoch, now: 102)
        let context = try await conversation.contextForGeneration(for: .init(text: "Explain the selected database fact"))
        #expect(context.snapshot.userContext.contains("The selected database fact is SQLite."))
        #expect(!context.snapshot.userContext.contains("OMITTED-LONG-TURN"))
        let draftID = SegmentID()
        let events: [TranscriptEvent] = [
            .upsert(.init(id: draftID, source: .localUser, sequence: 3, startTime: 200, endTime: 201, text: "A new draft", finality: .partial, revision: 1)),
            .upsert(.init(id: draftID, source: .localUser, sequence: 3, startTime: 200, endTime: 201, text: "A revised ordinary draft", finality: .partial, revision: 2)),
            .revise(.init(id: omitted.id, source: .localUser, sequence: omitted.sequence, startTime: omitted.startTime, endTime: omitted.endTime,
                text: "Corrected " + omitted.text, finality: .final, revision: 2)),
            .finalize(selected),
            .revise(.init(id: selected.id, source: .localUser, sequence: selected.sequence, startTime: selected.startTime, endTime: selected.endTime,
                text: selected.text.uppercased() + "?", finality: .final, revision: 2)),
            .revise(.init(id: selected.id, source: .localUser, sequence: selected.sequence, startTime: selected.startTime, endTime: selected.endTime,
                text: "Stale revision must not replace the selected fact", finality: .final, revision: 1))
        ]
        for event in events {
            let update = await conversation.apply(event, sessionEpoch: epoch, now: 202)
            #expect(update.invalidatedContextID == nil)
            #expect(await conversation.generationContextIsCurrent(context.contextID))
        }
    }

    @Test func correctionOfSelectedEvictedSummarySourceInvalidatesAtomicallyButEvictionAloneDoesNot() async throws {
        let conversation = ConversationEngine(limits: .init(maximumSegments: 1))
        let epoch = SessionEpoch(1)
        await conversation.begin(sessionID: .init(), epoch: epoch)
        let fact = TranscriptSegment(source: .localUser, sequence: 1, startTime: 0, endTime: 1,
            text: "The historical local limit is ten requests.", finality: .final)
        _ = await conversation.apply(.finalize(fact), sessionEpoch: epoch, now: 2)
        let original = try await conversation.contextForGeneration(for: .init(text: "Explain the local limit"))
        _ = await conversation.apply(.finalize(.init(source: .systemAudio, sequence: 1, startTime: 10, endTime: 11,
            text: "Explain the limit tradeoff", finality: .final)), sessionEpoch: epoch, now: 12)
        #expect(await conversation.generationContextIsCurrent(original.contextID))
        let summarized = try await conversation.contextForGeneration(for: .init(text: "Explain the historical local limit"))
        #expect(summarized.snapshot.userContext.contains(fact.text))
        let correction = TranscriptSegment(id: fact.id, source: fact.source, sequence: fact.sequence, startTime: fact.startTime,
            endTime: fact.endTime, text: "The historical local limit is NOT ten; it is two requests.", finality: .final, revision: 2)
        let update = await conversation.apply(.revise(correction), sessionEpoch: epoch, now: 13)
        #expect(update.result == .retiredSegment)
        #expect(update.invalidatedContextID == summarized.contextID)
        #expect(await conversation.generationContextIsCurrent(summarized.contextID) == false)
    }
}
