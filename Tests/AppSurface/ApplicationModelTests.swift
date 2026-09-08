import AppKit
import FreelyCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import Freely

private actor AppSurfaceCredentials: CredentialStoring {
    private(set) var writes = 0
    func load() -> String? { nil }
    func save(_ credential: String) { writes += 1 }
    func delete() {}
}
private actor SurfaceSourceGate {
    private var continuation: CheckedContinuation<[VisualSource], Never>?
    private(set) var started = false
    func fetch() async -> [VisualSource] { started = true; return await withCheckedContinuation { continuation = $0 } }
    func release(_ values: [VisualSource]) { continuation?.resume(returning: values); continuation = nil }
}

@MainActor struct ApplicationModelTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FreelySurfaceTests-\(UUID().uuidString)", isDirectory: true) }
    private func model(directory: URL, loader: @escaping @Sendable () async throws -> [VisualSource] = { [] }) -> ApplicationModel {
        ApplicationModel(store: PreferencesStore(directory: directory), credentials: AppSurfaceCredentials(),
            subscription: SubscriptionAuthentication(tokens: OAuthTokenClient(store: MemoryOAuthTokenStore())), fetchVisualSources: loader)
    }
    private func sources() -> [VisualSource] {
        [1, 2].map { .init(id: "display:\($0)", kind: .display, nativeID: UInt32($0), name: "Synthetic display \($0)", application: nil, width: 1_920, height: 1_080) }
    }
    private func cleanup(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    @Test func cancellingRegionChangePreservesExistingCrop() async throws {
        let directory = directory(), model = model(directory: directory)
        model.session.phase = .running; model.screenMode = .manual
        model.visualSources = sources(); model.selectedVisualID = "display:1"
        let original = CGRect(x: 100, y: 100, width: 500, height: 400)
        model.visualRegion = original
        model.chooseRegion = { _, completion in completion(nil) }
        model.selectRegion()
        #expect(model.visualRegion == original)
        await model.shutdown(); try cleanup(directory)
    }

    @Test func regionCallbackCannotMoveOldDisplayCropToNewSelection() async throws {
        let directory = directory(), model = model(directory: directory)
        model.session.phase = .running; model.screenMode = .manual
        model.visualSources = sources(); model.selectedVisualID = "display:1"
        var pending: ((CGRect?) -> Void)?
        model.chooseRegion = { _, completion in pending = completion }
        model.selectRegion()
        model.selectedVisualID = "display:2"
        pending?(CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(model.selectedVisualID == "display:2")
        #expect(model.visualRegion == nil)
        await model.shutdown(); try cleanup(directory)
    }

    @Test func stoppingSessionRejectsAnOutstandingRegionCallback() async throws {
        let directory = directory(), model = model(directory: directory)
        model.session.phase = .running; model.screenMode = .manual
        model.visualSources = sources(); model.selectedVisualID = "display:1"
        var pending: ((CGRect?) -> Void)?
        model.chooseRegion = { _, completion in pending = completion }
        model.selectRegion()
        await model.stop()
        pending?(CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(model.visualRegion == nil && model.selectedVisualID.isEmpty && model.screenMode == .off)
        await model.shutdown(); try cleanup(directory)
    }

    @Test func lateSourceInventoryIsDiscardedAfterConsentRevocation() async throws {
        let gate = SurfaceSourceGate()
        let directory = directory(), model = model(directory: directory, loader: { await gate.fetch() })
        model.session.phase = .running; model.screenMode = .manual
        let task = Task { await model.refreshVisualSources() }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.started)
        model.screenMode = .off
        await gate.release(sources())
        await task.value
        #expect(model.visualSources.isEmpty)
        #expect(model.screenMode == .off)
        await model.shutdown(); try cleanup(directory)
    }

    @Test func shutdownPermanentlyRejectsNewSessionAndMutationCommands() async throws {
        let directory = directory(), model = model(directory: directory)
        model.ready = true; model.modelReady = true; model.transcriptionOnly = true
        #expect(model.canStart)
        await model.shutdown()
        #expect(!model.canStart && model.isShuttingDown)
        let original = model.preferences
        model.addProfile(); model.toggleExpanded(); model.installModel(); model.validateAPI(); model.connectSubscription()
        #expect(model.preferences == original)
        #expect(!model.modelInstalling && !model.validatingAPI && !model.subscription.signingIn)
        try cleanup(directory)
    }

    @Test func newestPreferencesAreFlushedWhenQuitArrivesDuringDebounce() async throws {
        let directory = directory(), model = model(directory: directory)
        model.ready = true
        for index in 0..<100 { model.preferences.ai.answerLanguage = "Language \(index)" }
        model.preferences.ai.answerLanguage = "Serbian"
        await model.shutdown()
        let saved = try await PreferencesStore(directory: directory).load()
        #expect(saved.ai.answerLanguage == "Serbian")
        try cleanup(directory)
    }

    @Test func transcriptionOnlyCannotMislabelAnAlreadyRunningSession() async throws {
        let directory = directory(), model = model(directory: directory)
        model.session.phase = .running
        model.transcriptionOnly = true
        #expect(!model.transcriptionOnly)
        #expect(model.status.contains("automatic answers"))
        #expect(model.errorMessage?.contains("End the session") == true)
        model.session.phase = .idle
        model.transcriptionOnly = true
        #expect(model.transcriptionOnly)
        await model.shutdown(); try cleanup(directory)
    }

    @Test func captureDiagnosticsKeepOnlyApprovedDomainAndNumericCode() {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3801, userInfo: [NSLocalizedDescriptionKey: "PRIVATE WINDOW TITLE"])
        let diagnostic = ApplicationModel.captureFailureCode(denied)
        #expect(diagnostic.contains(SCStreamErrorDomain) && diagnostic.contains("-3801"))
        #expect(!diagnostic.contains("PRIVATE"))
        let untrusted = NSError(domain: "private-api-key-or-window-title", code: 42)
        #expect(ApplicationModel.captureFailureCode(untrusted) == "OtherNativeError (42)")
    }

    @Test func clearingDataCannotBeUndoneByPendingAutosave() async throws {
        let directory = directory(), model = model(directory: directory)
        model.ready = true
        model.addProfile()
        #expect(model.preferences.profiles.count == 1)
        await model.clearLocalData()
        #expect(model.preferences.profiles.isEmpty && model.preferences.selectedProfileID == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path))
        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path))
        await model.shutdown()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path))
        try cleanup(directory)
    }
}
