import Foundation
import Observation
import Synchronization
import Testing
@testable import Freely

private final class PresentationInvalidations: Sendable {
    let count = Mutex(0)
    func record() { count.withLock { $0 += 1 } }
}
@MainActor struct StopPresentationTests {
    @Test func transientStopStateInvalidatesComputedToolbarPresentation() async {
        let model = ApplicationModel()
        let changes = PresentationInvalidations()
        withObservationTracking {
            _ = model.preparing
            _ = model.status
        } onChange: { changes.record() }
        await model.stop()
        #expect(changes.count.withLock { $0 } > 0)
        #expect(!model.preparing)
        #expect(model.status != "Ending session")
        await model.shutdown()
    }
}
