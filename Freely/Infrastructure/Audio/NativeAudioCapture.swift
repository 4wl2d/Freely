import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

struct MicrophoneDevice: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
}
struct AudioApplication: Identifiable, Sendable, Hashable {
    let id: Int32
    let bundleID: String
    let name: String
}

enum SystemAudioSelection: Sendable, Equatable {
    case application(pid: Int32, bundleID: String)
    case allSystemAudio
}

protocol MicrophoneCapturing: Sendable {
    func start(deviceID: String?, ingress: AudioIngress) async throws
    func stop() async
}
protocol SystemAudioCapturing: Sendable {
    func start(selection: SystemAudioSelection, ingress: AudioIngress) async throws
    func stop() async
}

/// AVFoundation owns device routing. Selecting an input never changes the system default.
actor NativeMicrophoneCapture: MicrophoneCapturing {
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var delegate: MicrophoneSink?
    private var epoch: UInt64 = 0
    private var observations: [NSObjectProtocol] = []
    private var clockObservation: NSKeyValueObservation?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "local.freely.microphone", qos: .userInitiated)

    static func devices() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
            position: .unspecified).devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func permission() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    func start(deviceID: String?, ingress: AudioIngress) async throws {
        epoch &+= 1
        let startEpoch = epoch
        await stopCurrent()
        guard epoch == startEpoch, !Task.isCancelled else { throw CancellationError() }
        guard Self.permission() == .authorized else { throw AudioCaptureError.denied }
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                mediaType: .audio, position: .unspecified).devices.first { $0.uniqueID == deviceID }
        } else { device = AVCaptureDevice.default(for: .audio) }
        guard let device, device.isConnected else { throw AudioCaptureError.noDevice }
        let input = try AVCaptureDeviceInput(device: device)
        let newSession = AVCaptureSession()
        let newOutput = AVCaptureAudioDataOutput()
        newSession.beginConfiguration()
        guard newSession.canAddInput(input), newSession.canAddOutput(newOutput) else {
            newSession.commitConfiguration()
            throw AudioCaptureError.configuration("The selected microphone could not be configured.")
        }
        newSession.addInput(input)
        newSession.addOutput(newOutput)
        newSession.commitConfiguration()
        guard epoch == startEpoch, !Task.isCancelled else { throw CancellationError() }
        // AVFoundation establishes this nullable clock when capture starts, not necessarily
        // at commitConfiguration. Publish it through KVO before delivered samples use it.
        let clock = MicrophoneClockMapping(ingress: ingress)
        let sink = MicrophoneSink(ingress: ingress, clock: clock)
        newOutput.setSampleBufferDelegate(sink, queue: queue)
        session = newSession; output = newOutput; delegate = sink
        clockObservation = newSession.observe(\.synchronizationClock, options: [.initial, .new]) { observed, _ in
            // KVO's change dictionary can box a CF-valued property as NSValue. Read through
            // the typed accessor; passing the boxed value to CMSyncConvertTime is invalid.
            clock.observe(observed.synchronizationClock)
        }
        let notifications = NotificationCenter.default
        observations = [
            notifications.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: newSession, queue: nil) { _ in
                ingress.fail("Microphone capture failed. Check the selected input and resume the source.")
            },
            notifications.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: newSession, queue: nil) { _ in
                ingress.fail("Microphone capture was interrupted. Resume the source when the input is available.")
            },
            notifications.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: newSession, queue: nil) { _ in
                ingress.fail("Microphone capture stopped unexpectedly. Resume the source.")
            },
            notifications.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                ingress.fail("The selected microphone disconnected. Reconnect it or choose another input, then resume.")
            }
        ]
        if deviceID == nil {
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                ingress.fail("The system default microphone changed. Resume this source to use the new default input.")
            }
            var address = Self.defaultInputAddress
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            guard status == noErr else {
                await stop()
                throw AudioCaptureError.configuration("Default-input changes could not be observed. Select an explicit microphone instead.")
            }
            defaultInputListener = listener
        }
        newSession.startRunning()
        guard newSession.isRunning else {
            await stop()
            throw AudioCaptureError.configuration("Microphone capture did not start. Check permission and device availability.")
        }
        clock.observe(newSession.synchronizationClock)
        guard clock.isReady else {
            await stop()
            throw AudioCaptureError.configuration("The running microphone did not provide a synchronization clock. Choose another input and resume.")
        }
        guard epoch == startEpoch, !Task.isCancelled else {
            await stop()
            throw CancellationError()
        }
        FreelyLog.record(.audioStarted, scope: .init(source: .localUser), fields: [.epoch: .int(startEpoch)])
    }
    func stop() async {
        epoch &+= 1
        await stopCurrent()
    }
    private func stopCurrent() async {
        let sink = delegate
        let oldSession = session
        let oldOutput = output
        session = nil; output = nil; delegate = nil
        sink?.ingress.close()
        clockObservation?.invalidate(); clockObservation = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations.removeAll()
        if let listener = defaultInputListener {
            var address = Self.defaultInputAddress
            let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            if status != noErr { sink?.ingress.fail("Microphone device-change observation could not be detached.") }
            defaultInputListener = nil
        }
        oldOutput?.setSampleBufferDelegate(nil, queue: nil)
        // Let already-dispatched callbacks leave CMSyncConvertTime before AVFoundation
        // invalidates its device clock. Local handles prevent a late stop touching a successor.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        oldSession?.stopRunning()
        if oldSession != nil { FreelyLog.record(.audioStopped, scope: .init(source: .localUser)) }
    }
    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// A clock is immutable after publication. The KVO observer and audio callback exchange only
/// this retained Sendable reference; no capture-session object crosses into the callback.
final class MicrophoneClockMapping: Sendable {
    private final class Reference: Sendable {
        let clock: CMClock
        init(_ clock: CMClock) { self.clock = clock }
    }
    private let reference = AtomicLazyReference<Reference>()
    private let ingress: AudioIngress
    private let hostToUptime: Double
    init(ingress: AudioIngress) {
        self.ingress = ingress
        hostToUptime = ProcessInfo.processInfo.systemUptime - CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
    var isReady: Bool { reference.load() != nil }
    func observe(_ clock: CMClock?) {
        guard let clock else {
            if isReady { ingress.fail("The microphone synchronization clock became unavailable. Resume the source.") }
            return
        }
        guard CFGetTypeID(clock) == CMClockGetTypeID() else {
            ingress.fail("AVFoundation supplied an invalid microphone clock. Resume the source.")
            return
        }
        let stored = reference.storeIfNil(Reference(clock))
        if !CFEqual(stored.clock, clock) {
            ingress.fail("The microphone synchronization clock changed. Resume the source to reestablish timing.")
        }
    }
    func uptime(for time: CMTime) -> Double? {
        guard let reference = reference.load() else { return nil }
        let converted = CMSyncConvertTime(time, from: reference.clock, to: CMClockGetHostTimeClock()).seconds
        return converted.isFinite ? converted + hostToUptime : nil
    }
}

private final class MicrophoneSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    let ingress: AudioIngress
    private let clock: MicrophoneClockMapping
    init(ingress: AudioIngress, clock: MicrophoneClockMapping) {
        self.ingress = ingress; self.clock = clock
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard ingress.isAccepting else { return }
        let native = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let timestamp = clock.uptime(for: native) else {
            ingress.fail("The microphone delivered samples without a valid clock. Resume the source."); return
        }
        ingress.receive(sampleBuffer, timestampOverride: timestamp)
    }
}

actor NativeSystemAudioCapture: SystemAudioCapturing {
    private var stream: SCStream?
    private var delegate: SystemAudioSink?
    private var epoch: UInt64 = 0
    private let queue = DispatchQueue(label: "local.freely.systemaudio", qos: .userInitiated)

    @MainActor static func applications() async throws -> [AudioApplication] {
        // Listing running apps does not need screen-recording permission. ScreenCaptureKit
        // verifies the selected PID and bundle again when capture actually starts.
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return AudioApplication(id: app.processIdentifier, bundleID: bundleID, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(selection: SystemAudioSelection, ingress: AudioIngress) async throws {
        epoch &+= 1
        let startEpoch = epoch
        await stopCurrent()
        guard epoch == startEpoch, !Task.isCancelled else { throw CancellationError() }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch {
            if epoch != startEpoch || Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard epoch == startEpoch else { throw CancellationError() }
        guard let display = content.displays.first else { throw AudioCaptureError.configuration("No display is available for application audio capture.") }
        let filter: SCContentFilter
        switch selection {
        case .application(let pid, let bundleID):
            guard let application = content.applications.first(where: { $0.processID == pid && $0.bundleIdentifier == bundleID }) else {
                throw AudioCaptureError.noApplication
            }
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        case .allSystemAudio:
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        // Only an audio output is registered. No pixels are delivered, retained, or inspected.
        let sink = SystemAudioSink(ingress: ingress)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try newStream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: queue)
        stream = newStream; delegate = sink
        do {
            try await newStream.startCapture()
            guard epoch == startEpoch, !Task.isCancelled else {
                try await newStream.stopCapture()
                throw CancellationError()
            }
            FreelyLog.record(.audioStarted, scope: .init(source: .systemAudio), fields: [.epoch: .int(startEpoch)])
        } catch {
            let superseded = epoch != startEpoch || Task.isCancelled
            if epoch == startEpoch { await stop() }
            if superseded { throw CancellationError() }
            throw error
        }
    }
    func stop() async {
        epoch &+= 1
        await stopCurrent()
    }
    private func stopCurrent() async {
        let old = stream; let sink = delegate
        stream = nil; delegate = nil
        sink?.ingress.close()
        if let old {
            do { try await old.stopCapture() }
            catch { sink?.ingress.fail("System audio ended with a capture error. Start the source again.") }
            if let sink {
                do { try old.removeStreamOutput(sink, type: .audio) }
                catch { sink.ingress.fail("Audio output was already detached.") }
            }
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        if old != nil { FreelyLog.record(.audioStopped, scope: .init(source: .systemAudio)) }
    }
}

private final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let ingress: AudioIngress
    private let hostToUptime: Double
    init(ingress: AudioIngress) {
        self.ingress = ingress
        hostToUptime = ProcessInfo.processInfo.systemUptime - CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio { ingress.receive(sampleBuffer, timestampOverride: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds + hostToUptime) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ingress.fail("System audio is unavailable. Check capture permission and the selected meeting application.")
    }
}
