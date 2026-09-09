import AppKit
import FreelyCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Freely

private struct ReplayFixture: Codable, Sendable {
    let file: String
    let duration: Double
    let sha256: String
}
private enum SoakFailure: String, Error { case corruptCorpus, preparationTimeout, sourceUnavailable, uiIsolationViolation, cancelled, runFailure }

private actor PacedPCMReader {
    private let files: [URL]
    private var index = 0
    private var handle: FileHandle?
    let manifestHash: String
    let fixtureCount: Int
    let corpusSeconds: Double
    init(manifest: URL) throws {
        let metadata = try manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true, (metadata.fileSize ?? 0) > 0,
              (metadata.fileSize ?? .max) <= 8 * 1_024 * 1_024 else { throw SoakFailure.corruptCorpus }
        let data = try Data(contentsOf: manifest)
        manifestHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fixtures = try JSONDecoder().decode([ReplayFixture].self, from: data)
        guard !fixtures.isEmpty, fixtures.count <= 1_000 else { throw SoakFailure.corruptCorpus }
        let directory = manifest.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var paths: [URL] = [], total = 0.0
        for fixture in fixtures {
            guard fixture.duration.isFinite, fixture.duration > 0, fixture.duration <= 3_600,
                  fixture.sha256.count == 64, fixture.sha256.allSatisfy(\.isHexDigit),
                  !fixture.file.hasPrefix("/"), !fixture.file.split(separator: "/").contains("..") else { throw SoakFailure.corruptCorpus }
            let file = directory.appendingPathComponent(fixture.file).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(directory.path + "/") else { throw SoakFailure.corruptCorpus }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let expected = Int((fixture.duration * 16_000).rounded()) * 4
            guard values.isRegularFile == true, expected > 0, values.fileSize == expected else { throw SoakFailure.corruptCorpus }
            let audio = try Data(contentsOf: file, options: .mappedIfSafe)
            guard SHA256.hash(data: audio).map({ String(format: "%02x", $0) }).joined() == fixture.sha256.lowercased() else { throw SoakFailure.corruptCorpus }
            paths.append(file); total += fixture.duration
        }
        guard total <= 86_400 else { throw SoakFailure.corruptCorpus }
        files = paths; fixtureCount = fixtures.count; corpusSeconds = total
    }
    /// Fill one exact frame across file boundaries. No padded, skipped, or short-tail timing gaps.
    func next(sampleCount: Int = 320) throws -> [Float] {
        guard (1...320).contains(sampleCount) else { throw SoakFailure.corruptCorpus }
        var output = Data(); output.reserveCapacity(sampleCount * 4)
        var emptyReads = 0
        while output.count < sampleCount * 4 {
            if handle == nil { handle = try FileHandle(forReadingFrom: files[index]) }
            guard let handle else { throw SoakFailure.corruptCorpus }
            let data = try handle.read(upToCount: sampleCount * 4 - output.count) ?? Data()
            if data.isEmpty {
                try handle.close(); self.handle = nil; index = (index + 1) % files.count
                emptyReads += 1
                guard emptyReads <= files.count else { throw SoakFailure.corruptCorpus }
                continue
            }
            emptyReads = 0
            guard data.count % 4 == 0 else { throw SoakFailure.corruptCorpus }
            output.append(data)
        }
        let samples = output.withUnsafeBytes { bytes in
            (0..<sampleCount).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw SoakFailure.corruptCorpus }
        return samples
    }
    func close() throws { let old = handle; handle = nil; try old?.close() }
}

private struct FixtureCaptureSnapshot: Sendable {
    let frames: UInt64
    let samples: UInt64
    let maximumSchedulerLag: Double
    let recentLag: MetricSnapshot
    let failure: String?
    let running: Bool
    let stopSeconds: Double?
    let manifestHash: String
    let fixtureCount: Int
    let corpusSeconds: Double
}

/// Test-only capture replacement. The shipped SourcePipeline, local model, context and
/// session/generation coordinators remain real. No user microphone or screen is touched.
private actor PacedFixtureCapture: MicrophoneCapturing, SystemAudioCapturing {
    private let reader: PacedPCMReader
    private var job: Task<Void, Never>?
    private var ingress: AudioIngress?
    private var epoch: UInt64 = 0
    private var frames: UInt64 = 0
    private var samples: UInt64 = 0
    private var maximumSchedulerLag = 0.0
    private var recentLag = BoundedMetric(capacity: 2_048)
    private var failure: String?
    private var stopSeconds: Double?
    init(manifest: URL) throws { reader = try PacedPCMReader(manifest: manifest) }
    func start(deviceID: String?, ingress: AudioIngress) async throws { try await begin(ingress) }
    func start(selection: SystemAudioSelection, ingress: AudioIngress) async throws { try await begin(ingress) }
    private func begin(_ ingress: AudioIngress) async throws {
        epoch &+= 1; let expected = epoch
        await terminate()
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
        self.ingress = ingress
        let reader = reader
        job = Task { [weak self] in
            let clock = ContinuousClock(), origin = ContinuousClock().now
            let sourceOrigin = ProcessInfo.processInfo.systemUptime
            var sourceSamples: UInt64 = 0
            do {
                while !Task.isCancelled {
                    let representedTime = Double(sourceSamples) / 16_000
                    try await clock.sleep(until: origin.advanced(by: .seconds(representedTime)))
                    let frame = try await reader.next()
                    try Task.checkCancellation()
                    let lag = max(0, ProcessInfo.processInfo.systemUptime - sourceOrigin - representedTime)
                    ingress.offer(samples: frame, sampleRate: 16_000, timestamp: sourceOrigin + representedTime)
                    await self?.record(samples: frame.count, lag: lag)
                    sourceSamples += UInt64(frame.count)
                }
            } catch is CancellationError {} catch {
                ingress.fail("The licensed PCM fixture could not be read.")
                await self?.recordFailure("fixture_read_failed")
            }
        }
    }
    private func record(samples: Int, lag: Double) {
        frames &+= 1; self.samples += UInt64(samples)
        maximumSchedulerLag = max(maximumSchedulerLag, lag); recentLag.record(lag)
    }
    private func recordFailure(_ code: String) { failure = code }
    func snapshot() -> FixtureCaptureSnapshot {
        .init(frames: frames, samples: samples, maximumSchedulerLag: maximumSchedulerLag,
            recentLag: recentLag.snapshot, failure: failure, running: job != nil, stopSeconds: stopSeconds,
            manifestHash: reader.manifestHash, fixtureCount: reader.fixtureCount, corpusSeconds: reader.corpusSeconds)
    }
    func stop() async { epoch &+= 1; await terminate() }
    private func terminate() async {
        let began = ProcessInfo.processInfo.systemUptime
        let owned = job; job = nil
        let oldIngress = ingress; ingress = nil
        owned?.cancel(); oldIngress?.close(); await owned?.value
        do { try await reader.close() } catch { failure = "fixture_handle_close_failed" }
        if owned != nil { stopSeconds = ProcessInfo.processInfo.systemUptime - began }
    }
}

private actor SoakCredential: CredentialStoring {
    func load() -> String? { "test-only-recorded-provider" }
    func save(_ credential: String) {}
    func delete() {}
}
private actor RecordedSoakProvider: LLMProviding {
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private let budget: SharedRequestBudget
    private(set) var requests = 0
    private(set) var completions = 0
    private(set) var cancellations = 0
    private(set) var maximumJobs = 0
    init(budget: SharedRequestBudget) { self.budget = budget }
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        try Task.checkCancellation()
        try await budget.acquire()
        try Task.checkCancellation()
        guard jobs.count < 2 else { throw XAIError.localRateLimited }
        requests += 1
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            let task = Task {
                do {
                    for text in ["Use a bounded queue ", "and preserve source ordering. ", "Cancel obsolete work before publishing its result."] {
                        try await Task.sleep(for: .milliseconds(40)); try Task.checkCancellation()
                        try Self.emit(.textDelta(text), into: continuation)
                    }
                    try Self.emit(.completed, into: continuation)
                    continuation.finish(); completions += 1
                } catch {
                    if error is CancellationError || Task.isCancelled { cancellations += 1 }
                    continuation.finish(throwing: error)
                }
                jobs[id] = nil
            }
            jobs[id] = task; maximumJobs = max(maximumJobs, jobs.count)
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func emit(_ event: LLMEvent, into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued: return
        case .dropped: throw XAIError.outputBufferOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw XAIError.outputBufferOverflow
        }
    }
    func cancelAll() async {
        let owned = Array(jobs.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
    }
    var activeJobs: Int { jobs.count }
}

private struct SoakMemorySample: Codable {
    let seconds: Double
    let rssBytes: Double?
    let physicalFootprintBytes: Double?
    let segments: Int
    let ownedTasks: Int
    let localQueuedSeconds: Double?
    let remoteQueuedSeconds: Double?
    let thermalState: Int
}

private final class SoakUICredentials: CredentialStoring {
    private let accesses = Mutex(0)
    var accessCount: Int { accesses.withLock { $0 } }
    func load() -> String? { accesses.withLock { $0 += 1 }; return nil }
    func save(_ credential: String) { accesses.withLock { $0 += 1 } }
    func delete() { accesses.withLock { $0 += 1 } }
}
private final class SoakUITokens: OAuthTokenStoring {
    private let accesses = Mutex(0)
    var accessCount: Int { accesses.withLock { $0 } }
    func load() -> OAuthStoredTokens? { accesses.withLock { $0 += 1 }; return nil }
    func save(_ tokens: OAuthStoredTokens) { accesses.withLock { $0 += 1 } }
    func delete() { accesses.withLock { $0 += 1 } }
}

@MainActor private final class SoakHiddenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private struct SoakProductionViewTree: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        ShellView(model: model).frame(width: 720, height: 520)
    }
}
private struct SoakUIReport: Codable {
    let requested: Bool
    let active: Bool
    let closed: Bool
    let stateUpdates: UInt64
    let answerUpdates: UInt64
    let layoutPasses: UInt64
    let actionPanelLayouts: UInt64
    let maximumNativeTextViews: Int
    let maximumNativeTextBytes: Int
    let everVisible: Bool
    let everKey: Bool
    let everMain: Bool
    let applicationInitialized: Bool
    let applicationCredentialAccesses: Int
    let oauthTokenStoreAccesses: Int
    let preferencesFileCreated: Bool
    let temporaryStoreRemoved: Bool
    let cleanupFailed: Bool
}

/// Retains the actual production SwiftUI and AppKit text views, but deliberately never calls
/// initialize(), presents a window, installs shortcuts, or connects the UI model to live services.
@MainActor private final class SoakUIHost {
    private(set) var model: ApplicationModel?
    private var window: SoakHiddenWindow?
    private var hosting: NSHostingView<SoakProductionViewTree>?
    private let credentials = SoakUICredentials()
    private let tokens = SoakUITokens()
    private let directory: URL
    private var stateUpdates: UInt64 = 0
    private var answerUpdates: UInt64 = 0
    private var layoutPasses: UInt64 = 0
    private var actionPanelLayouts: UInt64 = 0
    private var maximumNativeTextViews = 0
    private var maximumNativeTextBytes = 0
    private var everVisible = false, everKey = false, everMain = false
    private var initialized = false, wrotePreferences = false, cleanupFailed = false
    private var temporaryStoreRemoved = false
    private var closed = false

    init(preferences: AppPreferences, presentation: PresentationCoordinator? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Freely-Soak-UI-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = NSApplication.shared // Creates AppKit infrastructure without activating the process.
        let model = ApplicationModel(store: PreferencesStore(directory: directory), credentials: credentials,
            subscription: SubscriptionAuthentication(tokens: OAuthTokenClient(store: tokens)), fetchVisualSources: { [] },
            presentation: presentation ?? PresentationCoordinator(outputMode: .memory))
        model.preferences = preferences
        model.section = .session
        model.modelReady = true
        // ready remains false: preference observers and shutdown must never persist this UI fixture.
        self.model = model
        let frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = SoakHiddenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        let hosting = NSHostingView(rootView: SoakProductionViewTree(model: model))
        hosting.frame = frame
        window.contentView = hosting
        self.window = window; self.hosting = hosting
        layout()
    }
    func record(_ state: SessionViewState) {
        guard !closed, let model else { return }
        model.session = state; stateUpdates &+= 1
    }
    func record(_ answer: AnswerPresentation, _ diagnostics: GenerationDiagnostics) {
        guard !closed, let model else { return }
        model.answerPresentation = answer; model.generationDiagnostics = diagnostics
        answerUpdates &+= 1
        layout() // Exercise incremental NativeAnswerView updates at the coordinator's batched rate.
    }
    func layout() {
        guard !closed, let model, let hosting, let window else { return }
        hosting.rootView = SoakProductionViewTree(model: model)
        hosting.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        layoutPasses &+= 1
        if model.shell.commandsVisible { actionPanelLayouts &+= 1 }
        let textViews = nativeTextViews(in: hosting)
        maximumNativeTextViews = max(maximumNativeTextViews, textViews.count)
        maximumNativeTextBytes = max(maximumNativeTextBytes, textViews.reduce(0) { $0 + $1.string.utf8.count })
        everVisible = everVisible || window.isVisible
        everKey = everKey || window.isKeyWindow
        everMain = everMain || window.isMainWindow
        initialized = initialized || model.ready
        wrotePreferences = wrotePreferences || FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path)
    }
    var isolationHeld: Bool {
        model?.presentation.window == nil && !everVisible && !everKey && !everMain && !initialized && !wrotePreferences &&
            credentials.accessCount == 0 && tokens.accessCount == 0
    }
    func presentationImage() -> CGImage? {
        guard let hosting else { return nil }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.cgImage
    }
    var renderedText: [String] { hosting.map { nativeTextViews(in: $0).map(\.string) } ?? [] }
    var textViewIdentities: Set<ObjectIdentifier> { Set(hosting.map { nativeTextViews(in: $0).map(ObjectIdentifier.init) } ?? []) }
    var report: SoakUIReport {
        .init(requested: true, active: !closed && window != nil && hosting != nil && model != nil, closed: closed,
            stateUpdates: stateUpdates, answerUpdates: answerUpdates, layoutPasses: layoutPasses, actionPanelLayouts: actionPanelLayouts,
            maximumNativeTextViews: maximumNativeTextViews, maximumNativeTextBytes: maximumNativeTextBytes,
            everVisible: everVisible, everKey: everKey, everMain: everMain, applicationInitialized: initialized,
            applicationCredentialAccesses: credentials.accessCount, oauthTokenStoreAccesses: tokens.accessCount,
            preferencesFileCreated: wrotePreferences, temporaryStoreRemoved: temporaryStoreRemoved, cleanupFailed: cleanupFailed)
    }
    func close() async {
        guard !closed else { return }
        layout()
        closed = true
        if let model {
            await model.shutdown()
            model.session = SessionViewState(); model.answerPresentation = AnswerPresentation()
            model.generationDiagnostics = GenerationDiagnostics()
        }
        if let hosting { for view in nativeTextViews(in: hosting) { view.textStorage?.setAttributedString(NSAttributedString()) } }
        window?.contentView = nil
        hosting?.removeFromSuperview()
        window?.close() // The window was never ordered, key, or main.
        window = nil; hosting = nil; model = nil
        wrotePreferences = wrotePreferences || FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path)
        do { try FileManager.default.removeItem(at: directory); temporaryStoreRemoved = true }
        catch { cleanupFailed = true }
    }
    private func nativeTextViews(in view: NSView) -> [NSTextView] {
        var values: [NSTextView] = []
        if let text = view as? NSTextView { values.append(text) }
        for child in view.subviews { values += nativeTextViews(in: child) }
        return values
    }
}

@MainActor private final class SoakRecorder {
    weak var coordinator: SessionCoordinator?
    var latest = SessionViewState()
    var maxSegments = 0, maxBytes = 0, maxTasks = 0, answers = 0, generationFailures = 0
    var maxRetainedGaps = 0
    var maximumQueue: [AudioSource: Double] = [:]
    var maximumBatch: [AudioSource: Double] = [:]
    var errors: Set<String> = []
    var uiHost: SoakUIHost?
    private var lastCompletedAnswer: GenerationID?
    private var lastFailedAnswer: GenerationID?
    func record(_ state: SessionViewState) {
        latest = state
        uiHost?.record(state)
        maxSegments = max(maxSegments, state.transcript.count)
        maxBytes = max(maxBytes, state.transcript.reduce(0) { $0 + $1.text.utf8.count })
        maxRetainedGaps = max(maxRetainedGaps, state.gapCount)
        maxTasks = max(maxTasks, coordinator?.ownedTaskCount ?? 0)
        if let error = state.error, errors.count < 16 { errors.insert(String(error.prefix(240))) }
        for (source, metrics) in state.metrics {
            maximumQueue[source] = max(maximumQueue[source, default: 0], metrics.queuedSeconds)
            maximumBatch[source] = max(maximumBatch[source, default: 0], metrics.retainedBatchSeconds)
        }
    }
    func record(_ answer: AnswerPresentation, _ diagnostics: GenerationDiagnostics) {
        uiHost?.record(answer, diagnostics)
        maxTasks = max(maxTasks, coordinator?.ownedTaskCount ?? 0)
        if let displayed = answer.displayed {
            if displayed.lifecycle == .completed, lastCompletedAnswer != displayed.id { answers += 1; lastCompletedAnswer = displayed.id }
            if displayed.error != nil, lastFailedAnswer != displayed.id { generationFailures += 1; lastFailedAnswer = displayed.id }
        }
    }
}

@Suite(.serialized)
struct IntegratedSoakTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_SOAK"] == "1", "Opt-in cached-model paced run"))
    @MainActor func realTimeDualSourceLocalProcessing() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let seconds = min(14_400, max(10, Int(environment["FREELY_SOAK_SECONDS"] ?? "60") ?? 60))
        let defaultCorpus = root.appendingPathComponent("Benchmarks/STT/.cache/paired-corpus-v1")
        let corpus = URL(fileURLWithPath: environment["FREELY_SOAK_CORPUS"] ?? defaultCorpus.path)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: root.appendingPathComponent("Freely/Resources/model-manifest.json")))
        let modelRoot = URL(fileURLWithPath: environment["FREELY_SOAK_MODELS"] ?? PreferencesStore.defaultDirectory.appendingPathComponent("Models").path)
        let installer = try ModelInstaller(root: modelRoot, manifest: manifest)
        _ = try await installer.verifiedInstallation()
        let cache = LocalSpeechModelCache(installer: installer)
        let local = try PacedFixtureCapture(manifest: corpus.appendingPathComponent("localUser.json"))
        let remote = try PacedFixtureCapture(manifest: corpus.appendingPathComponent("systemAudio.json"))
        let budget = SharedRequestBudget(), provider = RecordedSoakProvider(budget: budget)
        let recorder = SoakRecorder()
        let coordinator = SessionCoordinator(credentials: SoakCredential(), rateBudget: budget,
            microphone: local, system: remote, makeTranscriber: { source in try await cache.transcriber(for: source) },
            makeProvider: { _, _ in provider }, onState: recorder.record, onAnswer: recorder.record)
        recorder.coordinator = coordinator
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Freely opt-in paced local-processing benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var preferences = AppPreferences()
        preferences.audio.systemScope = .allSystemAudio
        preferences.ai.experimentalSpeculation = false
        let uiRequested = environment["FREELY_SOAK_UI"] == "1"
        let presentationRequested = environment["FREELY_SOAK_PRESENTATION"] == "1"
        let nativeCapture = environment["FREELY_SOAK_NATIVE_CAPTURE"] == "1"
        let fixtureStream = presentationRequested && !nativeCapture ? try FixturePresentationStream(repeats: true) : nil
        let output = fixtureStream?.coordinator() ?? PresentationCoordinator(outputMode: .memory)
        if uiRequested { recorder.uiHost = try SoakUIHost(preferences: preferences, presentation: output) }
        let presentation = presentationRequested ? recorder.uiHost?.model?.presentation : nil
        if presentationRequested {
            let presentation = try #require(presentation, "Presentation workload requires FREELY_SOAK_UI=1")
            if nativeCapture {
                await presentation.refreshSources()
                let fixture = try #require(presentation.sources.first { $0.application == "local.freely.capture-fixture" && $0.name.contains("Freely capture fixture — public test content") }, "Native capture is opt-in and requires the public CaptureFixture window")
                presentation.sourceID = fixture.id
            }
            presentation.loadPreview(); await presentation.waitForPendingOperations()
            #expect(presentation.preview != nil)
            presentation.panelImage = { [weak host = recorder.uiHost] in host?.presentationImage() }
            presentation.setPanelVisible(true); presentation.setShowPanel(true)
            presentation.prepare(); await presentation.waitForPendingOperations()
            #expect(presentation.active)
            #expect(presentation.window == nil, "A workload must never open an output window")
        }
        var memory: [SoakMemorySample] = []
        var began: Double?
        var failure: SoakFailure?
        var completedDuration = false
        var preparationPeakRSS = Self.rss()
        var preparationPeakFootprint = Self.footprint()
        let initialThermal = ProcessInfo.processInfo.thermalState.rawValue
        let preparationBegan = ProcessInfo.processInfo.systemUptime
        coordinator.start(preferences: preferences, sessionNotes: "", pinnedFacts: "", transcriptionOnly: false)
        do {
            while coordinator.phase == .preparing {
                recorder.uiHost?.layout()
                guard recorder.uiHost?.isolationHeld != false else { throw SoakFailure.uiIsolationViolation }
                if let rss = Self.rss() { preparationPeakRSS = max(preparationPeakRSS ?? rss, rss) }
                if let footprint = Self.footprint() { preparationPeakFootprint = max(preparationPeakFootprint ?? footprint, footprint) }
                guard ProcessInfo.processInfo.systemUptime - preparationBegan < 60 else { throw SoakFailure.preparationTimeout }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard coordinator.phase == .running,
                  AudioSource.allCases.allSatisfy({ recorder.latest.sources[$0] == .running }) else { throw SoakFailure.sourceUnavailable }
            let clock = ContinuousClock(), origin = ContinuousClock().now
            let start = ProcessInfo.processInfo.systemUptime; began = start
            let deadline = origin.advanced(by: .seconds(seconds))
            var nextSecond = 1, nextSample = 0.0, nextLog = 0.0
            while clock.now < deadline {
                try Task.checkCancellation()
                recorder.uiHost?.layout()
                guard recorder.uiHost?.isolationHeld != false else { throw SoakFailure.uiIsolationViolation }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if let ui = recorder.uiHost?.model {
                    ui.shell.commandsVisible = Int(elapsed) % 20 >= 10
                    ui.shell.commandSearch = Int(elapsed) % 60 >= 40 ? "source" : ""
                    if ui.shell.commandsVisible { ui.handlePopupKey(125) }
                }
                guard !presentationRequested || presentation?.active == true else { throw SoakFailure.sourceUnavailable }
                guard coordinator.phase == .running,
                      AudioSource.allCases.allSatisfy({ recorder.latest.sources[$0] == .running }) else { throw SoakFailure.sourceUnavailable }
                recorder.maxTasks = max(recorder.maxTasks, coordinator.ownedTaskCount)
                if elapsed >= nextSample {
                    memory.append(Self.memorySample(seconds: elapsed, recorder: recorder, coordinator: coordinator))
                    nextSample = (floor(elapsed / 30) + 1) * 30
                    if memory.count > 481 { memory.removeFirst() }
                }
                if elapsed >= nextLog {
                    FileHandle.standardError.write(Data("SOAK elapsed=\(Int(elapsed))s segments=\(recorder.latest.transcript.count) tasks=\(coordinator.ownedTaskCount) retainedGaps=\(recorder.latest.gapCount) presentationActive=\(presentation?.active ?? false) publishedFrames=\(presentation?.publishedCount ?? 0)\n".utf8))
                    nextLog = (floor(elapsed / 60) + 1) * 60
                }
                try await clock.sleep(until: min(deadline, origin.advanced(by: .seconds(nextSecond))))
                nextSecond = Int(ProcessInfo.processInfo.systemUptime - start) + 1
            }
            completedDuration = true
        } catch is CancellationError { failure = .cancelled }
        catch { failure = (error as? SoakFailure) ?? .runFailure }

        // Capture all final resident metrics while the session is still running. Keep only counts,
        // not a transcript array that would bias post-stop memory or retain meeting content.
        let finalElapsed = began.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        recorder.uiHost?.layout()
        let uiBeforeStop = recorder.uiHost?.report
        let finalMemory = Self.memorySample(seconds: finalElapsed, recorder: recorder, coordinator: coordinator)
        memory.append(finalMemory)
        if memory.count > 482 { memory.removeFirst() }
        let sourceMetrics = recorder.latest.metrics
        let finalSegments = recorder.latest.transcript.count
        let sourceSegmentCounts = Dictionary(uniqueKeysWithValues: AudioSource.allCases.map { source in
            (source.rawValue, recorder.latest.transcript.filter { $0.source == source }.count)
        })
        let finalThermal = ProcessInfo.processInfo.thermalState.rawValue
        let presentationMetrics: [String: Any] = [
            "requested": presentationRequested, "activeBeforeStop": presentation?.active ?? false,
            "stateBeforeStop": presentation?.state ?? "Not requested",
            "receivedFrames": presentation?.receivedCount ?? 0, "publishedFrames": presentation?.publishedCount ?? 0,
            "maximumRenderSeconds": presentation?.maximumRenderSeconds ?? 0,
            "source": nativeCapture ? "Explicit public CaptureFixture window; ScreenCaptureKit stream" : "Synthetic immutable in-memory frames; no ScreenCaptureKit or desktop access",
            "outputWindowCreated": presentation?.window != nil,
            "panelLayer": "Hidden production SwiftUI/AppKit workload host; test callback captures its native views"
        ]
        let presentationPassed = !presentationRequested || (presentation?.active == true && (presentation?.receivedCount ?? 0) > 0 && (presentation?.publishedCount ?? 0) > 0)
        presentation?.sessionEnded()
        let stopStart = ProcessInfo.processInfo.systemUptime
        await coordinator.stop() // Runs after success, timeout, source failure, or task cancellation.
        let coordinatorStopSeconds = ProcessInfo.processInfo.systemUptime - stopStart
        let uiCloseBegan = ProcessInfo.processInfo.systemUptime
        await recorder.uiHost?.close()
        let uiCloseSeconds = uiRequested ? ProcessInfo.processInfo.systemUptime - uiCloseBegan : nil
        let stopSeconds = ProcessInfo.processInfo.systemUptime - stopStart
        let postStopRSS = Self.rss()
        let uiAfterStop = recorder.uiHost?.report
        let captures = [AudioSource.localUser: await local.snapshot(), .systemAudio: await remote.snapshot()]
        let warmAt = min(600, Double(seconds) / 3)
        let warmSample = memory.first { $0.seconds >= warmAt && $0.rssBytes != nil }
        let growth = warmSample?.rssBytes.flatMap { warm in finalMemory.rssBytes.map { $0 - warm } }
        let growthLimit = warmSample?.rssBytes.map { max(128 * 1_024 * 1_024, $0 * 0.05) }
        let rssPeak = (memory.compactMap(\.rssBytes) + [preparationPeakRSS].compactMap { $0 }).max()
        let footprintPeak = (memory.compactMap(\.physicalFootprintBytes) + [preparationPeakFootprint].compactMap { $0 }).max()
        let providerActive = await provider.activeJobs
        let validSources = sourceMetrics.count == 2 && AudioSource.allCases.allSatisfy { source in
            sourceMetrics[source]?.receivedFrames ?? 0 > 0 && sourceMetrics[source]?.droppedSeconds == 0 &&
            sourceSegmentCounts[source.rawValue, default: 0] > 0 && captures[source]?.failure == nil && captures[source]?.running == false
        }
        let uiPassed = !uiRequested || (uiBeforeStop?.active == true && (uiBeforeStop?.layoutPasses ?? 0) > 0 &&
            (uiBeforeStop?.maximumNativeTextViews ?? 0) >= 2 && recorder.uiHost?.isolationHeld == true &&
            uiAfterStop?.closed == true && uiAfterStop?.temporaryStoreRemoved == true && uiAfterStop?.cleanupFailed == false)
        let passed = presentationPassed && failure == nil && completedDuration && recorder.errors.isEmpty && validSources && uiPassed &&
            recorder.maxRetainedGaps == 0 && recorder.maxSegments <= 2_000 && recorder.maxBytes <= 2 * 1_024 * 1_024 &&
            coordinator.ownedTaskCount == 0 && providerActive == 0 && stopSeconds < 2 &&
            (rssPeak.map { $0 <= 4 * 1_024 * 1_024 * 1_024 } ?? false) &&
            (growth.flatMap { value in growthLimit.map { value <= $0 } } ?? false)
        func json(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
        var sourceReports: [String: Any] = [:]
        for source in AudioSource.allCases {
            guard let capture = captures[source] else { continue }
            let metrics = sourceMetrics[source]
            let audioSeconds = Double(capture.samples) / 16_000
            sourceReports[source.rawValue] = [
                "framesOffered": capture.frames, "samplesOffered": capture.samples, "audioSecondsOffered": audioSeconds,
                "framesReceivedAtLastMonitor": metrics?.receivedFrames as Any? ?? NSNull(),
                "droppedSeconds": json(metrics?.droppedSeconds), "maximumObservedQueueSeconds": recorder.maximumQueue[source, default: 0],
                "maximumObservedBatchSeconds": recorder.maximumBatch[source, default: 0],
                "processingSeconds": json(metrics?.processingSeconds), "decodedAudioSeconds": json(metrics?.analysisSeconds),
                "decodedAudioRTF": json(metrics?.realTimeFactor),
                "offeredAudioRTF": json(metrics.map { $0.processingSeconds / max(0.001, audioSeconds) }),
                "schedulerLagMaximumSeconds": capture.maximumSchedulerLag,
                "recentSchedulerLagP50Seconds": json(capture.recentLag.p50), "recentSchedulerLagP95Seconds": json(capture.recentLag.p95),
                "schedulerLagSamplesRetained": capture.recentLag.retainedSamples,
                "fixtureCaptureStopSeconds": json(capture.stopSeconds), "fixtureFailure": capture.failure as Any? ?? NSNull(),
                "fixtureCount": capture.fixtureCount, "corpusSeconds": capture.corpusSeconds, "fixtureManifestSHA256": capture.manifestHash
            ]
        }
        let memoryObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory))
        let uiObject: Any = try uiAfterStop.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            ?? ["requested": false, "active": false]
        let raw: [String: Any] = [
            "schemaVersion": 3, "status": passed ? "passed" : failure == .cancelled ? "cancelled" : "failed",
            "kind": "real-time paced local inference in test process; recorded LLM; fixture capture",
            "requestedDurationSeconds": seconds, "processingDurationSeconds": finalElapsed, "completedRequestedDuration": completedDuration,
            "failureCode": failure?.rawValue as Any? ?? NSNull(), "preparationAndProcessingSeconds": stopStart - preparationBegan,
            "machine": Self.systemString("machdep.cpu.brand_string") as Any? ?? NSNull(),
            "hardwareModel": Self.systemString("hw.model") as Any? ?? NSNull(),
            "logicalCPUCount": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": "arm64",
            "modelRevision": manifest.revision, "model": manifest.name, "adapter": manifest.adapter, "adapterVersion": manifest.adapterVersion,
            "corpusProvenance": corpus.standardizedFileURL == defaultCorpus.standardizedFileURL ? "AMI EN2001a independent headset sources; CC-BY-4.0; Benchmarks/STT/dual-corpus-manifest.json" : "Explicitly supplied external corpus; license provenance not verified by this harness",
            "maxRetainedSegments": recorder.maxSegments, "maxTranscriptBytes": recorder.maxBytes, "maxObservedOwnedTasks": recorder.maxTasks,
            "retainedFinalSegments": finalSegments, "retainedSegmentsBySource": sourceSegmentCounts,
            "answersObserved": recorder.answers, "generationFailuresObserved": recorder.generationFailures,
            "recordedProviderRequests": await provider.requests, "recordedProviderCompletions": await provider.completions,
            "recordedProviderCancellations": await provider.cancellations, "recordedProviderMaximumJobs": await provider.maximumJobs,
            "maxRetainedGapRecords": recorder.maxRetainedGaps, "redactedSessionErrors": Array(recorder.errors).sorted(),
            "warmReferenceTargetSeconds": warmAt, "warmReferenceActualSeconds": json(warmSample?.seconds),
            "rssWarmBytes": json(warmSample?.rssBytes), "rssFinalBeforeStopBytes": json(finalMemory.rssBytes),
            "rssGrowthBytes": json(growth), "rssAfterStopBytes": json(postStopRSS),
            "sampledRSSPeakBytes": json(rssPeak), "sampledPhysicalFootprintPeakBytes": json(footprintPeak),
            "preparationSampledRSSPeakBytes": json(preparationPeakRSS), "preparationSampledPhysicalFootprintPeakBytes": json(preparationPeakFootprint),
            "presentation": presentationMetrics,
            "thermalStart": initialThermal, "thermalEndBeforeStop": finalThermal,
            "stopSeconds": stopSeconds, "ownedTasksAfterStop": coordinator.ownedTaskCount,
            "coordinatorStopSeconds": coordinatorStopSeconds, "uiCloseSeconds": json(uiCloseSeconds),
            "uiHostActiveDuringRun": uiBeforeStop?.active ?? false, "uiHost": uiObject,
            "recordedProviderJobsAfterStop": providerActive, "idleCachedSourceModelsAfterStop": await cache.cachedSourceCount,
            "sourceMetrics": sourceReports, "memorySamples": memoryObject,
            "limits": ["maximumTranscriptSegments": 2_000, "maximumTranscriptBytes": 2_097_152,
                "maximumRSSBytes": 4_294_967_296.0, "additionalGrowthBytes": growthLimit ?? 134_217_728,
                "normalTeardownSeconds": 2, "maximumMemorySamples": 482],
            "limitations": [presentationRequested ? "Paced synthetic PCM, real local STT and a recorded answer provider. Video uses synthetic frames unless native capture was explicitly selected. No live microphone, live Grok, recipient call or semantic-quality acceptance." : "No live microphone, ScreenCaptureKit capture, Grok/OAuth connection, provider latency or semantic quality is exercised.",
                uiRequested ? "Production SetupView and NativeAnswerView retain actual coordinator state in a hidden NSWindow inside the test process; this is not a proper app-bundle launch, visible rendering/focus test, or UI interaction test." : "Memory is sampled in a test process running the production coordinators and STT without a UI host, not the native UI app bundle.",
                "A warm immutable model cache remains resident after stop. Framework-internal housekeeping tasks are not enumerated.",
                "Scheduler percentiles describe the latest2048 feed events per source; maximum covers the full run.",
                "Final monitor frame counts can lag the feeder by at most its100ms sampling interval; stop intentionally releases queued tail audio."]
        ]
        let directory = root.appendingPathComponent("Benchmarks/results")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(environment["FREELY_SOAK_RESULT_NAME"] ?? "\(presentationRequested ? "presentation" : "integrated")-soak-\(seconds)s.json"), options: .atomic)
        #expect(passed, "Inspect the redacted integrated-soak JSON; all owned services were stopped before evaluating acceptance.")
    }
    @MainActor private static func memorySample(seconds: Double, recorder: SoakRecorder, coordinator: SessionCoordinator) -> SoakMemorySample {
        .init(seconds: seconds, rssBytes: rss(), physicalFootprintBytes: footprint(), segments: recorder.latest.transcript.count,
            ownedTasks: coordinator.ownedTaskCount, localQueuedSeconds: recorder.latest.metrics[.localUser]?.queuedSeconds,
            remoteQueuedSeconds: recorder.latest.metrics[.systemAudio]?.queuedSeconds, thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }
    private static func rss() -> Double? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.resident_size) : nil
    }
    private static func footprint() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : nil
    }
    private static func systemString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 512 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct SoakFixtureReaderTests {
    @Test @MainActor func hiddenProductionUIRetainsUpdatesWithoutActivationOrApplicationPersistence() async throws {
        let host = try SoakUIHost(preferences: AppPreferences())
        var state = SessionViewState(phase: .running)
        state.sources = [.localUser: .running, .systemAudio: .running]
        state.transcript = [.init(source: .systemAudio, sequence: 1, startTime: 0, endTime: 1,
                                  text: "A synthetic UI-only transcript fixture")]
        let question = QuestionState(text: "Explain the retained UI state")
        let identity = GenerationIdentity(sessionEpoch: .init(1), questionID: question.id, questionRevision: question.revision)
        var answer = AnswerPresentation()
        answer.begin(identity: identity, question: question)
        answer.append("A synthetic answer", identity: identity)
        host.record(state); host.record(answer, GenerationDiagnostics(status: "Streaming")); host.layout()
        do {
            for _ in 0..<10 { await Task.yield(); host.layout() }
            #expect(host.renderedText.filter { $0 == "A synthetic answer" }.count == 1)
            let textViewIDs = host.textViewIdentities
            answer.append("\n```swift\nlet retained = true\n```", identity: identity)
            answer.finish(identity: identity, lifecycle: .completed)
            host.record(answer, GenerationDiagnostics(status: "Completed"))
            for _ in 0..<10 { try Task.checkCancellation(); await Task.yield(); host.layout() }
            #expect(host.renderedText.contains { $0.contains("let retained = true") })
            #expect(host.textViewIdentities == textViewIDs)
            #expect(host.model?.session.transcript.count == 1)
            #expect(host.report.active && host.report.maximumNativeTextViews >= 2)
            #expect(host.isolationHeld)
            await host.close()
        } catch { await host.close(); throw error }
        let result = host.report
        #expect(result.closed && !result.active && result.temporaryStoreRemoved && !result.cleanupFailed)
        #expect(result.applicationCredentialAccesses == 0 && result.oauthTokenStoreAccesses == 0)
        #expect(!result.preferencesFileCreated && !result.applicationInitialized)
        #expect(!result.everVisible && !result.everKey && !result.everMain)
        #expect(host.model == nil && host.renderedText.isEmpty)
        await host.close()
    }

    @Test func exactFramesCrossFileBoundariesWithoutPaddingOrLostTailSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Freely-PacedReader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Fixture cleanup failed") } }
        let values: [[Float]] = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6, 0.7]]
        var fixtures: [ReplayFixture] = []
        for (index, samples) in values.enumerated() {
            var data = Data()
            for sample in samples { var bits = sample.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
            let file = "fixture-\(index).f32"; try data.write(to: directory.appendingPathComponent(file))
            fixtures.append(.init(file: file, duration: Double(samples.count) / 16_000,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = directory.appendingPathComponent("source.json")
        try JSONEncoder().encode(fixtures).write(to: manifest)
        let reader = try PacedPCMReader(manifest: manifest)
        #expect(try await reader.next(sampleCount: 5) == [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(try await reader.next(sampleCount: 5) == [0.6, 0.7, 0.1, 0.2, 0.3])
        try await reader.close()
    }
    @Test func emptyAndCorruptFixturesFailBeforePacedCaptureStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Freely-InvalidReader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Fixture cleanup failed") } }
        let manifest = directory.appendingPathComponent("source.json")
        try JSONEncoder().encode([ReplayFixture]()).write(to: manifest)
        #expect(throws: SoakFailure.self) { try PacedPCMReader(manifest: manifest) }
        try Data().write(to: directory.appendingPathComponent("empty.f32"))
        try JSONEncoder().encode([ReplayFixture(file: "empty.f32", duration: 1, sha256: String(repeating: "0", count: 64))]).write(to: manifest)
        #expect(throws: SoakFailure.self) { try PacedPCMReader(manifest: manifest) }
    }
}
