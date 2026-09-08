import FreelyCore
import Foundation
import os

struct SourceProcessingMetrics: Sendable {
    var source: AudioSource
    var queuedSeconds: Double = 0
    var retainedBatchSeconds: Double = 0
    var droppedSeconds: Double = 0
    var receivedFrames: UInt64 = 0
    var peak: Float = 0
    var sampleRate: Double = 0
    var analysisSeconds: Double = 0
    var processingSeconds: Double = 0
    var realTimeFactor: Double = 0
    var lastInferenceSeconds: Double = 0
    /// Window-end-to-hypothesis delay. Token-aligned speech latency is measured by the benchmark harness.
    var windowProcessingDelay: Double?
    var finalizationLatency: Double?
    var lastAudioAt: Double?
    var failure: String?
}

/// Bounded, time-preserving energy VAD. This is segmentation, not acoustic echo cancellation.
struct SpeechWindow {
    static let sampleRate = 16_000.0
    let maximumSamples = 240_000
    let prerollSamples = 3_200
    let endingSilenceSamples = 7_200
    var samples: [Float] = []
    private var preroll: [Float] = []
    private(set) var startTime = 0.0
    private(set) var representedEnd = 0.0
    private(set) var speechEnd = 0.0
    private(set) var silenceSamples = 0
    private(set) var speechSamples = 0
    private var noiseRMS: Float = 0.001
    let rmsFloor: Float
    init(rmsFloor: Float = 0.004) { self.rmsFloor = rmsFloor.isFinite ? max(0.0001, min(0.004, rmsFloor)) : 0.004 }
    var active: Bool { !samples.isEmpty }
    var shouldFinalize: Bool { active && (silenceSamples >= endingSilenceSamples || samples.count >= maximumSamples) }
    var canDecode: Bool { speechSamples >= 2_560 && samples.count >= 5_120 }

    /// The worker supplies at most 20ms per update, so endpoints do not inherit large native block jitter.
    mutating func append(_ chunk: [Float], timestamp: Double) {
        guard !chunk.isEmpty else { return }
        let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        let speech = rms >= max(rmsFloor, min(0.012, noiseRMS * 3))
        if !active {
            if !speech {
                noiseRMS = noiseRMS * 0.98 + rms * 0.02
                preroll += chunk
                if preroll.count > prerollSamples { preroll.removeFirst(preroll.count - prerollSamples) }
                return
            }
            samples = preroll
            startTime = timestamp - Double(preroll.count) / Self.sampleRate
            preroll.removeAll(keepingCapacity: true)
        }
        let available = maximumSamples - samples.count
        samples.append(contentsOf: chunk.prefix(max(0, available)))
        representedEnd = startTime + Double(samples.count) / Self.sampleRate
        if speech {
            speechSamples += chunk.count; silenceSamples = 0
            speechEnd = timestamp + Double(chunk.count) / Self.sampleRate
        } else { silenceSamples += chunk.count }
    }
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        silenceSamples = 0; speechSamples = 0
        startTime = 0; representedEnd = 0; speechEnd = 0
    }
}

actor SourcePipeline {
    let source: AudioSource
    let streamEpoch: SourceEpoch
    let ingress: AudioIngress
    private let transcriber: any SpeechTranscribing
    private let normalizer = AudioNormalizer()
    private let sessionOrigin: Double
    private var window = SpeechWindow()
    private var segmentID = SegmentID()
    private var segmentSequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var lastText = ""
    private var lastDecodeEnd = 0.0
    private var lastFrameEnd: Double?
    private var lastFrameSequence: UInt64?
    private var latestReportedOverflow: AudioDiscontinuity?
    private var lastSampleRate: Double?
    private var metrics: SourceProcessingMetrics
    private var cancelled = false
    private var summaryRecorded = false
    private let sessionID: UUID?

    init(source: AudioSource, streamEpoch: SourceEpoch, ingress: AudioIngress,
         transcriber: any SpeechTranscribing, sessionOrigin: Double, sessionID: UUID? = nil) {
        self.sessionID = sessionID
        self.source = source; self.streamEpoch = streamEpoch; self.ingress = ingress
        self.transcriber = transcriber; self.sessionOrigin = sessionOrigin
        self.window = SpeechWindow(rmsFloor: source == .systemAudio ? 0.001 : 0.004)
        metrics = SourceProcessingMetrics(source: source)
    }
    func snapshot() -> SourceProcessingMetrics {
        var result = metrics
        let capture = ingress.snapshot()
        result.queuedSeconds = capture.queuedSeconds
        result.droppedSeconds = capture.droppedSeconds
        result.receivedFrames = capture.receivedFrames
        result.peak = capture.peak
        return result
    }

    func run(onEvent: @escaping @Sendable (TranscriptEvent) async -> Void) async {
        defer { ingress.close(); window.reset(); metrics.retainedBatchSeconds = 0 }
        do {
            while !Task.isCancelled, !cancelled {
                let ingressState = ingress.snapshot()
                metrics.queuedSeconds = ingressState.queuedSeconds
                metrics.droppedSeconds = ingressState.droppedSeconds
                metrics.peak = ingressState.peak
                metrics.receivedFrames = ingressState.receivedFrames
                if let failure = ingressState.failure {
                    metrics.failure = failure
                    let end = elapsed
                    await onEvent(.gap(.init(source: source, streamEpoch: streamEpoch,
                        startTime: min(lastFrameEnd ?? end, end), endTime: end, cause: .sourceUnavailable)))
                    break
                }
                let batch = ingress.drainBatch()
                let frames = batch.frames
                metrics.retainedBatchSeconds = frames.reduce(0) { $0 + $1.duration }
                for loss in batch.losses {
                    let gap = AudioDiscontinuity(source: source, streamEpoch: streamEpoch,
                        startTime: max(0, loss.startTime - sessionOrigin), endTime: max(0, loss.endTime - sessionOrigin),
                        cause: .overflow, lostDuration: loss.duration)
                    latestReportedOverflow = gap
                    await onEvent(.gap(gap))
                }
                if !batch.losses.isEmpty {
                    if revision > 0 { await onEvent(.retract(id: segmentID, source: source, streamEpoch: streamEpoch, revision: revision + 1)) }
                    resetWindow(); normalizer.reset()
                }
                for frame in frames {
                    try Task.checkCancellation()
                    guard !cancelled else { throw CancellationError() }
                    let time = frame.timestamp - sessionOrigin
                    guard time.isFinite, time >= -1, time <= elapsed + 1 else {
                        throw AudioCaptureError.configuration("The source clock does not match the session timeline. Resume the source.")
                    }
                    let formatChanged = lastSampleRate.map { $0 != frame.sampleRate } ?? false
                    let skippedFrame = lastFrameSequence.map { frame.sequence != $0 &+ 1 } ?? false
                    if let lastFrameEnd, formatChanged || skippedFrame || abs(time - lastFrameEnd) > 0.08 {
                        var unexplainedStart = max(0, min(lastFrameEnd, time))
                        let unexplainedEnd = max(0, max(lastFrameEnd, time))
                        if time >= lastFrameEnd, let overflow = latestReportedOverflow,
                           overflow.startTime <= unexplainedStart + 0.001, overflow.endTime > unexplainedStart {
                            unexplainedStart = min(unexplainedEnd, overflow.endTime)
                        }
                        if formatChanged || unexplainedEnd - unexplainedStart > 0.08 {
                            await onEvent(.gap(.init(source: source, streamEpoch: streamEpoch,
                                startTime: unexplainedStart, endTime: unexplainedEnd, cause: .deviceChanged)))
                        }
                        // Even a20ms known drop must break decoder continuity. Its loss event
                        // may have been consumed with the preceding batch's retained frames.
                        if revision > 0 { await onEvent(.retract(id: segmentID, source: source, streamEpoch: streamEpoch, revision: revision + 1)) }
                        resetWindow(); normalizer.reset()
                    }
                    let normalized = try normalizer.convert(frame)
                    metrics.sampleRate = frame.sampleRate
                    lastSampleRate = frame.sampleRate
                    metrics.lastAudioAt = elapsed
                    lastFrameEnd = time + frame.duration
                    lastFrameSequence = frame.sequence
                    var offset = 0
                    while offset < normalized.count {
                        try Task.checkCancellation()
                        guard !cancelled else { throw CancellationError() }
                        // Split exactly at the window edge; append's capacity limit must never discard a chunk tail.
                        let remainingWindow = window.maximumSamples - window.samples.count
                        guard remainingWindow > 0 else {
                            try await decode(final: true, onEvent: onEvent)
                            resetWindow()
                            continue
                        }
                        let count = min(320, normalized.count - offset, remainingWindow)
                        let chunk = Array(normalized[offset..<(offset + count)])
                        window.append(chunk, timestamp: time + Double(offset) / 16_000)
                        offset += count
                        if window.shouldFinalize {
                            try await decode(final: true, onEvent: onEvent)
                            resetWindow()
                        }
                    }
                    metrics.retainedBatchSeconds = max(0, metrics.retainedBatchSeconds - frame.duration)
                }
                if window.canDecode, window.representedEnd - lastDecodeEnd >= 0.32 {
                    try await decode(final: false, onEvent: onEvent)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            // Cancellation is a normal terminal state and all final UI results are fenced upstream.
        } catch {
            metrics.failure = "Local transcription failed. Resume this source to reload its decoder."
            FreelyLog.record(.decodeFailed, level: .error, scope: .init(session: sessionID, source: source), fields: [.failure: .failure(error)])
            let end = elapsed
            await onEvent(.gap(.init(source: source, streamEpoch: streamEpoch,
                startTime: min(lastFrameEnd ?? end, end), endTime: end, cause: .decodingFailure)))
        }
    }
    func stop() async {
        if !summaryRecorded {
            summaryRecorded = true
            let final = snapshot()
            FreelyLog.record(.sourceSummary, scope: .init(session: sessionID, source: source), fields: [
                .epoch: .int(streamEpoch.rawValue), .frames: .int(final.receivedFrames),
                .queuedSeconds: .number(final.queuedSeconds), .droppedSeconds: .number(final.droppedSeconds),
                .realTimeFactor: .number(final.realTimeFactor)])
        }
        cancelled = true; ingress.close()
        await transcriber.stop()
        window.reset(); normalizer.reset(); metrics.retainedBatchSeconds = 0
    }
    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - sessionOrigin }
    private func resetWindow() {
        window.reset(); segmentID = .init(); segmentSequence &+= 1
        revision = 0; lastText = ""; lastDecodeEnd = 0
    }
    private func decode(final: Bool, onEvent: @Sendable (TranscriptEvent) async -> Void) async throws {
        guard window.canDecode else {
            if final && revision > 0 {
                await onEvent(.retract(id: segmentID, source: source, streamEpoch: streamEpoch, revision: revision + 1))
            }
            return
        }
        let capturedStart = window.startTime
        let capturedEnd = window.representedEnd
        let speechEnd = window.speechEnd
        let start = ProcessInfo.processInfo.systemUptime
        let hypothesis = try await transcriber.transcribe(window.samples)
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let inference = ProcessInfo.processInfo.systemUptime - start
        FreelyLog.record(.decodeCompleted, level: .debug, scope: .init(session: sessionID, source: source), fields: [.segmentID: .id(segmentID.rawValue), .final: .flag(final), .empty: .flag(hypothesis.text.isEmpty), .epoch: .int(streamEpoch.rawValue)], duration: inference)
        metrics.lastInferenceSeconds = inference
        metrics.processingSeconds += inference
        metrics.analysisSeconds += max(0, capturedEnd - max(capturedStart, lastDecodeEnd))
        metrics.realTimeFactor = metrics.processingSeconds / max(0.001, metrics.analysisSeconds)
        lastDecodeEnd = capturedEnd
        if final { metrics.finalizationLatency = max(0, elapsed - speechEnd) }
        else { metrics.windowProcessingDelay = max(0, elapsed - capturedEnd) }
        if hypothesis.text.isEmpty {
            if final && revision > 0 {
                await onEvent(.retract(id: segmentID, source: source, streamEpoch: streamEpoch, revision: revision + 1))
            }
            return
        }
        guard final || hypothesis.text != lastText else { return }
        revision &+= 1; lastText = hypothesis.text
        let segment = TranscriptSegment(id: segmentID, source: source, streamEpoch: streamEpoch,
            sequence: segmentSequence, startTime: max(0, capturedStart),
            endTime: final ? max(capturedStart, speechEnd) : capturedEnd,
            text: hypothesis.text, confidence: hypothesis.confidence,
            finality: final ? .final : .partial, revision: revision)
        await onEvent(final ? .finalize(segment) : .upsert(segment))
    }
}
