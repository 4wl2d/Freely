import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct VisualSource: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case display, window }
    let id: String
    let kind: Kind
    let nativeID: UInt32
    let name: String
    let application: String?
    let width: Double
    let height: Double
}

enum ScreenContextMode: String, CaseIterable, Sendable, Codable {
    case off = "Off"
    case manual = "Manual capture only"
    case automatic = "Automatic for relevant questions"
}

struct ScreenSelection: Sendable, Equatable {
    let source: VisualSource
    /// Display-local points, top-left origin, measured on the selected display.
    var region: CGRect?
}

struct CapturedVisual: Sendable {
    let id: UUID
    let selectionEpoch: UInt64
    let captureTime: Date
    let sourceName: String
    let width: Int
    let height: Int
    let contentHash: String
    let png: Data
}

struct PreparedScreenImage: Sendable {
    let captureTime: Date
    let width: Int
    let height: Int
    let png: Data
}

protocol ScreenContextCapturing: Sendable {
    func setConsent(_ mode: ScreenContextMode) async
    func select(_ selection: ScreenSelection?) async
    func capture(manual: Bool) async throws -> CapturedVisual
    func clear() async
}

enum ScreenCaptureFailure: LocalizedError {
    case disabled, noSelection, unavailable, stale, invalidRegion, tooLarge, encoding
    var errorDescription: String? {
        switch self {
        case .disabled: "Screen context is off. Enable it explicitly for this session before capturing."
        case .noSelection: "Select the display or window to analyze."
        case .unavailable: "The selected visual source is unavailable. Select it again; capture scope was not widened."
        case .stale: "The screen selection or consent changed during capture. Capture again."
        case .invalidRegion: "The region is outside the selected display. Choose a region again."
        case .tooLarge: "This image exceeds 4 MiB. Choose a smaller readable region."
        case .encoding: "The selected image could not be prepared. Capture again."
        }
    }
}

actor NativeScreenCapture: ScreenContextCapturing {
    private var mode = ScreenContextMode.off
    private var selection: ScreenSelection?
    private var epoch: UInt64 = 0
    private var latest: CapturedVisual?
    private var pending = false
    private let loadImage: @Sendable (ScreenSelection, @Sendable () async -> Bool) async throws -> PreparedScreenImage

    /// The closure is the native image acquisition boundary; Release uses ScreenCaptureKit below.
    init(loadImage: @escaping @Sendable (ScreenSelection, @Sendable () async -> Bool) async throws -> PreparedScreenImage = NativeScreenCapture.captureNative) {
        self.loadImage = loadImage
    }

    static func sources() async throws -> [VisualSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = content.displays.map {
            VisualSource(id: "display:\($0.displayID)", kind: .display, nativeID: $0.displayID,
                name: "Display \($0.displayID) · \($0.width) × \($0.height)", application: nil,
                width: $0.frame.width, height: $0.frame.height)
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.frame.width > 32 && $0.frame.height > 32
        }.map {
            VisualSource(id: "window:\($0.windowID)", kind: .window, nativeID: $0.windowID,
                name: "\($0.owningApplication?.applicationName ?? "Application") — \($0.title ?? "Untitled window")",
                application: $0.owningApplication?.bundleIdentifier,
                width: $0.frame.width, height: $0.frame.height)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return displays + windows
    }
    func setConsent(_ mode: ScreenContextMode) {
        guard self.mode != mode else { return }
        self.mode = mode; epoch &+= 1; latest = nil
    }
    /// Commits a generation coordinator's latest desired mode/selection as one actor operation.
    func configure(mode: ScreenContextMode, selection: ScreenSelection?) {
        guard !Task.isCancelled, self.mode != mode || self.selection != selection else { return }
        self.mode = mode; self.selection = selection; epoch &+= 1; latest = nil
        CopilotLog.screen.info("Visual consent/selection changed; enabled=\(mode != .off), epoch=\(self.epoch)")
    }
    func select(_ selection: ScreenSelection?) {
        guard self.selection != selection else { return }
        self.selection = selection; epoch &+= 1; latest = nil
    }
    func clear() { epoch &+= 1; latest = nil; mode = .off }
    func capture(manual: Bool) async throws -> CapturedVisual {
        try Task.checkCancellation()
        guard mode != .off, manual || mode == .automatic else { throw ScreenCaptureFailure.disabled }
        guard let selection else { throw ScreenCaptureFailure.noSelection }
        guard !pending else { throw ScreenCaptureFailure.stale }
        pending = true
        defer { pending = false }
        let expected = epoch
        let image = try await loadImage(selection) { [weak self] in await self?.permitsCapture(epoch: expected) ?? false }
        try Task.checkCancellation()
        guard expected == epoch, mode != .off else { throw ScreenCaptureFailure.stale }
        guard image.width > 0, image.height > 0, max(image.width, image.height) <= 2_048,
              image.png.count <= 4 * 1_024 * 1_024 else { throw ScreenCaptureFailure.tooLarge }
        let result = CapturedVisual(id: UUID(), selectionEpoch: expected, captureTime: image.captureTime,
            sourceName: selection.source.name, width: image.width, height: image.height,
            contentHash: SHA256.hash(data: image.png).map { String(format: "%02x", $0) }.joined(), png: image.png)
        latest = result
        CopilotLog.screen.info("Selected screenshot prepared; id=\(result.id.uuidString, privacy: .public), width=\(result.width), height=\(result.height)")
        return result
    }

    private func permitsCapture(epoch expected: UInt64) -> Bool { expected == epoch && mode != .off }

    private static func captureNative(_ selection: ScreenSelection, stillAuthorized: @Sendable () async -> Bool) async throws -> PreparedScreenImage {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard await stillAuthorized() else { throw ScreenCaptureFailure.stale }
        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let bounds: CGRect
        switch selection.source.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == selection.source.nativeID }) else {
                throw ScreenCaptureFailure.unavailable
            }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            bounds = CGRect(origin: .zero, size: display.frame.size)
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selection.source.nativeID }),
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                  window.isOnScreen else { throw ScreenCaptureFailure.unavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            bounds = CGRect(origin: .zero, size: window.frame.size)
        }
        let crop = selection.region ?? bounds
        guard Self.validRegion(crop, inside: bounds) else { throw ScreenCaptureFailure.invalidRegion }
        configuration.sourceRect = crop
        guard let pixels = Self.renderSize(for: crop, pointPixelScale: Double(filter.pointPixelScale)) else { throw ScreenCaptureFailure.invalidRegion }
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.captureDynamicRange = .SDR
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.ignoreShadowsSingleWindow = true
        guard await stillAuthorized() else { throw ScreenCaptureFailure.stale }
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard await stillAuthorized() else { throw ScreenCaptureFailure.stale }
        let captureTime = Date()
        let bytes = try Self.encodePNG(image)
        guard bytes.count <= 4 * 1024 * 1024 else { throw ScreenCaptureFailure.tooLarge }
        try Task.checkCancellation()
        return PreparedScreenImage(captureTime: captureTime, width: image.width, height: image.height, png: bytes)
    }
    func isCurrent(_ image: CapturedVisual, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(image.captureTime)
        return mode != .off && image.selectionEpoch == epoch && latest?.id == image.id && age >= 0 && age <= 30
    }
    static func validRegion(_ rect: CGRect, inside bounds: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
            rect.width >= 8 && rect.height >= 8 && bounds.width >= 8 && bounds.height >= 8 && bounds.contains(rect)
    }
    static func renderSize(for crop: CGRect, pointPixelScale: Double) -> CGSize? {
        guard crop.width.isFinite, crop.height.isFinite, crop.width >= 8, crop.height >= 8,
              pointPixelScale.isFinite, pointPixelScale > 0, pointPixelScale <= 8 else { return nil }
        let scale = min(pointPixelScale, 2_048 / max(crop.width, crop.height))
        return CGSize(width: max(1, (crop.width * scale).rounded()), height: max(1, (crop.height * scale).rounded()))
    }
    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenCaptureFailure.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureFailure.encoding }
        return data as Data
    }
}
