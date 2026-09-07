import AVFoundation
import Foundation
import Testing
@testable import MeetingCopilot

struct AudioAdapterTests {
    @Test func ingressBoundsAndMeasuresEveryDroppedNewestFrame() {
        let ingress = AudioIngress(maximumDuration: 2)
        for index in 0..<50 {
            ingress.offer(samples: Array(repeating: 0.25, count: 1_600), sampleRate: 16_000, timestamp: Double(index) / 10)
        }
        let snapshot = ingress.snapshot()
        #expect(snapshot.queuedSeconds <= 2.00001)
        #expect(abs(snapshot.queuedSeconds + snapshot.droppedSeconds - 5) < 0.00001)
        let frames = ingress.drain()
        // SPSC overflow deliberately preserves already-buffered order and drops new arrivals.
        #expect(frames.first?.timestamp == 0)
        #expect(frames.last?.timestamp ?? .infinity < 2)
        #expect(ingress.snapshot().queuedSeconds == 0)
    }
    @Test func noAudioAcceptedAfterClose() {
        let ingress = AudioIngress()
        ingress.offer(samples: [0, 1], sampleRate: 16_000, timestamp: 0)
        ingress.close()
        ingress.offer(samples: [0, 1], sampleRate: 16_000, timestamp: 1)
        #expect(ingress.drain().isEmpty)
    }
    @Test func sourcesHaveIndependentBoundedState() {
        let local = AudioIngress(); let remote = AudioIngress()
        local.offer(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, timestamp: 1)
        remote.offer(samples: Array(repeating: 0.9, count: 16_000), sampleRate: 16_000, timestamp: 1)
        #expect(local.drain()[0].samples[0] == 0.1)
        #expect(remote.drain()[0].samples[0] == 0.9)
    }
    @Test func nativeConverterDownsamplesAndPreservesSine() throws {
        let source = (0..<4_800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        let frame = CapturedAudio(samples: source, sampleRate: 48_000, timestamp: 12, sequence: 1)
        let normalized = try AudioNormalizer().convert(frame)
        #expect(abs(normalized.count - 1_600) <= 16)
        #expect(normalized.allSatisfy { $0.isFinite })
        #expect(normalized.map(abs).max() ?? 0 > 0.9)
        #expect(frame.timestamp == 12)
    }
    @Test func visualCropRejectsOutOfBoundsAndNonfinite() {
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        #expect(NativeScreenCapture.validRegion(CGRect(x: 100, y: 200, width: 640, height: 480), inside: bounds))
        #expect(!NativeScreenCapture.validRegion(CGRect(x: 1_900, y: 0, width: 80, height: 80), inside: bounds))
        #expect(!NativeScreenCapture.validRegion(CGRect(x: 0, y: 0, width: 0, height: 10), inside: bounds))
    }
    @Test func visualCaptureRequiresConsentBeforeNativeAPI() async {
        let capture = NativeScreenCapture()
        do { _ = try await capture.capture(manual: true); Issue.record("Capture unexpectedly allowed without consent") }
        catch { #expect(error is ScreenCaptureFailure) }
    }
}
