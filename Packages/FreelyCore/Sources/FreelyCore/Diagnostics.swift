import Foundation

public struct MetricSnapshot: Sendable {
    public let count: UInt64
    public let retainedSamples: Int
    public let p50: Double?
    public let p95: Double?
    public let maximum: Double?
}
public struct BoundedMetric: Sendable {
    private var samples: [Double] = []
    private var cursor = 0
    private var count: UInt64 = 0
    private let capacity: Int
    public init(capacity: Int = 1_024) { self.capacity = max(1, capacity) }
    public mutating func record(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        count &+= 1
        if samples.count < capacity { samples.append(value) }
        else { samples[cursor] = value; cursor = (cursor + 1) % capacity }
    }
    /// Percentiles cover the bounded recent window; count covers all accepted measurements.
    public var snapshot: MetricSnapshot {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        return .init(count: count, retainedSamples: samples.count, p50: percentile(0.5),
                     p95: percentile(0.95), maximum: sorted.last)
    }
}
public struct AudioTimeline: Sendable {
    public private(set) var lastEndTime: TimeInterval?
    public private(set) var processedFrames: UInt64 = 0
    private var sourceEnds: [AudioSource: (epoch: SourceEpoch, end: TimeInterval)] = [:]
    public init() {}
    public mutating func observe(_ frame: AudioFrame) -> AudioDiscontinuity? {
        guard frame.timestamp.isFinite, frame.timestamp >= 0, frame.format.sampleRate.isFinite,
              frame.format.sampleRate > 0, frame.format.channels > 0 else { return nil }
        defer {
            lastEndTime = frame.timestamp + frame.duration
            sourceEnds[frame.source] = (frame.streamEpoch, frame.timestamp + frame.duration)
            processedFrames &+= 1
        }
        guard let source = sourceEnds[frame.source], source.epoch == frame.streamEpoch,
              frame.timestamp - source.end > 0.002 else { return nil }
        return .init(source: frame.source, streamEpoch: frame.streamEpoch,
                     startTime: source.end, endTime: frame.timestamp, cause: .overflow)
    }
}
