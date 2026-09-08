import Foundation
import Testing
@testable import FreelyCore

func segment(_ text: String, id: SegmentID = .init(), source: AudioSource = .systemAudio,
             sequence: UInt64 = 1, start: Double = 1, end: Double = 2, revision: UInt64 = 1,
             finality: TranscriptFinality = .final, epoch: SourceEpoch = .init()) -> TranscriptSegment {
    .init(id: id, source: source, streamEpoch: epoch, sequence: sequence, startTime: start, endTime: end,
          text: text, finality: finality, revision: revision)
}

@Test func partialReplacementAndFinalCorrections() {
    let id = SegmentID()
    var store = TranscriptStore()
    #expect(store.apply(.insert(segment("How would", id: id, finality: .partial))) == .accepted)
    #expect(store.apply(.update(segment("How would retries work", id: id, revision: 2, finality: .partial))) == .accepted)
    #expect(store.segments.count == 1)
    #expect(store.segments.first?.text == "How would retries work")
    #expect(store.apply(.finalize(segment("How would retries work?", id: id, revision: 3))) == .accepted)
    #expect(store.apply(.update(segment("How", id: id, revision: 2, finality: .partial))) == .staleRevision)
    #expect(store.apply(.update(segment("How", id: id, revision: 4, finality: .partial))) == .staleRevision)
    let correction = segment("How would retries not work?", id: id, revision: 4)
    #expect(store.apply(.revise(correction)) == .accepted)
    #expect(store.apply(.upsert(correction)) == .duplicate)
    #expect(store.segments.first?.confidence == nil)
    #expect(store.segments.first?.revision == 4)
}

@Test func retractionTombstonePreventsOldCallbackResurrection() {
    var store = TranscriptStore()
    let original = segment("Explain StateFlow")
    store.apply(.upsert(original))
    #expect(store.apply(.retract(id: original.id, source: original.source, streamEpoch: .init(), revision: 2)) == .accepted)
    #expect(store.segments.isEmpty)
    #expect(store.apply(.upsert(original)) == .staleRevision)
    #expect(store.apply(.retract(id: original.id, source: original.source, streamEpoch: .init(), revision: 1)) == .staleRevision)
}

@Test func timestampOrderingDoesNotDependOnArrival() {
    let a = segment("local", source: .localUser, sequence: 8, start: 2, end: 3)
    let b = segment("earlier", sequence: 12, start: 1, end: 2)
    let c = segment("remote", sequence: 5, start: 2, end: 3)
    var first = TranscriptStore(), second = TranscriptStore()
    for value in [a, b, c] { first.apply(.upsert(value)) }
    for value in [c, b, a] { second.apply(.upsert(value)) }
    #expect(first.segments == second.segments)
    #expect(first.segments.map(\.text) == ["earlier", "local", "remote"])
}

@Test func gapsAndSourceEpochsRemainExplicit() {
    var store = TranscriptStore()
    let old = segment("existing conversation")
    store.apply(.upsert(old))
    store.setSourceEpoch(.init(2), source: .systemAudio)
    store.setSourceEpoch(.init(1), source: .systemAudio)
    #expect(store.apply(.upsert(segment("late callback", sequence: 2))) == .wrongEpoch)
    #expect(store.apply(.upsert(segment("new decoder", sequence: 1, start: 3, end: 4, epoch: .init(2)))) == .accepted)
    #expect(store.segments.count == 2)
    let gap = AudioDiscontinuity(source: .systemAudio, streamEpoch: .init(2), startTime: 2, endTime: 3, cause: .deviceChanged)
    #expect(store.apply(.gap(gap)) == .accepted)
    #expect(store.apply(.gap(gap)) == .duplicate)
    #expect(store.gaps.first?.droppedDuration == 1)
    #expect(store.apply(.upsert(segment("local remains active", source: .localUser, start: 3, end: 4))) == .accepted)
}

@Test func allTranscriptRetentionBoundaries() {
    var count = TranscriptStore(limits: .init(maximumSegments: 2))
    for i in 1...3 { count.apply(.upsert(segment("value \(i)", sequence: UInt64(i), start: Double(i), end: Double(i) + 0.5))) }
    #expect(count.enforceLimits().count == 1)
    #expect(count.segments.count == 2)
    #expect(count.contextLimited)
    #expect(count.apply(.upsert(segment("old callback", sequence: 1))) == .retiredSegment)
    var age = TranscriptStore(limits: .init(maximumAge: 3))
    age.apply(.upsert(segment("old", sequence: 1)))
    age.apply(.upsert(segment("new", sequence: 2, start: 10, end: 11)))
    #expect(age.enforceLimits().count == 1)
    var bytes = TranscriptStore(limits: .init(maximumTextBytes: 128))
    bytes.apply(.upsert(segment(String(repeating: "a", count: 100))))
    bytes.apply(.upsert(segment(String(repeating: "b", count: 100), sequence: 2, start: 3, end: 4)))
    #expect(bytes.enforceLimits().count == 1)
    #expect(bytes.textBytes == 100)
    #expect(bytes.apply(.upsert(segment(String(repeating: "x", count: 129), sequence: 3))) == .invalidSegment)
}

@Test func invalidTimeAndIdentityAreRejected() {
    var store = TranscriptStore()
    #expect(store.apply(.upsert(segment("negative", start: -1))) == .invalidSegment)
    #expect(store.apply(.upsert(segment("nan", start: .nan))) == .invalidSegment)
    #expect(store.apply(.upsert(segment("backward", start: 3, end: 2))) == .invalidSegment)
    let a = segment("first")
    store.apply(.upsert(a))
    #expect(store.apply(.upsert(segment("wrong source", id: a.id, source: .localUser, revision: 2))) == .invalidSegment)
}

@Test func evictionOfOldDecoderEpochDoesNotRetireNewDecoderSequences() {
    var store = TranscriptStore(limits: .init(maximumSegments: 2))
    store.apply(.upsert(segment("old decoder", sequence: 100)))
    store.setSourceEpoch(.init(2), source: .systemAudio)
    store.apply(.upsert(segment("new first", sequence: 1, start: 3, end: 4, epoch: .init(2))))
    store.apply(.upsert(segment("new second", sequence: 2, start: 5, end: 6, epoch: .init(2))))
    #expect(store.enforceLimits().count == 1)
    #expect(store.apply(.upsert(segment("new third", sequence: 3, start: 7, end: 8, epoch: .init(2)))) == .accepted)
}

@Test func boundedTombstonesStillRejectRetiredRetractions() {
    var store = TranscriptStore(limits: .init(maximumSegments: 2))
    var first: TranscriptSegment?
    for index in 1...10 {
        let value = segment("temporary hypothesis", sequence: UInt64(index), start: Double(index), end: Double(index) + 0.5)
        if first == nil { first = value }
        store.apply(.upsert(value))
        store.apply(.retract(id: value.id, source: value.source, streamEpoch: value.streamEpoch, revision: 2))
    }
    #expect(store.contextLimited)
    if let first { #expect(store.apply(.upsert(first)) == .retiredSegment) }
    #expect(store.segments.isEmpty)
    let unknown = SegmentID()
    #expect(store.apply(.retract(id: unknown, source: .systemAudio, streamEpoch: .init(), revision: 3)) == .invalidSegment)
    #expect(store.apply(.retract(id: unknown, source: .systemAudio, streamEpoch: .init(), revision: 3, sequence: 20)) == .accepted)
    #expect(store.apply(.upsert(segment("late first insert", id: unknown, sequence: 20, start: 20, end: 21))) == .staleRevision)
}

@Test func coalescedGapRetainsMeasuredLossSeparateFromCoveringSpan() {
    var store = TranscriptStore()
    let value = AudioDiscontinuity(source: .systemAudio, startTime: 10, endTime: 20, cause: .overflow, lostDuration: 0.8)
    #expect(value.droppedDuration == 0.8)
    #expect(store.apply(.gap(value)) == .accepted)
    #expect(store.apply(.gap(.init(source: .systemAudio, startTime: 10, endTime: 20, cause: .overflow, lostDuration: 11))) == .invalidSegment)
    #expect(store.apply(.gap(.init(source: .systemAudio, startTime: 10, endTime: 20, cause: .overflow, lostDuration: .nan))) == .invalidSegment)
}

@Test func turnsSpanSegmentsAndWaitForBoundary() {
    let values = [segment("What is the difference", end: 1.5),
                  segment("between StateFlow and SharedFlow", sequence: 2, start: 1.6, end: 2)]
    let early = TurnBuilder.build(segments: values, now: 2.1)
    #expect(early.count == 1)
    #expect(!early[0].isStable)
    let stable = TurnBuilder.build(segments: values, now: 2.31)
    #expect(stable[0].isStable)
    #expect(stable[0].text == "What is the difference between StateFlow and SharedFlow")
    #expect(stable[0].segmentIDs.count == 2)
}

@Test func turnIdentityAndRevisionSurviveLatePrependAndRetraction() {
    let first = segment("between StateFlow and SharedFlow", sequence: 2, start: 2, end: 3)
    let initial = TurnBuilder.build(segments: [first], now: 4)
    let earlier = segment("Explain the difference", sequence: 1, start: 1, end: 1.5)
    let prepended = TurnBuilder.build(segments: [earlier, first], now: 4, previous: initial)
    #expect(prepended.count == 1)
    #expect(prepended[0].id == initial[0].id)
    #expect(prepended[0].revision == initial[0].revision + 1)
    let retracted = TurnBuilder.build(segments: [first], now: 4, previous: prepended)
    #expect(retracted[0].id == initial[0].id)
    #expect(retracted[0].revision == prepended[0].revision + 1)
    let unchanged = TurnBuilder.build(segments: [first], now: 5, previous: retracted)
    #expect(unchanged[0].revision == retracted[0].revision)
    let local = segment("An interruption", source: .localUser, start: 1.7, end: 1.9)
    let split = TurnBuilder.build(segments: [earlier, local, first], now: 5, previous: prepended)
    #expect(Set(split.map(\.id)).count == 3)
}

@Test func overlapAndEchoDoNotEraseLocalSpeech() {
    let remote = segment("Explain how StateFlow handles concurrent updates", start: 1, end: 3)
    let local = segment("Explain how StateFlow handles concurrent updates", source: .localUser, start: 1.2, end: 3.1)
    let turns = TurnBuilder.build(segments: [remote, local], now: 4)
    #expect(turns.count == 2)
    #expect(turns.last?.possibleCrossSourceDuplicate == true)
    let intentional = segment("Explain how StateFlow handles concurrent updates", source: .localUser, start: 6, end: 8)
    #expect(TurnBuilder.build(segments: [remote, intentional], now: 9).last?.possibleCrossSourceDuplicate == false)
    let acknowledgment = segment("yes okay", source: .localUser, start: 1.2, end: 1.5)
    #expect(TurnBuilder.build(segments: [remote, acknowledgment], now: 4).last?.possibleCrossSourceDuplicate == false)
}
