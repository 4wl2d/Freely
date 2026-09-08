import Foundation
import Testing
@testable import Freely

private actor VisualCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

struct VisualCaptureTests {
    private func selection(_ id: UInt32 = 1) -> ScreenSelection {
        .init(source: .init(id: "display:\(id)", kind: .display, nativeID: id, name: "Test-only display", application: nil, width: 1_920, height: 1_080))
    }
    private func image(at time: Date = Date()) -> PreparedScreenImage {
        .init(captureTime: time, width: 100, height: 100, png: Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }
    @Test func displayScaleAndRotatedGeometryStayBoundedWithoutInventedUpscaling() {
        let rectangle = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(NativeScreenCapture.renderSize(for: rectangle, pointPixelScale: 1) == CGSize(width: 600, height: 400))
        #expect(NativeScreenCapture.renderSize(for: rectangle, pointPixelScale: 2) == CGSize(width: 1_200, height: 800))
        let portrait = NativeScreenCapture.renderSize(for: CGRect(x: 0, y: 0, width: 1_080, height: 1_920), pointPixelScale: 2)
        #expect(portrait?.height == 2_048)
        #expect(portrait?.width == 1_152)
        #expect(NativeScreenCapture.renderSize(for: rectangle, pointPixelScale: .nan) == nil)
        #expect(!NativeScreenCapture.validRegion(CGRect(x: -1, y: 0, width: 100, height: 100), inside: rectangle))
    }
    @Test func disabledAndManualModesPreventUnrequestedAcquisition() async throws {
        let capture = NativeScreenCapture(loadImage: { _, _ in Issue.record("Acquisition must not run"); return image() })
        await capture.select(selection())
        do { _ = try await capture.capture(manual: true); Issue.record("Disabled capture must fail") } catch { #expect(error is ScreenCaptureFailure) }
        await capture.setConsent(.manual)
        do { _ = try await capture.capture(manual: false); Issue.record("Manual-only capture must reject automatic request") } catch { #expect(error is ScreenCaptureFailure) }
    }
    @Test func consentRevocationAndSelectionChangesDiscardPendingImage() async throws {
        for revoke in [true, false] {
            let gate = VisualCaptureGate()
            let capture = NativeScreenCapture(loadImage: { _, authorized in
                await gate.wait()
                #expect(await authorized() == false)
                return image()
            })
            await capture.setConsent(.manual)
            await capture.select(selection())
            let task = Task { try await capture.capture(manual: true) }
            for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(1)) }
            #expect(await gate.started)
            if revoke { await capture.setConsent(.off) } else { await capture.select(selection(2)) }
            await gate.release()
            do { _ = try await task.value; Issue.record("Pending obsolete image must be rejected") }
            catch { #expect(error is ScreenCaptureFailure) }
        }
    }
    @Test func latestImageIdentityAndAgeAreChecked() async throws {
        let time = Date()
        let capture = NativeScreenCapture(loadImage: { _, _ in image(at: time) })
        await capture.setConsent(.manual)
        await capture.select(selection())
        let first = try await capture.capture(manual: true)
        #expect(await capture.isCurrent(first, now: time.addingTimeInterval(1)))
        #expect(await capture.isCurrent(first, now: time.addingTimeInterval(-1)) == false)
        #expect(await capture.isCurrent(first, now: time.addingTimeInterval(31)) == false)
        let newer = try await capture.capture(manual: true)
        #expect(await capture.isCurrent(first, now: time.addingTimeInterval(1)) == false)
        #expect(await capture.isCurrent(newer, now: time.addingTimeInterval(1)))
        await capture.clear()
        #expect(await capture.isCurrent(newer, now: time.addingTimeInterval(1)) == false)
    }
    @Test func cancellationDiscardsImageThatFinishesAfterStop() async throws {
        let gate = VisualCaptureGate()
        let capture = NativeScreenCapture(loadImage: { _, _ in await gate.wait(); return image() })
        await capture.setConsent(.manual)
        await capture.select(selection())
        let task = Task { try await capture.capture(manual: true) }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.started)
        task.cancel()
        await capture.clear()
        await gate.release()
        do { _ = try await task.value; Issue.record("Cancelled screenshot must not escape") }
        catch { #expect(error is CancellationError) }
    }
}
