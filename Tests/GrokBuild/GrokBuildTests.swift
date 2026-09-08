import Foundation
import Synchronization
import ScreenCaptureKit
import Testing
@testable import Freely

struct GrokBuildStreamTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private let ready = Data(#"{"type":"system","subtype":"init","tools":[],"mcp_servers":[]}"#.utf8)
    private let delta = Data(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Ready"}}}"#.utf8)
    private let result = Data(#"{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Ready","usage":{"input_tokens":80,"output_tokens":2}}"#.utf8)

    @Test func streamsOnlyAnswerTextAndRequiresFinalSuccess() throws {
        var parser = GrokBuildStreamParser()
        #expect(try parser.consume(ready) == [.providerPrivacy(zeroDataRetention: nil)])
        #expect(try parser.consume(data(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private reasoning"}}}"#)).isEmpty)
        #expect(try parser.consume(delta) == [.textDelta("Ready")])
        #expect(throws: GrokBuildError.invalidResponse) { try parser.finish() }
        #expect(try parser.consume(result).isEmpty)
        #expect(try parser.finish().last == .completed)
    }
    @Test func neverDuplicatesFinalAnswer() throws {
        var parser = GrokBuildStreamParser()
        _ = try parser.consume(ready); _ = try parser.consume(delta)
        _ = try parser.consume(data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Ready"}]}}"#))
        #expect(try parser.consume(result).isEmpty)
    }
    @Test func rejectsEnabledToolsAndMissingCapabilityInventory() {
        for text in [#"{"type":"system","subtype":"init","tools":["bash"],"mcp_servers":[]}"#,
                     #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[{}]}"#,
                     #"{"type":"system","subtype":"init"}"#] {
            var parser = GrokBuildStreamParser()
            #expect(throws: GrokBuildError.incompatibleRuntime) { try parser.consume(data(text)) }
        }
    }
    @Test func rejectsAVisibleToolCallEvenAfterEmptyInventory() throws {
        var parser = GrokBuildStreamParser(); _ = try parser.consume(ready)
        #expect(throws: GrokBuildError.incompatibleRuntime) {
            try parser.consume(data(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use"}}}"#))
        }
    }
    @Test func preservesInterruptedPartialAndNeverClaimsCompletion() throws {
        var parser = GrokBuildStreamParser(); _ = try parser.consume(ready); _ = try parser.consume(delta)
        #expect(throws: GrokBuildError.requestFailed) {
            try parser.consume(data(#"{"type":"result","is_error":true,"result":"secret provider detail"}"#))
        }
        #expect(throws: GrokBuildError.invalidResponse) { try parser.finish() }
        #expect(!GrokBuildError.requestFailed.localizedDescription.contains("secret"))
    }
    @Test func mapsOutputLimitToIncomplete() throws {
        var parser = GrokBuildStreamParser(); _ = try parser.consume(ready); _ = try parser.consume(delta)
        _ = try parser.consume(data(#"{"type":"result","is_error":false,"stop_reason":"max_tokens"}"#))
        #expect(try parser.finish() == [.incomplete(.outputLimit)])
    }
    @Test func boundsAnswerAndRejectsUnexpectedOrder() throws {
        var parser = GrokBuildStreamParser()
        #expect(throws: GrokBuildError.invalidResponse) { try parser.consume(delta) }
        _ = try parser.consume(ready)
        let large: [String: Any] = ["type": "result", "is_error": false, "stop_reason": "end_turn", "result": String(repeating: "a", count: 131_073)]
        #expect(throws: GrokBuildError.outputTooLarge) { try parser.consume(JSONSerialization.data(withJSONObject: large)) }
    }
    @Test func subscriptionAccountMustNotUseAPIKeyLogin() throws {
        #expect(try GrokBuildAccount.parse("You are logged in with grok.com.\nAvailable models:\n * grok-4.6 (default)\n - grok-4.5").models == ["grok-4.6", "grok-4.5"])
        #expect(throws: GrokBuildError.signInRequired) {
            try GrokBuildAccount.parse("You are logged in with an API key.\n * grok-4.6")
        }
    }
    @Test func childEnvironmentDoesNotInheritAPIKeysOrOtherClientsConfiguration() {
        let env = GrokBuildRuntime.environment(home: URL(fileURLWithPath: "/temporary/home"), authFile: URL(fileURLWithPath: "/user/.grok/auth.json"),
            inherited: ["HOME": "/user", "PATH": "/untrusted/bin", "XAI_API_KEY": "private", "GROK_CONFIG": "private", "GROK_STORAGE_MODE": "writeback"])
        #expect(env["HOME"] == "/user")
        #expect(env["XAI_API_KEY"] == nil && env["GROK_CONFIG"] == nil)
        #expect(env["GROK_STORAGE_MODE"] == "local")
        #expect(env["GROK_CLAUDE_HOOKS_ENABLED"] == "0" && env["GROK_MANAGED_MCPS_ENABLED"] == "0")
        #expect(env["GROK_AUTH_PATH"] == "/user/.grok/auth.json")
    }
}

struct GrokBuildProcessTests {
    private func fixture(_ body: String) throws -> (GrokBuildRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freely-process-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("grok")
        try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (GrokBuildRuntime(executable: executable, authFile: root.appendingPathComponent("auth.json"), temporaryRoot: root.appendingPathComponent("runs")), root)
    }
    @Test func drainsOutputAndRemovesTemporaryHistory() async throws {
        let (runtime, root) = try fixture("printf 'first\\nlast'\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = Mutex<[String]>([])
        let code = try await runtime.run(arguments: [], timeout: .seconds(5)) { data in
            lines.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
        }
        #expect(code == 0)
        #expect(lines.withLock { $0 } == ["first", "last"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.temporaryRoot.path).isEmpty)
    }
    @Test func cancellationWaitsForTheChildAndRemovesItsWorkspace() async throws {
        let (runtime, root) = try fixture("printf 'started\\n'\nexec /bin/sleep 60\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = OAuthResultGate<Void>()
        let task = Task { try await runtime.run(arguments: [], timeout: .seconds(10)) { _ in started.resolve(.success(())) } }
        try await withCheckedThrowingContinuation { started.install($0) }
        let clock = ContinuousClock(); let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: clock.now) < .seconds(4))
        #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.temporaryRoot.path).isEmpty)
    }
    @Test func deadlineStopsAnUnresponsiveChild() async throws {
        let (runtime, root) = try fixture("exec /bin/sleep 60\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: GrokBuildError.timedOut) {
            try await runtime.run(arguments: [], timeout: .milliseconds(100)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.temporaryRoot.path).isEmpty)
    }
    @Test func failedGenerationDoesNotBecomeCompleted() async throws {
        let (runtime, root) = try fixture("printf 'partial\\n'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await runtime.run(arguments: [], timeout: .seconds(3)) { _ in } == 1)
    }
}

struct LegacyDataMigrationTests {
    @Test func copiesLegacyDataOnceAndPreservesExistingFreelyPreferences() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("freely-migration-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try manager.createDirectory(at: old.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try manager.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("preferences.json"))
        try Data("new".utf8).write(to: new.appendingPathComponent("preferences.json"))
        try Data("model".utf8).write(to: old.appendingPathComponent("Models/weights"))
        #expect(try LegacyDataMigration.copyIfNeeded(destination: new, legacy: old))
        #expect(try String(contentsOf: new.appendingPathComponent("preferences.json"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: new.appendingPathComponent("Models/weights"), encoding: .utf8) == "model")
        #expect(manager.fileExists(atPath: old.appendingPathComponent("Models/weights").path))
        try manager.removeItem(at: new.appendingPathComponent("preferences.json"))
        #expect(try !LegacyDataMigration.copyIfNeeded(destination: new, legacy: old))
        #expect(!manager.fileExists(atPath: new.appendingPathComponent("preferences.json").path))
    }
}

struct GrokBuildLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREELY_GROK_LIVE"] == "1"))
    func realSubscriptionRespondsAndCleansTemporaryData() async throws {
        let runtime = try GrokBuildRuntime.installed()
        let events = Mutex<[LLMEvent]>([])
        try await runtime.generate(LLMRequest(trustedInstructions: "Answer this connection test in one word.", selectedContext: "Reply Ready.",
            estimatedInputTokens: 80, sessionCacheKey: UUID().uuidString), configuration: .init()) { event in events.withLock { $0.append(event) } }
        #expect(events.withLock { $0.contains(.completed) })
        #expect(events.withLock { $0.contains { if case .textDelta(let text) = $0 { return !text.isEmpty }; return false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.temporaryRoot.path).isEmpty)
    }
}

@MainActor struct GrokBuildConnectionTests {
    @Test func missingClientProducesAnActionableState() async throws {
        let connection = GrokBuildConnection(makeRuntime: { throw GrokBuildError.notInstalled })
        let finished = OAuthResultGate<Bool>()
        connection.connect(configuration: .init()) { finished.resolve(.success($0)) }
        let connected = try await withCheckedThrowingContinuation { finished.install($0) }
        await connection.shutdown()
        #expect(!connected && !connection.connected && !connection.busy)
        #expect(connection.needsInstall)
        #expect(connection.status.contains("Install"))
    }
    @Test func cancellationBeforeProcessLaunchDoesNotLeaveAStuckButton() async {
        let connection = GrokBuildConnection(makeRuntime: { throw GrokBuildError.notInstalled })
        connection.connect(configuration: .init()) { _ in }
        connection.cancel()
        await connection.shutdown()
        #expect(!connection.connected && !connection.busy)
    }
}

@MainActor @Test func screenCaptureDenialExplainsTheMacOSRecoveryStep() {
    let error = NSError(domain: SCStreamErrorDomain, code: -3801, userInfo: [NSLocalizedDescriptionKey: "private native detail"])
    let message = SessionCoordinator.message(error)
    #expect(message.contains("Screen & System Audio Recording"))
    #expect(message.contains("reopen Freely"))
    #expect(!message.contains("private native detail"))
}
