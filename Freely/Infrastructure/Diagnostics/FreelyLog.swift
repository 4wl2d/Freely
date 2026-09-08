import FreelyCore
import Foundation
import ScreenCaptureKit
import os

enum DiagnosticLevel: String, Codable, CaseIterable, Sendable {
    case debug, info, warning, error
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

/// Closed names and field keys prevent payloads from becoming messages or metric keys.
enum DiagnosticName: String, Codable, CaseIterable, Sendable {
    case appLaunched = "app.launched", appReady = "app.ready", appStopping = "app.stopping", appStopped = "app.stopped"
    case operationFailed = "app.operation_failed", errorPresented = "app.error_presented"
    case debugOpened = "debug.opened", debugMarker = "debug.marker"
    case sessionStarted = "session.started", sessionReady = "session.ready", sessionStopping = "session.stopping", sessionStopped = "session.stopped"
    case sourceSummary = "audio.source_summary", sourceState = "audio.source_state", sourceFailed = "audio.source_failed", audioStarted = "audio.started", audioStopped = "audio.stopped", audioGap = "audio.gap"
    case decodeCompleted = "stt.decode_completed", decodeFailed = "stt.decode_failed"
    case transcriptFinal = "transcript.final", contextPrepared = "context.prepared", contextInvalidated = "context.invalidated", summaryFinished = "context.summary_finished"
    case generationStarted = "llm.generation_started", generationFirstText = "llm.first_visible_text", generationCompleted = "llm.generation_completed", generationIncomplete = "llm.generation_incomplete", generationCancelled = "llm.generation_cancelled", generationFailed = "llm.generation_failed"
    case requestCancelled = "network.request_cancelled", requestStarted = "network.request_started", responseReceived = "network.response_received", requestFinished = "network.request_finished", requestFailed = "network.request_failed", requestRetry = "network.retry"
    case permissionChecked = "permissions.checked", screenChanged = "screen.changed", screenCaptured = "screen.captured"
    case modelStarted = "model.install_started", modelInstalled = "model.installed", modelCancelled = "model.install_cancelled", modelCleanupFailed = "model.cleanup_failed"
    case authStarted = "auth.started", authConnected = "auth.connected", authCancelled = "auth.cancelled", authFailed = "auth.failed", authDisconnected = "auth.disconnected"
    case overlayVisibility = "overlay.visibility", overlayInteraction = "overlay.interaction"
    var category: String { String(rawValue.split(separator: ".")[0]) }
}

enum DiagnosticField: String, Sendable {
    case state, source, epoch, revision, count, bytes, width, height, enabled, ready, connected
    case inputTokens, outputTokens, cachedTokens, visual, manual, speculative, final, empty
    case attempt, httpStatus, delaySeconds, durationSeconds, failure, transcriptionOnly
    case segmentID, questionID, contextID, reason, droppedSeconds, frames, queuedSeconds, realTimeFactor
}

/// No arbitrary String initializer. Never pass localizedDescription or userInfo.
struct DiagnosticValue: Sendable {
    let text: String
    private init(_ text: String) { self.text = text }
    static func state(_ value: StaticString) -> Self { .init(value.description) }
    static func int<T: BinaryInteger>(_ value: T) -> Self { .init(String(value)) }
    static func number(_ value: Double) -> Self { .init(value.isFinite ? String(value) : "unavailable") }
    static func flag(_ value: Bool) -> Self { .init(value ? "true" : "false") }
    static func id(_ value: UUID) -> Self { .init(value.uuidString) }
    static func gapCause(_ value: AudioDiscontinuity.Cause) -> Self { .init(value.rawValue) }
    static func source(_ source: AudioSource) -> Self { .init(source.rawValue) }
    static func failure(_ error: any Error) -> Self {
        if error is CancellationError { return .state("cancelled") }
        if let error = error as? XAIError {
            switch error {
            case .unauthorized(let code): return .init("xai.unauthorized.\(code)")
            case .server(let code): return .init("xai.server.\(code)")
            case .rejected(let code): return .init("xai.rejected.\(code)")
            case .rateLimited: return .state("xai.rate_limited")
            case .missingCredential: return .state("xai.missing_credential")
            case .invalidConfiguration: return .state("xai.invalid_configuration")
            case .contextTooLarge: return .state("xai.context_too_large")
            case .invalidImage: return .state("xai.invalid_image")
            case .localRateLimited: return .state("xai.local_rate_limited")
            case .offline: return .state("xai.offline")
            case .network: return .state("xai.network")
            case .firstOutputTimeout: return .state("xai.first_output_timeout")
            case .inactivityTimeout: return .state("xai.inactivity_timeout")
            case .deadlineExceeded: return .state("xai.deadline_exceeded")
            case .malformedStream: return .state("xai.malformed_stream")
            case .earlyEOF: return .state("xai.early_eof")
            case .providerFailure: return .state("xai.provider_failure")
            case .outputBufferOverflow: return .state("xai.output_buffer_overflow")
            }
        }
        if let error = error as? AudioCaptureError {
            switch error {
            case .denied: return .state("audio.permission_denied")
            case .noDevice: return .state("audio.no_device")
            case .noApplication: return .state("audio.no_application")
            case .invalidFormat: return .state("audio.invalid_format")
            case .configuration: return .state("audio.configuration")
            }
        }
        if let error = error as? ModelInstallError {
            switch error {
            case .invalidManifest: return .state("model.invalid_manifest")
            case .insufficientSpace: return .state("model.insufficient_space")
            case .downloadFailed: return .state("model.download_failed")
            case .sizeMismatch: return .state("model.size_mismatch")
            case .checksumMismatch: return .state("model.checksum_mismatch")
            case .notInstalled: return .state("model.not_installed")
            case .busy: return .state("model.busy")
            case .publicationFailed: return .state("model.publication_failed")
            case .unsafeFile: return .state("model.unsafe_file")
            case .storageUnavailable: return .state("model.storage_unavailable")
            }
        }
        if let error = error as? GrokBuildError {
            switch error {
            case .notInstalled: return .state("grok_build.not_installed")
            case .signInRequired: return .state("grok_build.sign_in_required")
            case .signInFailed: return .state("grok_build.sign_in_failed")
            case .modelUnavailable: return .state("grok_build.model_unavailable")
            case .invalidResponse: return .state("grok_build.invalid_response")
            case .incompatibleRuntime: return .state("grok_build.incompatible_runtime")
            case .requestFailed: return .state("grok_build.request_failed")
            case .timedOut: return .state("grok_build.timed_out")
            case .outputTooLarge: return .state("grok_build.output_too_large")
            }
        }
        if let error = error as? OAuthError {
            switch error {
            case .registrationRequired: return .state("oauth.registration_required")
            case .invalidConfiguration: return .state("oauth.invalid_configuration")
            case .randomFailure: return .state("oauth.random_failure")
            case .invalidDiscovery: return .state("oauth.invalid_discovery")
            case .invalidCallback: return .state("oauth.invalid_callback")
            case .denied: return .state("oauth.denied")
            case .malformedResponse: return .state("oauth.malformed_response")
            case .expired: return .state("oauth.expired")
            case .unavailable: return .state("oauth.unavailable")
            case .clientRejected: return .state("oauth.client_rejected")
            case .scopeUnavailable: return .state("oauth.scope_unavailable")
            case .disconnected: return .state("oauth.disconnected")
            case .timedOut: return .state("oauth.timed_out")
            case .localDeletionFailed: return .state("oauth.local_deletion_failed")
            case .revocationUnconfirmed: return .state("oauth.revocation_unconfirmed")
            }
        }
        if let error = error as? ScreenCaptureFailure {
            switch error {
            case .disabled: return .state("screen.disabled")
            case .noSelection: return .state("screen.no_selection")
            case .unavailable: return .state("screen.unavailable")
            case .stale: return .state("screen.stale")
            case .invalidRegion: return .state("screen.invalid_region")
            case .tooLarge: return .state("screen.too_large")
            case .encoding: return .state("screen.encoding")
            }
        }
        let native = error as NSError
        let allowed = [SCStreamErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain]
        let domain = allowed.contains(native.domain) ? native.domain : "other"
        return .init("\(domain).\(native.code)")
    }
}

struct DiagnosticScope: Codable, Sendable {
    var session: UUID?
    var request: UUID?
    var source: AudioSource?
}

struct DiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UInt64
    let date: Date
    let uptime: Double
    let level: DiagnosticLevel
    let name: DiagnosticName
    let scope: DiagnosticScope
    let fields: [String: String]
    var details: String { fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: "  ") }
    var searchableText: String {
        [name.rawValue, details, scope.session?.uuidString ?? "", scope.request?.uuidString ?? "", scope.source?.rawValue ?? ""].joined(separator: " ")
    }
    func matches(search: String, minimumLevel: DiagnosticLevel, category: String) -> Bool {
        level.rank >= minimumLevel.rank && (category.isEmpty || name.category == category) &&
            (search.isEmpty || searchableText.localizedCaseInsensitiveContains(search))
    }
}

struct DiagnosticTiming: Codable, Identifiable, Sendable {
    var id: DiagnosticName { name }
    let name: DiagnosticName
    let count: UInt64
    let retainedSamples: Int
    let p50: Double?
    let p95: Double?
    let maximum: Double?
}

struct DiagnosticSnapshot: Codable, Sendable {
    let runID: UUID
    let startedAt: Date
    let capacity: Int
    let totalRecorded: UInt64
    let evicted: UInt64
    let suppressedDebug: UInt64
    let verbose: Bool
    let counts: [String: UInt64]
    let events: [DiagnosticEvent]
    let timings: [DiagnosticTiming]
}

/// Fixed memory, O(1) insertion, no disk I/O or Task allocation on the producer.
/// Use control/worker paths, never an audio callback. UI snapshots only while visible.
final class DiagnosticRecorder: Sendable {
    private struct State {
        var ring: [DiagnosticEvent] = []
        var cursor = 0
        var nextID: UInt64 = 0
        var total: UInt64 = 0
        var suppressed: UInt64 = 0
        var verbose = false
        var counts: [String: UInt64] = [:]
        var timings: [DiagnosticName: BoundedMetric] = [:]
    }
    let runID = UUID()
    let startedAt = Date()
    let capacity: Int
    private let storage: OSAllocatedUnfairLock<State>
    init(capacity: Int = 2_000, verbose: Bool = false) {
        self.capacity = max(1, min(10_000, capacity))
        storage = OSAllocatedUnfairLock(initialState: State(verbose: verbose))
    }
    func setVerbose(_ enabled: Bool) { storage.withLock { $0.verbose = enabled } }
    @discardableResult
    func record(_ name: DiagnosticName, level: DiagnosticLevel = .info, scope: DiagnosticScope = .init(),
                fields: [DiagnosticField: DiagnosticValue] = [:], duration: Double? = nil) -> DiagnosticEvent? {
        storage.withLock { state in
            if let duration, duration.isFinite, duration >= 0 {
                state.timings[name, default: BoundedMetric(capacity: 256)].record(duration)
            }
            guard level != .debug || state.verbose else { state.suppressed &+= 1; return nil }
            state.nextID &+= 1; state.total &+= 1
            state.counts[level.rawValue, default: 0] &+= 1
            var safeFields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value.text) })
            if let duration { safeFields[DiagnosticField.durationSeconds.rawValue] = DiagnosticValue.number(duration).text }
            let event = DiagnosticEvent(id: state.nextID, date: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                level: level, name: name, scope: scope, fields: safeFields)
            if state.ring.count < capacity { state.ring.append(event) }
            else { state.ring[state.cursor] = event; state.cursor = (state.cursor + 1) % capacity }
            return event
        }
    }
    func snapshot() -> DiagnosticSnapshot {
        let state = storage.withLock { $0 }
        let ordered = Array(state.ring[state.cursor...]) + Array(state.ring[..<state.cursor])
        let timings = state.timings.keys.sorted { $0.rawValue < $1.rawValue }.map { name in
            let metric = state.timings[name]!.snapshot
            return DiagnosticTiming(name: name, count: metric.count, retainedSamples: metric.retainedSamples,
                p50: metric.p50, p95: metric.p95, maximum: metric.maximum)
        }
        return DiagnosticSnapshot(runID: runID, startedAt: startedAt, capacity: capacity, totalRecorded: state.total,
            evicted: state.total - UInt64(ordered.count), suppressedDebug: state.suppressed, verbose: state.verbose,
            counts: state.counts, events: ordered, timings: timings)
    }
    func clear() {
        storage.withLock { state in
            // Never reuse IDs while a selection or previously exported report exists.
            state = State(nextID: state.nextID, verbose: state.verbose)
        }
    }
}

enum FreelyLog {
    static let subsystem = "local.freely.app"
    static let recorder = DiagnosticRecorder()
    private static let loggers = Dictionary(uniqueKeysWithValues:
        Set(DiagnosticName.allCases.map(\.category)).map { ($0, Logger(subsystem: subsystem, category: $0)) })
    static func record(_ name: DiagnosticName, level: DiagnosticLevel = .info, scope: DiagnosticScope = .init(),
                       fields: [DiagnosticField: DiagnosticValue] = [:], duration: Double? = nil) {
        guard let event = recorder.record(name, level: level, scope: scope, fields: fields, duration: duration),
              let logger = loggers[name.category] else { return }
        let line = "run=\(recorder.runID.uuidString) seq=\(event.id) \(event.name.rawValue) session=\(scope.session?.uuidString ?? "-") request=\(scope.request?.uuidString ?? "-") source=\(scope.source?.rawValue ?? "-") \(event.details)"
        switch level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.notice("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }
}
