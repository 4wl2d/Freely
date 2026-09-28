import AppKit
import CoreImage
import Observation
import QuartzCore
import ScreenCaptureKit
import Synchronization

struct PresentationRevision: Equatable, Sendable {
    var source: UInt64 = 0
    var visibility: UInt64 = 0
}

/// Single replaceable source slot. No panel pixels ever enter the capture queue.
final class PresentationMailbox: Sendable {
    struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer; let revision: UInt64 }
    enum Sample: Sendable { case frame(Frame), unavailable(UInt64) }
    private let slot = Mutex<Sample?>(nil)
    func replace(_ sample: Sample) { slot.withLock { $0 = sample } }
    func take() -> Sample? { slot.withLock { value in let result = value; value = nil; return result } }
    func clear() { slot.withLock { $0 = nil } }
    func discard(through revision: UInt64) {
        slot.withLock { value in
            let current: UInt64?
            switch value {
            case .frame(let frame): current = frame.revision
            case .unavailable(let revision): current = revision
            case nil: current = nil
            }
            if let current, current <= revision { value = nil }
        }
    }
}

private final class PresentationStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let mailbox: PresentationMailbox
    let revision: UInt64
    init(mailbox: PresentationMailbox, revision: UInt64) { self.mailbox = mailbox; self.revision = revision }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let raw = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else {
            mailbox.replace(.unavailable(revision)); return
        }
        if status == .idle || status == .started { return }
        guard status == .complete, let image = buffer.imageBuffer else {
            mailbox.replace(.unavailable(revision)); return
        }
        mailbox.replace(.frame(.init(buffer: image, revision: revision)))
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        FreelyLog.record(.operationFailed, level: .warning, fields: [.state: .state("presentation_capture"), .failure: .failure(error)])
        mailbox.replace(.unavailable(revision))
    }
}

/// The capture adapter is injectable; a background harness can supply immutable frames
/// without ScreenCaptureKit, permissions, a public fixture app or any desktop windows.
@MainActor protocol PresentationStreaming: AnyObject {
    func start(selection: ScreenSelection, mailbox: PresentationMailbox, revision: UInt64) async throws
    func stop() async
}

@MainActor final class NativePresentationStream: PresentationStreaming {
    private var stream: SCStream?
    private var output: PresentationStreamOutput?
    func start(selection: ScreenSelection, mailbox: PresentationMailbox, revision: UInt64) async throws {
        let (filter, configuration) = try await PresentationCapture.configuration(selection)
        try Task.checkCancellation()
        let output = PresentationStreamOutput(mailbox: mailbox, revision: revision)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.freely.presentation.capture", qos: .userInitiated))
        self.output = output; self.stream = stream
        try await stream.startCapture()
        guard self.stream === stream, !Task.isCancelled else {
            // Stop the local stream even if stop() ran while startCapture was suspended.
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }
    func stop() async {
        let stream = stream, output = output
        self.stream = nil; self.output = nil
        try? await stream?.stopCapture()
        withExtendedLifetime(output) {}
    }
}

@MainActor
final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PresentationImageView: NSView {
    var image: CGImage? {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
}

enum PresentationCompositor {
    static let size = CGSize(width: 1920, height: 1080)
    static func fit(_ source: CGSize, into bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func panelRect(_ source: CGSize) -> CGRect {
        let scale = min(1, min((size.width - 32) / source.width, (size.height - 32) / source.height))
        let width = source.width * scale, height = source.height * scale
        return CGRect(x: size.width - width - 16, y: 16, width: width, height: height)
    }
    static func compose(source: CGImage?, panel: CGImage?) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [13 / 255, 17 / 255, 23 / 255, 1])!)
        context.fill(CGRect(origin: .zero, size: size))
        if let source { context.draw(source, in: fit(CGSize(width: source.width, height: source.height), into: CGRect(origin: .zero, size: size))) }
        // A neutral frame must contain neither the source nor the panel.
        if source != nil, let panel {
            let rect = panelRect(CGSize(width: panel.width, height: panel.height))
            context.setFillColor(PanelBackdrop.graphite.cgColor); context.fill(rect)
            context.draw(panel, in: rect)
        }
        return context.makeImage()
    }
}

@MainActor @Observable
final class PresentationCoordinator: NSObject, NSWindowDelegate {
    var sources: [VisualSource] = []
    var sourceID = "" { didSet { if sourceID != oldValue { region = nil; preview = nil; invalidate("Source changed. Check preview, then prepare.") } } }
    var region: CGRect? { didSet { if region != oldValue { preview = nil; invalidate("Region changed. Check preview, then prepare.") } } }
    private(set) var preview: CGImage?
    private(set) var previewLoading = false
    private(set) var publishedFrame: CGImage?
    private(set) var state = "Not prepared"
    private(set) var active = false
    private(set) var preparing = false
    private(set) var showPanel = false
    private(set) var panelVisible = false
    private(set) var panelInPublishedFrame = false
    private(set) var revision = PresentationRevision()
    @ObservationIgnored private(set) var publishedCount: UInt64 = 0
    @ObservationIgnored private(set) var receivedCount: UInt64 = 0
    @ObservationIgnored private(set) var maximumRenderSeconds = 0.0
    @ObservationIgnored private var cachedPanel: CGImage?
    @ObservationIgnored private var lastPanelSnapshotAt = 0.0
    private(set) var publishedRevision = PresentationRevision()
    private(set) var window: PresentationWindow?
    var panelImage: (() -> CGImage?)?
    @ObservationIgnored private let mailbox = PresentationMailbox()
    @ObservationIgnored private let ci = CIContext(options: [.cacheIntermediates: false])
    @ObservationIgnored private var stream: (any PresentationStreaming)?
    @ObservationIgnored private let makeStream: () -> any PresentationStreaming
    @ObservationIgnored private let previewLoader: (ScreenSelection) async throws -> CGImage
    private let outputMode: OutputMode
    private var outputOpen = false
    enum OutputMode { case window, memory, previewWindow }

    init(outputMode: OutputMode = .window,
         makeStream: @escaping () -> any PresentationStreaming = { NativePresentationStream() },
         previewLoader: @escaping (ScreenSelection) async throws -> CGImage = { try await PresentationCapture.preview($0) }) {
        self.outputMode = outputMode; self.makeStream = makeStream; self.previewLoader = previewLoader
        super.init()
    }
    @ObservationIgnored private var imageView: PresentationImageView?
    @ObservationIgnored private var latestSource: CGImage?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRevision: UInt64 = 0
    var selectedSource: VisualSource? { sources.first { $0.id == sourceID } }
    var visibilityStatus: String { panelInPublishedFrame ? "Freely shown in output" : "Freely hidden in output" }

    func refreshSources() async {
        refreshRevision &+= 1
        let expected = refreshRevision
        do {
            let result = try await NativeScreenCapture.sources()
            guard expected == refreshRevision else { return }
            sources = result
            if !sourceID.isEmpty && selectedSource == nil { invalidate("Source unavailable. Select another source.") }
        } catch { if expected == refreshRevision { invalidate("Capture permission or source unavailable. Open Audio & Speech to review permissions.") } }
    }
    func loadPreview() {
        guard let source = selectedSource, !previewLoading else { return }
        previewLoading = true
        previewTask?.cancel()
        let selection = ScreenSelection(source: source, region: region)
        let expected = revision.source
        previewTask = Task { [weak self] in
            defer { self?.previewLoading = false }
            do {
                let image = try await self?.previewLoader(selection)
                guard let image else { return }
                guard let self, !Task.isCancelled, expected == revision.source else { return }
                preview = image
            } catch { if let self, !Task.isCancelled, expected == revision.source { state = "Preview unavailable. Review capture permissions and select the source again." } }
        }
    }
    func prepare() {
        guard let source = selectedSource, preview != nil else { state = "Select a source and check its local preview first."; return }
        let selection = ScreenSelection(source: source, region: region)
        invalidate("Preparing selected source…")
        preparing = true
        ensureWindow()
        let expected = revision.source
        prepareTask = Task { [weak self] in
            guard let self else { return }
            await stopTask?.value
            do {
                guard !Task.isCancelled, expected == revision.source else { return }
                let stream = makeStream()
                self.stream = stream
                try await stream.start(selection: selection, mailbox: mailbox, revision: expected)
                guard !Task.isCancelled, expected == revision.source else { await stream.stop(); return }
                preparing = false; active = true
                state = outputMode == .memory ? "Frame output ready" : "Output ready. Select Freely Presentation in your meeting app."
                startTimer()
            } catch {
                if !Task.isCancelled, expected == revision.source { invalidate("Presentation unavailable. Review capture permissions and prepare again.") }
            }
        }
    }
    func setShowPanel(_ value: Bool) {
        showPanel = value; cachedPanel = nil; lastPanelSnapshotAt = 0; revision.visibility &+= 1
        // Synchronous compositor: no queued images with the old visibility can be published later.
        publish()
    }
    func setPanelVisible(_ value: Bool) {
        panelVisible = value; cachedPanel = nil; lastPanelSnapshotAt = 0; revision.visibility &+= 1; publish()
    }
    func suspend(_ reason: String = "Presentation paused for system UI. Check the source and resume explicitly.") {
        invalidate(reason)
    }
    func sessionEnded() { preview = nil; suspend("Session ended. Output is neutral. Prepare explicitly to resume.") }
    func closeOutput() {
        invalidate("Not prepared")
        outputOpen = false
        let closing = window
        window = nil; imageView = nil; publishedFrame = nil; panelInPublishedFrame = false
        closing?.delegate = nil; closing?.contentView = nil; closing?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeOutput(); return false }
    func shutdown() async { closeOutput(); previewTask?.cancel(); await previewTask?.value; await prepareTask?.value; await stopTask?.value }

    /// A synchronization point for CLI hosts and deterministic adapter tests.
    func waitForPendingOperations() async {
        await previewTask?.value; await prepareTask?.value; await stopTask?.value
    }

    private func invalidate(_ message: String) {
        revision.source &+= 1
        prepareTask?.cancel(); previewTask?.cancel()
        timer?.invalidate(); timer = nil
        active = false; preparing = false; latestSource = nil; cachedPanel = nil; mailbox.clear()
        if let stream {
            let previous = stopTask, closingRevision = revision.source
            let mailbox = mailbox
            stopTask = Task {
                await previous?.value
                await stream.stop()
                // A callback already in flight at invalidation may have replaced the slot.
                // Discard it after capture quiesces without clearing a newer stream's frame.
                mailbox.discard(through: closingRevision)
            }
        }
        stream = nil
        state = message
        publish()
    }
    private func ensureWindow() {
        outputOpen = true
        guard outputMode != .memory else { publish(); return }
        guard window == nil else { return }
        let preview = outputMode == .previewWindow
        let result = PresentationWindow(contentRect: CGRect(x: 80, y: 80, width: preview ? 640 : 960, height: preview ? 360 : 540),
            styleMask: preview ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless], backing: .buffered, defer: false)
        result.title = "Freely Presentation"
        result.isReleasedWhenClosed = false; result.delegate = self
        result.collectionBehavior = preview ? [] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        result.animationBehavior = .none
        result.level = .normal; result.hidesOnDeactivate = false
        result.isOpaque = true; result.backgroundColor = .black
        result.ignoresMouseEvents = !preview
        let view = PresentationImageView(frame: result.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        result.contentView = view; imageView = view; window = result
        publish()
        result.orderBack(nil)
    }
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderLatestFrame() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func renderLatestFrame() {
        guard active else { return }
        var changed = false
        if let sample = mailbox.take() {
            switch sample {
            case .unavailable(let sourceRevision):
                if sourceRevision == revision.source { invalidate("Source interrupted. Output is neutral. Check the source and prepare again."); return }
            case .frame(let frame):
                guard frame.revision == revision.source else { return }
                receivedCount &+= 1; changed = true
                let image = CIImage(cvPixelBuffer: frame.buffer)
                latestSource = ci.createCGImage(image, from: image.extent)
            }
        }
        if changed || (showPanel && panelVisible && ProcessInfo.processInfo.systemUptime - lastPanelSnapshotAt >= 0.1) { publish() }
    }
    private func publish() {
        guard outputOpen else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let token = revision
        if active && panelVisible && showPanel && (cachedPanel == nil || began - lastPanelSnapshotAt >= 0.1) {
            cachedPanel = panelImage?(); lastPanelSnapshotAt = began
        }
        let overlay = active && panelVisible && showPanel ? cachedPanel : nil
        let image = PresentationCompositor.compose(source: active ? latestSource : nil, panel: overlay)
        guard token == revision else { return }
        // Flush drawing before acknowledging the new visibility in observable state.
        imageView?.image = image; imageView?.displayIfNeeded()
        window?.displayIfNeeded(); CATransaction.flush()
        publishedFrame = image; publishedRevision = token; publishedCount &+= 1
        panelInPublishedFrame = image != nil && active && latestSource != nil && overlay != nil
        maximumRenderSeconds = max(maximumRenderSeconds, ProcessInfo.processInfo.systemUptime - began)
    }
}

@MainActor
enum PresentationCapture {
    /// A short owned stream supplies the local preview. Waiting for a valid frame is
    /// bounded; every started stream is stopped on success, failure or cancellation.
    static func preview(_ selection: ScreenSelection) async throws -> CGImage {
        let (filter, configuration) = try await configuration(selection)
        return try await firstFrame(filter: filter, configuration: configuration)
    }
    static func firstFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let mailbox = PresentationMailbox()
        let output = PresentationStreamOutput(mailbox: mailbox, revision: 0)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.freely.presentation.preview"))
        defer { withExtendedLifetime(output) {} }
        do {
            try await stream.startCapture()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let sample = mailbox.take() {
                    switch sample {
                    case .unavailable: throw ScreenCaptureFailure.unavailable
                    case .frame(let frame):
                        let image = CIImage(cvPixelBuffer: frame.buffer)
                        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent) else { throw ScreenCaptureFailure.encoding }
                        try await stream.stopCapture()
                        mailbox.clear()
                        return result
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw ScreenCaptureFailure.unavailable
        } catch {
            try? await stream.stopCapture()
            mailbox.clear()
            throw error
        }
    }
    static func configuration(_ selection: ScreenSelection) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let crop: CGRect?
        switch selection.source.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == selection.source.nativeID }),
                  let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { throw ScreenCaptureFailure.unavailable }
            guard content.applications.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                // Never start a display output unless own-process exclusion can be expressed.
                throw ScreenCaptureFailure.unavailable
            }
            let excluded = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier || ["com.apple.dock", "com.apple.systemuiserver"].contains($0.bundleIdentifier.lowercased())
            }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            filter.includeMenuBar = false
            let visible = CGRect(x: screen.visibleFrame.minX - screen.frame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY,
                width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            if let region = selection.region {
                guard NativeScreenCapture.validRegion(region, inside: CGRect(origin: .zero, size: display.frame.size)) else { throw ScreenCaptureFailure.invalidRegion }
                let clipped = region.intersection(visible)
                guard NativeScreenCapture.validRegion(clipped, inside: visible) else { throw ScreenCaptureFailure.invalidRegion }
                crop = clipped
            } else { crop = visible }
        case .window:
            guard selection.region == nil, let window = content.windows.first(where: { $0.windowID == selection.source.nativeID }),
                  window.isOnScreen, let owner = window.owningApplication,
                  owner.processID != ProcessInfo.processInfo.processIdentifier else { throw ScreenCaptureFailure.unavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            crop = nil
        }
        let configuration = SCStreamConfiguration()
        let sourceSize = crop?.size ?? CGSize(width: selection.source.width, height: selection.source.height)
        let fitted = PresentationCompositor.fit(sourceSize, into: CGRect(origin: .zero, size: PresentationCompositor.size))
        configuration.width = max(2, Int(fitted.width)); configuration.height = max(2, Int(fitted.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.showsCursor = true; configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR; configuration.colorSpaceName = CGColorSpace.sRGB
        if let crop { configuration.sourceRect = crop }
        return (filter, configuration)
    }
}
