import Foundation
import Observation
import Synchronization

@MainActor @Observable
final class GrokBuildConnection {
    private(set) var connected = false
    private(set) var busy = false
    private(set) var needsInstall = false
    private(set) var status = "Connect your Grok subscription. An existing Grok Build sign-in can be used."
    private(set) var availableModels: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let makeRuntime: @Sendable () throws -> GrokBuildRuntime

    init(makeRuntime: @escaping @Sendable () throws -> GrokBuildRuntime = GrokBuildRuntime.installed) {
        self.makeRuntime = makeRuntime
        needsInstall = (try? makeRuntime()) == nil
    }

    func restore(enabled: Bool) async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let account = try await makeRuntime().account()
            try Task.checkCancellation()
            availableModels = account.models; connected = true; needsInstall = false
            status = "Grok subscription connected through Grok Build."
        } catch is CancellationError {}
        catch { connected = false; show(error) }
    }

    func connect(configuration: XAIConfiguration, completion: @escaping @MainActor (Bool) -> Void) {
        guard !busy else { return }
        busy = true; status = "Checking Grok Build sign-in…"
        FreelyLog.record(.authStarted, fields: [.state: .state("grok_build")])
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; task = nil }
            do {
                let runtime = try makeRuntime()
                needsInstall = false
                let account: GrokBuildAccount
                do { account = try await runtime.account() }
                catch GrokBuildError.signInRequired {
                    status = "Opening Grok sign-in in your browser. Complete sign-in, then return to Freely."
                    try await runtime.signIn()
                    account = try await runtime.account()
                }
                try Task.checkCancellation()
                availableModels = account.models
                status = "Verifying your subscription with a short test…"
                let completed = Mutex(false)
                try await runtime.generate(LLMRequest(trustedInstructions: "Answer this connection test with one word.",
                    selectedContext: "Reply Ready.", estimatedInputTokens: 80, sessionCacheKey: UUID().uuidString),
                    configuration: configuration) { event in
                        if event == .completed { completed.withLock { $0 = true } }
                    }
                try Task.checkCancellation()
                guard completed.withLock({ $0 }) else { throw GrokBuildError.invalidResponse }
                connected = true
                FreelyLog.record(.authConnected, fields: [.state: .state("grok_build")])
                status = "Connected · \(configuration.model) answered successfully through your subscription."
                completion(true)
            } catch is CancellationError {
                FreelyLog.record(.authCancelled, fields: [.state: .state("grok_build")])
                status = connected ? "Grok subscription connected. Test cancelled." : "Connection cancelled. Click Connect Grok to try again."
            } catch {
                connected = false; show(error); completion(false)
                FreelyLog.record(.authFailed, level: .error, fields: [.state: .state("grok_build"), .failure: .failure(error)])
            }
        }
    }

    func cancel() { task?.cancel() }
    func disconnect() async {
        cancel(); await task?.value
        connected = false
        FreelyLog.record(.authDisconnected, fields: [.state: .state("grok_build")])
        status = "Freely disconnected. Your Grok Build account remains signed in."
    }
    func shutdown() async { cancel(); await task?.value }
    private func show(_ error: Error) {
        needsInstall = error as? GrokBuildError == .notInstalled
        status = (error as? GrokBuildError)?.errorDescription ?? (error as? XAIError)?.errorDescription
            ?? "Grok could not connect. Check the network and try again."
    }
}
