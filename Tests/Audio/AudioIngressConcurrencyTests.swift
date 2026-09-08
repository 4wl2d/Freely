import Foundation
import Synchronization
import Testing
@testable import Freely

/// A shared reference gives noncopyable atomic storage one stable owner across test tasks.
private final class IngressStressSignal: Sendable {
    let value = Atomic<Bool>(false)
}

struct AudioIngressConcurrencyTests {
    @Test func lowBacklogProducerHasZeroLossWhileConsumerAndDiagnosticsRunConcurrently() async {
        let ingress = AudioIngress(maximumDuration: 2)
        let complete = IngressStressSignal()
        let count = 20_000
        let samples = [Float](repeating: 0.2, count: 160)
        let producer = Task.detached {
            for index in 0..<count {
                // Pace outside the callback under test. Queue occupancy stays far below capacity;
                // any drop would therefore be synchronization loss rather than intentional overflow.
                while ingress.snapshot().queuedSeconds >= 0.05 { await Task.yield() }
                ingress.offer(samples: samples, sampleRate: 16_000, timestamp: Double(index) / 100)
            }
            complete.value.store(true, ordering: .releasing)
        }
        let diagnostics = Task.detached {
            var samples = 0
            while !complete.value.load(ordering: .acquiring) {
                _ = ingress.snapshot(); samples += 1
                if samples % 64 == 0 { await Task.yield() }
            }
            return samples
        }
        var deliveredSamples = 0
        var previousSequence: UInt64 = 0
        var ordered = true
        var measuredLoss = 0.0
        while !complete.value.load(ordering: .acquiring) {
            let batch = ingress.drainBatch()
            for frame in batch.frames {
                ordered = ordered && frame.sequence == previousSequence + 1
                previousSequence = frame.sequence; deliveredSamples += frame.samples.count
            }
            measuredLoss += batch.losses.reduce(0) { $0 + $1.duration }
            await Task.yield()
        }
        await producer.value
        let final = ingress.drainBatch()
        for frame in final.frames {
            ordered = ordered && frame.sequence == previousSequence + 1
            previousSequence = frame.sequence; deliveredSamples += frame.samples.count
        }
        measuredLoss += final.losses.reduce(0) { $0 + $1.duration }
        #expect(await diagnostics.value > 0)
        #expect(deliveredSamples == count * 160)
        #expect(ordered)
        #expect(measuredLoss == 0)
        #expect(ingress.snapshot().droppedSeconds == 0)
        #expect(ingress.snapshot().receivedFrames == UInt64(count))
        #expect(ingress.snapshot().queuedSeconds == 0)
        #expect(ingress.snapshot().failure == nil)
        ingress.close()
    }

    @Test func closeAndDrainCanRacePublicationWithoutLeavingFramesOrBorrowedOwnership() async {
        for _ in 0..<100 {
            let ingress = AudioIngress(maximumDuration: 0.2)
            let started = IngressStressSignal()
            let producer = Task.detached {
                let samples = [Float](repeating: 0.3, count: 320)
                for index in 0..<300 {
                    ingress.offer(samples: samples, sampleRate: 16_000, timestamp: Double(index) / 50)
                    if index == 0 { started.value.store(true, ordering: .releasing) }
                }
            }
            while !started.value.load(ordering: .acquiring) { await Task.yield() }
            _ = ingress.drainBatch()
            ingress.close(); ingress.close()
            await producer.value
            #expect(ingress.drainBatch().frames.isEmpty)
            #expect(ingress.snapshot().queuedSeconds == 0)
            let received = ingress.snapshot().receivedFrames
            ingress.offer(samples: [0.3], sampleRate: 16_000, timestamp: 100)
            #expect(ingress.snapshot().receivedFrames == received)
        }
    }
}
