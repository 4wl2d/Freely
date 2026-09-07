import CopilotCore
import Foundation
import Synchronization
import Testing
@testable import MeetingCopilot

private actor PipelineFixtureTranscriber: SpeechTranscribing {
    private(set) var calls = 0
    func transcribe(_ samples: [Float]) -> SpeechHypothesis {
        calls += 1
        return SpeechHypothesis(text: "What is the current source question", confidence: nil)
    }
    func stop() {}
}
private actor PipelineEventCollector {
    private(set) var gaps: [AudioDiscontinuity] = []
    private(set) var segments: [TranscriptSegment] = []
    func receive(_ event: TranscriptEvent) {
        switch event {
        case .gap(let gap): gaps.append(gap)
        case .upsert(let segment), .finalize(let segment): segments.append(segment)
        default: break
        }
    }
}

struct SourcePipelineTests {
    @Test func shortNewestOverflowResetsAtTheNextFrameWithoutJoiningAcrossMissingAudio() async throws {
        let origin = ProcessInfo.processInfo.systemUptime - 100
        let ingress = AudioIngress(maximumDuration: 0.04)
        for index in 0..<3 {
            ingress.offer(samples: [Float](repeating: 0.1, count: 320), sampleRate: 16_000, timestamp: origin + Double(index) / 50)
        }
        let pipeline = SourcePipeline(source: .systemAudio, streamEpoch: .init(9), ingress: ingress,
            transcriber: PipelineFixtureTranscriber(), sessionOrigin: origin)
        let events = PipelineEventCollector()
        let worker = Task { await pipeline.run { await events.receive($0) } }
        for index in 3..<22 {
            for _ in 0..<100 {
                if ingress.snapshot().queuedSeconds == 0 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            ingress.offer(samples: [Float](repeating: 0.1, count: 320), sampleRate: 16_000, timestamp: origin + Double(index) / 50)
        }
        for _ in 0..<100 {
            if !(await events.segments.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        worker.cancel(); await worker.value; await pipeline.stop()
        let first = try #require(await events.segments.first)
        #expect(abs(first.startTime - 0.06) < 0.00001)
        let gaps = await events.gaps
        #expect(gaps.count == 1)
        #expect(gaps.first?.cause == .overflow)
        #expect(abs((gaps.first?.droppedDuration ?? 0) - 0.02) < 0.00001)
    }

    @Test func frozenSourceSpecificVADAdmitsQuietRemoteSpeechWithoutLoweringLocalFloor() {
        var remote = SpeechWindow(rmsFloor: 0.001), local = SpeechWindow()
        for index in 0..<100 {
            let silence = [Float](repeating: 0.00005, count: 320)
            remote.append(silence, timestamp: Double(index) / 50)
            local.append(silence, timestamp: Double(index) / 50)
        }
        for index in 100..<125 {
            let quietSpeech = [Float](repeating: 0.0015, count: 320)
            remote.append(quietSpeech, timestamp: Double(index) / 50)
            local.append(quietSpeech, timestamp: Double(index) / 50)
        }
        #expect(remote.canDecode)
        #expect(!local.canDecode)
        #expect(local.rmsFloor == 0.004)
        #expect(remote.rmsFloor == 0.001)
    }

    @Test func ingressLossIntervalsCarryExactDurationAndAreConsumedOnce() {
        let ingress = AudioIngress(maximumDuration: 0.2)
        for index in 0..<5 { ingress.offer(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, timestamp: 40 + Double(index) / 10) }
        let batch = ingress.drainBatch()
        #expect(abs(batch.losses.reduce(0) { $0 + $1.duration } - 0.3) < 0.00001)
        #expect(abs((batch.losses.first?.startTime ?? 0) - 40.2) < 0.00001)
        #expect(abs((batch.losses.first?.endTime ?? 0) - 40.5) < 0.00001)
        #expect(batch.frames.map(\.timestamp) == [40, 40.1])
        #expect(ingress.drainBatch().losses.isEmpty)
        let oversized = AudioIngress(maximumDuration: 0.1)
        oversized.offer(samples: [Float](repeating: 0.1, count: 4_000), sampleRate: 16_000, timestamp: 100)
        let lost = oversized.drainBatch()
        #expect(lost.frames.isEmpty)
        #expect(lost.losses == [.init(startTime: 100, endTime: 100.25, duration: 0.25)])
    }

    @Test func concurrentCaptureAndDrainConserveSamplesUnderOverflowAndContention() async {
        let ingress = AudioIngress(maximumDuration: 0.1)
        let completed = Atomic<Bool>(false)
        let producer = Task.detached {
            for index in 0..<2_000 {
                ingress.offer(samples: [Float](repeating: 0.25, count: 160), sampleRate: 16_000, timestamp: Double(index) / 100)
            }
            completed.store(true, ordering: .releasing)
        }
        var retained = 0.0
        var reportedLoss = 0.0
        while !completed.load(ordering: .acquiring) {
            let batch = ingress.drainBatch()
            retained += batch.frames.reduce(0) { $0 + $1.duration }
            reportedLoss += batch.losses.reduce(0) { $0 + $1.duration }
            await Task.yield()
        }
        await producer.value
        let batch = ingress.drainBatch()
        retained += batch.frames.reduce(0) { $0 + $1.duration }
        reportedLoss += batch.losses.reduce(0) { $0 + $1.duration }
        #expect(abs(retained + ingress.snapshot().droppedSeconds - 20) < 0.00001)
        #expect(abs(reportedLoss - ingress.snapshot().droppedSeconds) < 0.00001)
        #expect(ingress.snapshot().receivedFrames == 2_000)
        #expect(ingress.snapshot().queuedSeconds <= 0.1)
    }

    @Test func timestampGapsStillDetectedAfterEarlierOverflow() async throws {
        let origin = ProcessInfo.processInfo.systemUptime - 100
        let ingress = AudioIngress(maximumDuration: 0.2)
        for index in 0..<5 { ingress.offer(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, timestamp: origin + Double(index) / 10) }
        let pipeline = SourcePipeline(source: .systemAudio, streamEpoch: .init(7), ingress: ingress,
            transcriber: PipelineFixtureTranscriber(), sessionOrigin: origin)
        let events = PipelineEventCollector()
        let worker = Task { await pipeline.run { await events.receive($0) } }
        for _ in 0..<100 {
            if await events.gaps.contains(where: { $0.cause == .overflow }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        ingress.offer(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, timestamp: origin + 3)
        for _ in 0..<100 {
            if await events.gaps.contains(where: { $0.cause == .deviceChanged }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        worker.cancel(); await worker.value; await pipeline.stop()
        let gaps = await events.gaps
        #expect(gaps.contains { $0.cause == .overflow && abs($0.droppedDuration - 0.3) < 0.00001 })
        #expect(gaps.contains { $0.cause == .deviceChanged && $0.endTime >= 3 })
        #expect(gaps.allSatisfy { $0.source == .systemAudio && $0.streamEpoch == .init(7) })
        #expect(await pipeline.snapshot().failure == nil)
    }

    @Test func windowBoundaryKeepsTailOfNondivisibleNativeFrame() async throws {
        // A fixed past clock also exercises a boundary rounded just below 15 seconds.
        let origin = -100.0
        let ingress = AudioIngress()
        let transcriber = PipelineFixtureTranscriber()
        let pipeline = SourcePipeline(source: .localUser, streamEpoch: .init(2), ingress: ingress, transcriber: transcriber, sessionOrigin: origin)
        let events = PipelineEventCollector()
        let worker = Task { await pipeline.run { await events.receive($0) } }
        // 250 native frames = 16 seconds. The 15-second window ends inside the 235th 1024-sample frame.
        for index in 0..<250 {
            ingress.offer(samples: [Float](repeating: 0.1, count: 1_024), sampleRate: 16_000, timestamp: origin + Double(index * 1_024) / 16_000)
            if index % 10 == 9 {
                for _ in 0..<100 {
                    if ingress.snapshot().queuedSeconds == 0 { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        for _ in 0..<100 {
            // Identical hypotheses suppress later partial events, so wait for decoded
            // audio coverage instead of requiring a newer displayed timestamp.
            if await pipeline.snapshot().analysisSeconds >= 16 - 0.00001 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        worker.cancel(); await worker.value; await pipeline.stop()
        let segments = await events.segments
        let final = try #require(segments.first { $0.finality == .final })
        let continuation = try #require(segments.first { $0.sequence == final.sequence + 1 })
        #expect(abs(final.endTime - 15) < 0.00001)
        #expect(abs(continuation.startTime - 15) < 0.00001)
        #expect(abs(await pipeline.snapshot().analysisSeconds - 16) < 0.00001)
        #expect(await events.gaps.isEmpty)
        #expect(ingress.snapshot().droppedSeconds == 0)
        #expect(await pipeline.snapshot().retainedBatchSeconds == 0)
    }

    @Test func converterHandlesSequentialBlocksAndRateChangesWithoutStaleAudio() throws {
        let normalizer = AudioNormalizer()
        var count = 0
        for index in 0..<100 {
            let input = CapturedAudio(samples: [Float](repeating: 0.25, count: 1_024), sampleRate: 48_000, timestamp: Double(index * 1_024) / 48_000, sequence: UInt64(index))
            count += try normalizer.convert(input).count
        }
        #expect(abs(Double(count) - 102_400.0 / 3) < 2)
        let direct = CapturedAudio(samples: [Float](repeating: 0.9, count: 1_600), sampleRate: 16_000, timestamp: 3, sequence: 100)
        #expect(try normalizer.convert(direct) == direct.samples)
        let restarted = CapturedAudio(samples: [Float](repeating: 0, count: 4_800), sampleRate: 48_000, timestamp: 4, sequence: 101)
        #expect(try normalizer.convert(restarted).allSatisfy { $0 == 0 })
    }
}
