import CoreMedia
import Foundation
import Testing
@testable import Freely

struct MicrophoneClockTests {
    @Test func clockCanBeEstablishedAfterConfiguration() throws {
        let ingress = AudioIngress()
        let mapping = MicrophoneClockMapping(ingress: ingress)
        mapping.observe(nil)
        #expect(!mapping.isReady)
        #expect(ingress.snapshot().failure == nil)
        mapping.observe(CMClockGetHostTimeClock())
        #expect(mapping.isReady)
        let mapped = try #require(mapping.uptime(for: CMClockGetTime(CMClockGetHostTimeClock())))
        #expect(abs(mapped - ProcessInfo.processInfo.systemUptime) < 0.1)
        mapping.observe(CMClockGetHostTimeClock())
        #expect(ingress.snapshot().failure == nil)
    }
    @Test func clockLossAfterStartIsAnExplicitSourceFailure() {
        let ingress = AudioIngress()
        let mapping = MicrophoneClockMapping(ingress: ingress)
        mapping.observe(CMClockGetHostTimeClock())
        mapping.observe(nil)
        #expect(ingress.snapshot().failure != nil)
    }
}
