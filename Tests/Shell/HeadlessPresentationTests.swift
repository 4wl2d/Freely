import AppKit
import CoreVideo
import Testing
@testable import Freely

/// Test-only immutable frames. No permissions, display capture, external app or window.
@MainActor final class FixturePresentationStream: PresentationStreaming {
    static let source = VisualSource(id: "memory-fixture", kind: .window, nativeID: .max,
        name: "Synthetic in-memory frames", application: nil, width: 100, height: 100)
    let image: CGImage
    private let buffer: CVPixelBuffer
    private let repeats: Bool
    private var timer: Timer?
    private var mailbox: PresentationMailbox?
    private var revision: UInt64 = 0
    private(set) var starts = 0
    private(set) var stops = 0
    var isRunning: Bool { mailbox != nil }
    init(repeats: Bool = false) throws {
        self.repeats = repeats
        image = try PresentationCompositorTests.solid(CGColor(red: 0, green: 0.6, blue: 0.3, alpha: 1))
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw ScreenCaptureFailure.encoding }
        buffer = pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw ScreenCaptureFailure.encoding }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    func start(selection: ScreenSelection, mailbox: PresentationMailbox, revision: UInt64) async throws {
        self.mailbox = mailbox; self.revision = revision; starts += 1
        emit()
        if repeats {
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.emit() } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    func stop() async { timer?.invalidate(); timer = nil; mailbox = nil; stops += 1 }
    func emit() { mailbox?.replace(.frame(.init(buffer: buffer, revision: revision))) }
    func delayedFrame() -> () -> Void {
        let mailbox = mailbox, revision = revision, buffer = buffer
        return { mailbox?.replace(.frame(.init(buffer: buffer, revision: revision))) }
    }
    func coordinator() -> PresentationCoordinator {
        let coordinator = PresentationCoordinator(outputMode: .memory, makeStream: { self }, previewLoader: { _ in self.image })
        coordinator.sources = [Self.source]; coordinator.sourceID = Self.source.id
        return coordinator
    }
}

@MainActor struct HeadlessPresentationTests {
    @Test func framesVisibilityAndLateCallbacksWorkWithoutCreatingAWindow() async throws {
        let application = NSApplication.shared
        let visibleBefore = Set(application.windows.filter(\.isVisible).map(\.windowNumber))
        let stream = try FixturePresentationStream()
        let output = stream.coordinator()
        let marker = try PresentationCompositorTests.solid(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 1, 1])!)
        output.panelImage = { marker }
        output.loadPreview(); await output.waitForPendingOperations()
        output.setPanelVisible(true); output.setShowPanel(true)
        output.prepare(); await output.waitForPendingOperations()
        output.renderLatestFrame()
        #expect(output.active && output.window == nil && stream.isRunning)
        #expect(PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        let delayed = stream.delayedFrame()
        output.setPanelVisible(false)
        #expect(output.publishedRevision == output.revision)
        #expect(!PresentationCompositorTests.hasMagenta(try #require(output.publishedFrame)))
        output.setPanelVisible(true)
        output.suspend(); await output.waitForPendingOperations()
        #expect(!output.active && !stream.isRunning)
        output.prepare(); await output.waitForPendingOperations()
        let frames = output.receivedCount
        delayed(); output.renderLatestFrame()
        #expect(output.receivedCount == frames, "An old stream cannot publish after restart")
        stream.emit(); output.renderLatestFrame()
        #expect(output.receivedCount == frames + 1)
        output.closeOutput(); await output.waitForPendingOperations()
        #expect(output.window == nil && output.publishedFrame == nil && !stream.isRunning)
        #expect(stream.starts == stream.stops)
        #expect(Set(application.windows.filter(\.isVisible).map(\.windowNumber)) == visibleBefore)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        await output.shutdown()
    }
}
