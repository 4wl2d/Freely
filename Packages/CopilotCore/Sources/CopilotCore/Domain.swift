import Foundation

public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct SessionEpoch: Hashable, Codable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64 = 0) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public func advanced() -> Self { Self(rawValue &+ 1) }
}
public struct SourceEpoch: Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64 = 0) { self.rawValue = rawValue }
}
public struct SegmentID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct TurnID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct QuestionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct GenerationID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct VisualSnapshotID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct SelectionEpoch: Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64 = 0) { self.rawValue = rawValue }
}
public enum AudioSource: String, CaseIterable, Codable, Sendable {
    case localUser, systemAudio
    public var label: String { self == .localUser ? "Local microphone" : "Meeting audio" }
}
public struct AudioFormat: Equatable, Codable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public init(sampleRate: Double = 16_000, channels: Int = 1) {
        self.sampleRate = sampleRate; self.channels = channels
    }
}
/// Float samples are owned values. Adapters must copy borrowed native sample memory before construction.
public struct AudioFrame: Sendable {
    public let source: AudioSource
    public let epoch: SessionEpoch
    public let streamEpoch: SourceEpoch
    public let sequence: UInt64
    public let format: AudioFormat
    public let timestamp: TimeInterval
    public let samples: [Float]
    public var sampleCount: Int { samples.count }
    public var duration: TimeInterval {
        guard format.sampleRate > 0, format.channels > 0 else { return 0 }
        return Double(samples.count) / format.sampleRate / Double(format.channels)
    }
    public init(source: AudioSource, epoch: SessionEpoch, streamEpoch: SourceEpoch = .init(),
                sequence: UInt64, format: AudioFormat = .init(), timestamp: TimeInterval, samples: [Float]) {
        self.source = source; self.epoch = epoch; self.streamEpoch = streamEpoch
        self.sequence = sequence; self.format = format; self.timestamp = timestamp; self.samples = samples
    }
}
public struct AudioDiscontinuity: Equatable, Codable, Sendable {
    public enum Cause: String, Codable, Sendable { case overflow, deviceChanged, sourceUnavailable, paused, decodingFailure }
    public let source: AudioSource
    public let streamEpoch: SourceEpoch
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let cause: Cause
    /// Measured dropped sample duration, which can be smaller than a coalesced interval's span.
    public let lostDuration: TimeInterval?
    public var droppedDuration: TimeInterval { max(0, lostDuration ?? (endTime - startTime)) }
    public init(source: AudioSource, streamEpoch: SourceEpoch = .init(), startTime: TimeInterval,
                endTime: TimeInterval, cause: Cause, lostDuration: TimeInterval? = nil) {
        self.source = source; self.streamEpoch = streamEpoch; self.startTime = startTime
        self.endTime = endTime; self.cause = cause; self.lostDuration = lostDuration
    }
}
public enum TranscriptFinality: String, Codable, Sendable { case partial, final }
public struct TranscriptSegment: Identifiable, Equatable, Codable, Sendable {
    public let id: SegmentID
    public let source: AudioSource
    public let streamEpoch: SourceEpoch
    public let sequence: UInt64
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let confidence: Double?
    public let finality: TranscriptFinality
    public let revision: UInt64
    public init(id: SegmentID = .init(), source: AudioSource, streamEpoch: SourceEpoch = .init(),
                sequence: UInt64, startTime: TimeInterval, endTime: TimeInterval, text: String,
                confidence: Double? = nil, finality: TranscriptFinality = .final, revision: UInt64 = 1) {
        self.id = id; self.source = source; self.streamEpoch = streamEpoch; self.sequence = sequence
        self.startTime = startTime; self.endTime = endTime; self.text = text; self.confidence = confidence
        self.finality = finality; self.revision = revision
    }
}
public enum TranscriptEvent: Sendable {
    case upsert(TranscriptSegment)
    case insert(TranscriptSegment)
    case update(TranscriptSegment)
    case finalize(TranscriptSegment)
    case revise(TranscriptSegment)
    case retract(id: SegmentID, source: AudioSource, streamEpoch: SourceEpoch, revision: UInt64, sequence: UInt64? = nil)
    case gap(AudioDiscontinuity)
}
public struct ConversationTurn: Identifiable, Equatable, Sendable {
    public let id: TurnID
    public let source: AudioSource
    public let segmentIDs: [SegmentID]
    public let revision: UInt64
    public let sourceRevisionFingerprint: UInt64
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let isFinal: Bool
    public let isStable: Bool
    public let possibleCrossSourceDuplicate: Bool
    public let hasAudioGap: Bool
}
public enum QuestionTrigger: String, Codable, Sendable { case interrogative, imperative, followUp, manual, speculative }
public struct QuestionState: Identifiable, Equatable, Sendable {
    public let id: QuestionID
    public let revision: UInt64
    public let supportingTurnIDs: [TurnID]
    public let text: String
    public let triggerReason: QuestionTrigger
    public let relatedPriorQuestion: QuestionID?
    public let antecedent: String?
    public let source: AudioSource?
    public init(id: QuestionID = .init(), revision: UInt64 = 1, supportingTurnIDs: [TurnID] = [],
                text: String, triggerReason: QuestionTrigger = .manual, relatedPriorQuestion: QuestionID? = nil,
                antecedent: String? = nil, source: AudioSource? = nil) {
        self.id = id; self.revision = revision; self.supportingTurnIDs = supportingTurnIDs
        self.text = text; self.triggerReason = triggerReason; self.relatedPriorQuestion = relatedPriorQuestion
        self.antecedent = antecedent; self.source = source
    }
}
public struct AppError: Error, Equatable, Sendable {
    public enum Domain: String, Sendable { case session, audio, transcription, context, generation, network, visual, model, credentials }
    public enum Category: String, Sendable { case unavailable, permissionDenied, invalidConfiguration, capacity, interrupted, invalidData, staleResult }
    public let domain: Domain
    public let category: Category
    public let recoverable: Bool
    public let userAction: String
    /// Only application-authored metadata belongs here, never observed content or credentials.
    public let diagnosticCode: String
    public init(domain: Domain, category: Category, recoverable: Bool = true, userAction: String,
                diagnosticCode: String) {
        self.domain = domain; self.category = category; self.recoverable = recoverable
        self.userAction = userAction; self.diagnosticCode = diagnosticCode
    }
}
