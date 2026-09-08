import Foundation
import Testing
@testable import FreelyCore

@Test func layeredQuestionHeuristics() {
    for text in ["What is StateFlow", "Would you preserve ordering", "Explain how retries work", "Please compare these approaches", "Show me an implementation"] {
        #expect(IntentHeuristics.classify(text, hasAntecedent: false) != nil)
    }
    for text in ["That is interesting?", "I wonder why that happened", "yes?", "StateFlow has replay", "We should compare these tomorrow"] {
        #expect(IntentHeuristics.classify(text, hasAntecedent: false) == nil)
    }
    #expect(IntentHeuristics.classify("Now assume the process dies", hasAntecedent: true) == .followUp)
    #expect(IntentHeuristics.classify("Why not?", hasAntecedent: true) == .followUp)
    #expect(IntentHeuristics.classify("Explain retries", hasAntecedent: false) == .imperative)
    #expect(IntentHeuristics.classify("StateFlow versus SharedFlow", hasAntecedent: false) == .imperative)
}

@Test func questionAcrossSegmentsAndFollowupReferents() async throws {
    let engine = ConversationEngine()
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    let first = segment("What is the difference", end: 1.5)
    _ = await engine.apply(.upsert(first), sessionEpoch: epoch, now: 1.5)
    let second = segment("between StateFlow and SharedFlow?", sequence: 2, start: 1.6, end: 2)
    let unready = await engine.apply(.upsert(second), sessionEpoch: epoch, now: 2.1)
    #expect(unready.newQuestion == nil)
    let tick = await engine.tick(now: 2.4, sessionEpoch: epoch)
    let question = try #require(tick.newQuestion)
    #expect(question.text.contains("StateFlow and SharedFlow"))
    #expect(await engine.tick(now: 2.5).newQuestion == nil)
    let update = await engine.apply(.upsert(segment("And what about replay for new subscribers?", sequence: 3, start: 5, end: 6)), sessionEpoch: epoch, now: 6.4)
    let followup = try #require(update.newQuestion)
    #expect(followup.relatedPriorQuestion == question.id)
    let context = try await engine.context(for: followup)
    #expect(context.userContext.contains("StateFlow and SharedFlow"))
    #expect(context.userContext.contains("replay for new subscribers"))
}

@Test func chainedFollowupsPreserveOriginalSubjectAndNewConstraint() async throws {
    let engine = ConversationEngine()
    await engine.begin(sessionID: .init(), epoch: .init(1))
    let texts = ["How would you implement retries?", "Now assume the process dies.", "Would your previous approach still preserve ordering?"]
    var question: QuestionState?
    for (index, text) in texts.enumerated() {
        let start = Double(index * 4 + 1)
        question = await engine.apply(.upsert(segment(text, sequence: UInt64(index + 1), start: start, end: start + 1)), sessionEpoch: .init(1), now: start + 1.4).newQuestion
    }
    let final = try #require(question)
    let context = try await engine.context(for: final)
    #expect(context.userContext.contains("implement retries"))
    #expect(context.userContext.contains("process dies"))
    #expect(context.userContext.contains("preserve ordering"))
}

@Test func lateNegationSupersedesButPunctuationDoesNot() async throws {
    let engine = ConversationEngine()
    await engine.begin(sessionID: .init(), epoch: .init(1))
    let id = SegmentID()
    let original = await engine.apply(.upsert(segment("Should we retry failed requests", id: id)), sessionEpoch: .init(1), now: 3)
    let a = try #require(original.newQuestion)
    let cosmetic = await engine.apply(.revise(segment("Should we retry failed requests?", id: id, revision: 2)), sessionEpoch: .init(1), now: 3)
    #expect(cosmetic.newQuestion == nil)
    let material = await engine.apply(.revise(segment("Should we not retry failed requests?", id: id, revision: 3)), sessionEpoch: .init(1), now: 3)
    let b = try #require(material.newQuestion)
    #expect(a.id == b.id)
    #expect(b.revision == a.revision + 1)
    #expect(material.invalidatedQuestionIDs.contains(a.id))
}

@Test func localOverlapDoesNotTriggerAutomaticGeneration() async throws {
    let engine = ConversationEngine()
    await engine.begin(sessionID: .init(), epoch: .init(1))
    _ = await engine.apply(.upsert(segment("How would retries work", start: 1, end: 3)), sessionEpoch: .init(1), now: 2)
    let local = await engine.apply(.upsert(segment("Can you hear me clearly", source: .localUser, start: 2, end: 4)), sessionEpoch: .init(1), now: 4.4)
    #expect(local.newQuestion?.source == .systemAudio)
    #expect(local.turns.count == 2)
    #expect(await engine.tick(now: 5).newQuestion == nil)
}

@Test func stopRestartRejectsOldCallbacksAndTicks() async {
    let engine = ConversationEngine()
    await engine.begin(sessionID: .init(), epoch: .init(1))
    await engine.stop(epoch: .init(2))
    await engine.begin(sessionID: .init(), epoch: .init(3))
    await engine.stop(epoch: .init(2))
    await engine.begin(sessionID: .init(), epoch: .init(1))
    let stale = await engine.apply(.upsert(segment("How would the old session work")), sessionEpoch: .init(1), now: 4)
    #expect(stale.result == .wrongEpoch)
    #expect(stale.segments.isEmpty)
    #expect(await engine.tick(now: 500, sessionEpoch: .init(1)).result == .wrongEpoch)
    #expect(await engine.tick(now: 500, sessionEpoch: .init(3)).result == .accepted)
}

@Test func correctionRebuildsFollowupAntecedentAndDoesNotReplayAnOlderUnrelatedQuestion() async throws {
    let engine = ConversationEngine()
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    let first = segment("Should we retry failed requests?")
    _ = await engine.apply(.upsert(first), sessionEpoch: epoch, now: 3)
    let followup = await engine.apply(.upsert(segment("Would that preserve ordering?", sequence: 2, start: 5, end: 6)), sessionEpoch: epoch, now: 7)
    let old = try #require(followup.newQuestion)
    let corrected = await engine.apply(.revise(segment("Should we not retry failed requests?", id: first.id, revision: 2)), sessionEpoch: epoch, now: 8)
    let new = try #require(corrected.newQuestion)
    #expect(new.id == old.id)
    #expect(new.revision > old.revision)
    #expect(new.antecedent?.contains("not retry") == true)
    #expect(corrected.invalidatedQuestionIDs.contains(old.id))
    _ = await engine.apply(.upsert(segment("What is the difference between StateFlow and SharedFlow?", sequence: 3, start: 10, end: 11)), sessionEpoch: epoch, now: 12)
    let unrelated = await engine.apply(.revise(segment("Should we retry only network errors?", id: first.id, revision: 3)), sessionEpoch: epoch, now: 13)
    #expect(unrelated.newQuestion == nil)
}

@Test func gapOverAQuestionInvalidatesAutomaticIntentAndRetainsManualContext() async throws {
    let engine = ConversationEngine()
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    let update = await engine.apply(.upsert(segment("Should we delete the failed request?", start: 1, end: 3)), sessionEpoch: epoch, now: 4)
    let question = try #require(update.newQuestion)
    let gap = AudioDiscontinuity(source: .systemAudio, startTime: 1.7, endTime: 2, cause: .overflow)
    let invalidated = await engine.apply(.gap(gap), sessionEpoch: epoch, now: 4)
    #expect(invalidated.invalidatedQuestionIDs.contains(question.id))
    #expect(invalidated.newQuestion == nil)
    let context = try await engine.context(for: .init(text: "Clarify the interrupted question"))
    #expect(context.userContext.contains("Audio gaps"))
}

@Test func retractingAntecedentPurgesItFromFollowupContext() async throws {
    let engine = ConversationEngine()
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    let first = segment("How would you implement retries?")
    _ = await engine.apply(.upsert(first), sessionEpoch: epoch, now: 3)
    let second = await engine.apply(.upsert(segment("Would that preserve ordering?", sequence: 2, start: 5, end: 6)), sessionEpoch: epoch, now: 7)
    let priorFollowup = try #require(second.newQuestion)
    let removed = await engine.apply(.retract(id: first.id, source: first.source, streamEpoch: first.streamEpoch, revision: 2), sessionEpoch: epoch, now: 8)
    #expect(removed.invalidatedQuestionIDs.contains(priorFollowup.id))
    #expect((removed.newQuestion?.revision ?? 0) > priorFollowup.revision)
    let context = try await engine.context(for: .init(text: "What conversation remains?"))
    #expect(!context.userContext.contains("implement retries"))
}

@Test func repeatedLongSessionCompactionStaysBoundedWithoutRetriggeringHistory() async throws {
    let engine = ConversationEngine(limits: .init(maximumAge: 40, maximumSegments: 12, maximumTextBytes: 2_048))
    await engine.begin(sessionID: .init(), epoch: .init(1))
    for index in 1...600 {
        let start = Double(index * 4)
        let update = await engine.apply(.upsert(segment("Explain retry strategy number \(index)", sequence: UInt64(index), start: start, end: start + 1)), sessionEpoch: .init(1), now: start + 1.4)
        #expect(update.segments.count <= 12)
        #expect(update.newQuestion?.text == "Explain retry strategy number \(index)")
        #expect(await engine.tick(now: start + 1.5).newQuestion == nil)
    }
    let update = await engine.currentUpdate()
    #expect(update.contextLimited)
    #expect(await engine.recentQuestions().count <= 20)
    let summary = try #require(await engine.rollingSummary())
    #expect(summary.isExtractiveFallback)
    #expect(summary.facts.utf8.count <= 1_700)
    #expect(!summary.uncertainties.isEmpty)
}

@Test func summaryCommitFencesRevisionRaceAndStop() async throws {
    let engine = ConversationEngine(limits: .init(maximumSegments: 8))
    await engine.begin(sessionID: .init(), epoch: .init(1))
    let first = segment("We decided to preserve ordering", start: 1, end: 2)
    _ = await engine.apply(.upsert(first), sessionEpoch: .init(1), now: 3)
    for index in 2...6 {
        _ = await engine.apply(.upsert(segment("A stable statement \(index)", sequence: UInt64(index), start: Double(index * 4), end: Double(index * 4 + 1))), sessionEpoch: .init(1), now: Double(index * 4 + 2))
    }
    let request = try #require(await engine.prepareSummary(now: 310))
    #expect(await engine.prepareSummary(now: 311) == nil)
    _ = await engine.apply(.revise(segment("We decided not to preserve ordering", id: first.id, revision: 2)), sessionEpoch: .init(1), now: 312)
    #expect(await engine.commitSummary(request: request, facts: "Ordering is preserved", now: 313) == false)
    let second = try #require(await engine.prepareSummary(now: 314))
    #expect(await engine.commitSummary(request: second, facts: "Ordering may be lost", uncertainties: ["Needs confirmation"], now: 315))
    _ = await engine.apply(.revise(segment("We have not decided about ordering", id: first.id, revision: 3)), sessionEpoch: .init(1), now: 316)
    #expect(await engine.rollingSummary()?.facts == "")
    let third = try #require(await engine.prepareSummary(now: 620))
    await engine.stop(epoch: .init(2))
    #expect(await engine.commitSummary(request: third, facts: "Late summary", now: 621) == false)
}

@Test func sourceChangeFencesPendingSummaryWithoutErasingHistoricalProvenance() async throws {
    let engine = ConversationEngine(limits: .init(maximumSegments: 8))
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    for index in 1...6 {
        _ = await engine.apply(.upsert(segment("The original source statement \(index)", sequence: UInt64(index), start: Double(index * 4), end: Double(index * 4 + 1))), sessionEpoch: epoch, now: Double(index * 4 + 2))
    }
    let pending = try #require(await engine.prepareSummary(now: 310))
    await engine.setSourceEpoch(.init(2), source: .systemAudio, sessionEpoch: epoch)
    #expect(await engine.commitSummary(request: pending, facts: "Late source summary", now: 311) == false)
    let update = await engine.tick(now: 312, sessionEpoch: epoch)
    #expect(update.segments.count == 6)
    #expect(update.segments.allSatisfy { $0.source == .systemAudio && $0.streamEpoch == .init() })
}

@Test func lateAudioGapInvalidatesInFlightAndCommittedSummaries() async throws {
    let engine = ConversationEngine(limits: .init(maximumSegments: 8))
    let epoch = SessionEpoch(1)
    await engine.begin(sessionID: .init(), epoch: epoch)
    for index in 1...6 {
        _ = await engine.apply(.upsert(segment("Stable source statement \(index)", sequence: UInt64(index), start: Double(index * 4), end: Double(index * 4 + 1))), sessionEpoch: epoch, now: Double(index * 4 + 2))
    }
    let first = try #require(await engine.prepareSummary(now: 310))
    _ = await engine.apply(.gap(.init(source: .systemAudio, startTime: 4.2, endTime: 4.4, cause: .overflow)), sessionEpoch: epoch, now: 311)
    #expect(await engine.commitSummary(request: first, facts: "Unsafe summary", now: 312) == false)
    let second = try #require(await engine.prepareSummary(now: 313))
    #expect(!second.references.contains { $0.sequence == 1 })
    #expect(await engine.commitSummary(request: second, facts: "Remaining facts", now: 314))
    _ = await engine.apply(.gap(.init(source: .systemAudio, startTime: 8.2, endTime: 8.4, cause: .overflow)), sessionEpoch: epoch, now: 315)
    #expect(await engine.rollingSummary()?.facts == "")
}
