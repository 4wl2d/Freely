import Foundation

public struct TranscriptLimits: Sendable {
    public let maximumAge: TimeInterval
    public let maximumSegments: Int
    public let maximumTextBytes: Int
    public let maximumGaps: Int
    public init(maximumAge: TimeInterval = 600, maximumSegments: Int = 2_000,
                maximumTextBytes: Int = 2 * 1_024 * 1_024, maximumGaps: Int = 128) {
        self.maximumAge = max(1, maximumAge); self.maximumSegments = max(1, maximumSegments)
        self.maximumTextBytes = max(128, maximumTextBytes); self.maximumGaps = max(1, maximumGaps)
    }
}
public enum ReconciliationResult: Equatable, Sendable {
    case accepted, duplicate, staleRevision, wrongEpoch, invalidSegment, retiredSegment
}
public struct SegmentReference: Hashable, Sendable {
    public let id: SegmentID
    public let source: AudioSource
    public let streamEpoch: SourceEpoch
    public let sequence: UInt64
    public let revision: UInt64
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public init(_ segment: TranscriptSegment) {
        id = segment.id; source = segment.source; streamEpoch = segment.streamEpoch
        sequence = segment.sequence; revision = segment.revision
        startTime = segment.startTime; endTime = segment.endTime
    }
}

/// A value store owned by ConversationEngine. No callback-arrival order is exposed as transcript order.
public struct TranscriptStore: Sendable {
    public let limits: TranscriptLimits
    public private(set) var revision: UInt64 = 0
    public private(set) var contextLimited = false
    public private(set) var gaps: [AudioDiscontinuity] = []
    private var entries: [SegmentID: TranscriptSegment] = [:]
    private struct Tombstone: Sendable {
        let revision: UInt64
        let source: AudioSource
        let epoch: SourceEpoch
        let sequence: UInt64?
    }
    private var tombstones: [SegmentID: Tombstone] = [:]
    private var tombstoneOrder: [SegmentID] = []
    private var retiredSequence: [AudioSource: UInt64] = [:]
    private var sourceEpochs: [AudioSource: SourceEpoch] = [:]
    private var newestTime: TimeInterval = 0
    public init(limits: TranscriptLimits = .init()) { self.limits = limits }
    public var segments: [TranscriptSegment] { entries.values.sorted(by: Self.ordered) }
    public var textBytes: Int { entries.values.reduce(0) { $0 + $1.text.utf8.count } }
    public func segment(_ id: SegmentID) -> TranscriptSegment? { entries[id] }
    public func matches(_ references: [SegmentReference]) -> Bool {
        references.allSatisfy { ref in
            guard let value = entries[ref.id] else { return false }
            return value.revision == ref.revision && value.source == ref.source && value.streamEpoch == ref.streamEpoch && value.sequence == ref.sequence
        }
    }
    public mutating func setSourceEpoch(_ epoch: SourceEpoch, source: AudioSource) {
        guard epoch.rawValue > sourceEpochs[source, default: .init()].rawValue else { return }
        sourceEpochs[source] = epoch
        retiredSequence[source] = nil
        revision &+= 1
    }
    @discardableResult public mutating func apply(_ event: TranscriptEvent) -> ReconciliationResult {
        switch event {
        case .upsert(let segment), .insert(let segment), .update(let segment), .finalize(let segment), .revise(let segment):
            guard sourceEpochs[segment.source, default: .init()] == segment.streamEpoch else { return .wrongEpoch }
            guard segment.startTime.isFinite, segment.endTime.isFinite, segment.startTime >= 0,
                  segment.endTime >= segment.startTime, segment.text.utf8.count <= limits.maximumTextBytes,
                  segment.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { return .invalidSegment }
            if let old = entries[segment.id] {
                guard old.source == segment.source, old.streamEpoch == segment.streamEpoch,
                      old.sequence == segment.sequence else { return .invalidSegment }
                if old == segment { return .duplicate }
                guard segment.revision > old.revision else { return .staleRevision }
                guard old.finality != .final || segment.finality == .final else { return .staleRevision }
            } else {
                if let tombstone = tombstones[segment.id] {
                    guard tombstone.source == segment.source, tombstone.epoch == segment.streamEpoch else { return .invalidSegment }
                    if segment.revision <= tombstone.revision { return .staleRevision }
                }
                if let floor = retiredSequence[segment.source], segment.sequence <= floor { return .retiredSegment }
                if segment.endTime < newestTime - limits.maximumAge { return .retiredSegment }
            }
            entries[segment.id] = segment
            newestTime = max(newestTime, segment.endTime)
        case .retract(let id, let source, let epoch, let value, let suppliedSequence):
            guard sourceEpochs[source, default: .init()] == epoch else { return .wrongEpoch }
            if let old = entries[id] {
                guard old.source == source, old.streamEpoch == epoch else { return .invalidSegment }
                guard value > old.revision else { return .staleRevision }
                if let suppliedSequence, suppliedSequence != old.sequence { return .invalidSegment }
            } else if let old = tombstones[id] {
                guard old.source == source, old.epoch == epoch else { return .invalidSegment }
                if value <= old.revision { return .staleRevision }
            }
            let sequence = entries[id]?.sequence ?? suppliedSequence ?? tombstones[id]?.sequence
            // A retraction before its insert needs its source sequence to retain a bounded watermark.
            guard sequence != nil else { return .invalidSegment }
            entries[id] = nil
            if tombstones[id] == nil { tombstoneOrder.append(id) }
            tombstones[id] = .init(revision: value, source: source, epoch: epoch, sequence: sequence)
            while tombstoneOrder.count > limits.maximumSegments {
                let retiredID = tombstoneOrder.removeFirst()
                if let retired = tombstones.removeValue(forKey: retiredID),
                   sourceEpochs[retired.source, default: .init()] == retired.epoch, let sequence = retired.sequence {
                    retiredSequence[retired.source] = max(retiredSequence[retired.source] ?? 0, sequence)
                }
                contextLimited = true
            }
        case .gap(let gap):
            guard sourceEpochs[gap.source, default: .init()] == gap.streamEpoch else { return .wrongEpoch }
            guard gap.startTime.isFinite, gap.endTime.isFinite, gap.startTime >= 0,
                  gap.endTime >= gap.startTime,
                  gap.lostDuration.map({ $0.isFinite && $0 >= 0 && $0 <= gap.endTime - gap.startTime + 0.001 }) ?? true else { return .invalidSegment }
            if gaps.last == gap { return .duplicate }
            gaps.append(gap)
            if gaps.count > limits.maximumGaps { gaps.removeFirst(gaps.count - limits.maximumGaps) }
        }
        revision &+= 1
        return .accepted
    }
    /// Caller can preserve an extractive fallback from these values before they leave memory.
    @discardableResult public mutating func enforceLimits() -> [TranscriptSegment] {
        var ordered = segments
        var bytes = textBytes
        var evicted: [TranscriptSegment] = []
        while let first = ordered.first,
              ordered.count > limits.maximumSegments || bytes > limits.maximumTextBytes || first.endTime < newestTime - limits.maximumAge {
            ordered.removeFirst(); entries[first.id] = nil; bytes -= first.text.utf8.count
            if sourceEpochs[first.source, default: .init()] == first.streamEpoch {
                retiredSequence[first.source] = max(retiredSequence[first.source] ?? 0, first.sequence)
            }
            evicted.append(first)
        }
        if !evicted.isEmpty { contextLimited = true; revision &+= 1 }
        return evicted
    }
    private static func ordered(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}

public enum TurnBuilder {
    public static func build(segments: [TranscriptSegment], now: TimeInterval,
                             gapThreshold: TimeInterval = 0.9, stabilityDelay: TimeInterval = 0.3,
                             gaps: [AudioDiscontinuity] = [], previous: [ConversationTurn] = []) -> [ConversationTurn] {
        var groups: [[TranscriptSegment]] = []
        for segment in segments {
            if let last = groups.last?.last, last.source == segment.source,
               last.streamEpoch == segment.streamEpoch, segment.startTime - last.endTime <= gapThreshold,
               !gaps.contains(where: { $0.source == segment.source && $0.streamEpoch == segment.streamEpoch &&
                   $0.startTime < segment.startTime && $0.endTime > last.endTime }) {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        var previousBySegment: [SegmentID: ConversationTurn] = [:]
        for turn in previous { for id in turn.segmentIDs { previousBySegment[id] = turn } }
        var reusedIDs: Set<TurnID> = []
        return groups.enumerated().map { index, group in
            let first = group[0], last = group[group.count - 1]
            let prior = group.lazy.compactMap { previousBySegment[$0.id] }.first { !reusedIDs.contains($0.id) }
            let candidateID = prior?.id ?? .init(first.id.rawValue)
            let turnID = reusedIDs.contains(candidateID) ? TurnID() : candidateID
            reusedIDs.insert(turnID)
            let fingerprint = revisionFingerprint(group.map(SegmentReference.init))
            let revision = prior.map { $0.sourceRevisionFingerprint == fingerprint ? $0.revision : $0.revision + 1 } ?? 1
            let text = group.map(\.text).joined(separator: " ")
            let final = group.allSatisfy { $0.finality == .final }
            let hasGap = gaps.contains { gap in
                gap.source == first.source && gap.streamEpoch == first.streamEpoch &&
                gap.startTime < last.endTime && gap.endTime > first.startTime
            }
            let boundary = index < groups.count - 1 || now - last.endTime >= stabilityDelay
            // This is an uncertainty annotation only. Never delete or suppress local speech.
            let longEnoughForComparison = text.count >= 24
            let localMaterial = first.source == .localUser && longEnoughForComparison ? IntentHeuristics.materialText(text) : nil
            let possibleDuplicate = localMaterial != nil && segments.contains { other in
                guard other.source == .systemAudio,
                      first.startTime >= other.startTime - 0.15,
                      first.startTime <= other.endTime + 1.5 else { return false }
                return localMaterial == IntentHeuristics.materialText(other.text)
            }
            return ConversationTurn(id: turnID, source: first.source,
                segmentIDs: group.map(\.id), revision: revision, sourceRevisionFingerprint: fingerprint,
                startTime: first.startTime, endTime: last.endTime, text: text, isFinal: final,
                isStable: final && boundary, possibleCrossSourceDuplicate: possibleDuplicate, hasAudioGap: hasGap)
        }
    }
}

/// Deterministic noncryptographic revision fingerprint; never used as a security/content hash.
public func revisionFingerprint(_ references: [SegmentReference]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for ref in references.sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) {
        for byte in "\(ref.id.rawValue.uuidString):\(ref.source.rawValue):\(ref.streamEpoch.rawValue):\(ref.sequence):\(ref.revision);".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
    return hash
}
