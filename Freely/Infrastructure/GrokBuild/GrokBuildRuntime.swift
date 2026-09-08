import Darwin
import Foundation
import Synchronization

/// Freely invokes the official client. Its auth file is read/refreshed only by Grok Build;
/// tokens, provider client IDs and browser cookies never enter Freely.
struct GrokBuildRuntime: Sendable {
    let executable: URL
    let authFile: URL
    let temporaryRoot: URL

    static func installed() throws -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/grok"), home.appendingPathComponent(".grok/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"), URL(fileURLWithPath: "/usr/local/bin/grok")]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw GrokBuildError.notInstalled
        }
        return Self(executable: executable.resolvingSymlinksInPath(), authFile: home.appendingPathComponent(".grok/auth.json"),
            temporaryRoot: PreferencesStore.defaultDirectory.appendingPathComponent("GrokRuns", isDirectory: true))
    }

    func account() async throws -> GrokBuildAccount {
        let output = Mutex(Data())
        let code = try await run(arguments: ["models"], timeout: .seconds(20)) { line in
            try output.withLock { data in
                guard data.count + line.count < 64 * 1_024 else { throw GrokBuildError.invalidResponse }
                data.append(line); data.append(10)
            }
        }
        guard code == 0 else { throw GrokBuildError.signInRequired }
        return try GrokBuildAccount.parse(output.withLock { String(decoding: $0, as: UTF8.self) })
    }

    func signIn() async throws {
        let code = try await run(arguments: ["login", "--oauth"], timeout: .seconds(600)) { _ in }
        guard code == 0 else { throw GrokBuildError.signInFailed }
        _ = try await account()
    }

    func generate(_ request: LLMRequest, configuration: XAIConfiguration,
                  receive: @escaping @Sendable (LLMEvent) throws -> Void) async throws {
        let scope = DiagnosticScope(session: request.diagnosticSessionID, request: request.diagnosticRequestID)
        let started = ProcessInfo.processInfo.systemUptime
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: request.detailed ? configuration.detailedDeadline : configuration.normalDeadline)
        FreelyLog.record(.requestStarted, scope: scope, fields: [.state: .state("grok_build")])
        do {
            // Validate the same input and image bounds as the direct API connection.
            _ = try ResponsesRequest(request: request, configuration: configuration)
            let account = try await account()
            guard account.models.contains(configuration.model) else { throw GrokBuildError.modelUnavailable }
            let parser = Mutex(GrokBuildStreamParser())
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw GrokBuildError.timedOut }
            let code = try await run(arguments: [], timeout: remaining,
                prepare: { directory in
                    let profile = directory.appendingPathComponent("freely.md")
                    try Self.writePrivate(Data((Self.profileHeader + request.trustedInstructions).utf8), to: profile)
                    var blocks: [[String: String]] = [["type": "text", "text": request.selectedContext]]
                    if let image = request.image {
                        blocks.append(["type": "image", "data": image.bytes.base64EncodedString(), "mimeType": image.format.rawValue])
                    }
                    let prompt = directory.appendingPathComponent("prompt.json")
                    try Self.writePrivate(try JSONSerialization.data(withJSONObject: blocks), to: prompt)
                    return ["--agent", profile.path, "--verbatim", "--disallowed-tools", Self.disabledTools,
                        "--deny", "*", "--no-subagents", "--disable-web-search", "--max-turns", "1",
                        "--output-format", "streaming-messages-json", "--include-partial-messages",
                        "--model", configuration.model, "--reasoning-effort", configuration.reasoningEffort.rawValue,
                        "--prompt-file", prompt.path]
                }) { line in
                    let events = try parser.withLock { try $0.consume(line) }
                    for event in events { try receive(event) }
                }
            guard code == 0 else { throw GrokBuildError.requestFailed }
            for event in try parser.withLock({ try $0.finish() }) { try receive(event) }
            FreelyLog.record(.requestFinished, scope: scope, fields: [.state: .state("grok_build")], duration: ProcessInfo.processInfo.systemUptime - started)
        } catch {
            FreelyLog.record(error is CancellationError ? .requestCancelled : .requestFailed,
                level: error is CancellationError ? .info : .error, scope: scope,
                fields: [.state: .state("grok_build"), .failure: .failure(error)], duration: ProcessInfo.processInfo.systemUptime - started)
            throw error
        }
    }

    /// Every process gets a fresh config/workspace. Only the official credential location is shared.
    /// The temporary home contains CLI transcripts/logs; it is removed after the process has exited.
    func run(arguments: [String], timeout: Duration,
             prepare: @Sendable (URL) throws -> [String] = { _ in [] },
             receiveLine: @escaping @Sendable (Data) throws -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let workspace = directory.appendingPathComponent("work", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(Data("[cli]\nauto_update = false\n[grok_com_config]\ndisable_api_key_auth = true\n".utf8),
            to: home.appendingPathComponent("config.toml"))
        let prepared = try prepare(directory)
        let process = GrokSubprocess(executable: executable, arguments: arguments + prepared,
            environment: Self.environment(home: home, authFile: authFile), directory: workspace)
        return try await withTaskCancellationHandler {
            let deadline = Task {
                do { try await Task.sleep(for: timeout); process.cancel(timedOut: true) } catch {}
            }
            defer { deadline.cancel() }
            return try await Task.detached {
                try process.execute(receiveLine: receiveLine)
            }.value
        } onCancel: { process.cancel() }
    }

    static func environment(home: URL, authFile: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["GROK_HOME"] = home.path
        result["GROK_AUTH_PATH"] = authFile.path
        result["GROK_MEMORY"] = "0"
        result["GROK_DISABLE_AUTOUPDATER"] = "1"
        result["GROK_STORAGE_MODE"] = "local"
        result["GROK_TELEMETRY_ENABLED"] = "off"
        result["GROK_EXTERNAL_OTEL"] = "0"
        result["GROK_MANAGED_MCPS_ENABLED"] = "0"
        for vendor in ["CURSOR", "CLAUDE", "CODEX"] {
            for surface in ["SKILLS", "RULES", "AGENTS", "MCPS", "HOOKS", "SESSIONS"] {
                result["GROK_\(vendor)_\(surface)_ENABLED"] = "0"
            }
        }
        return result
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static let profileHeader = """
    ---
    name: freely
    description: Freely meeting answers
    promptMode: full
    agentsMd: false
    discoverSkills: false
    ---

    """
    // CLI names and internal aliases both occur in released builds. A nonempty advertised
    // toolset is rejected by the parser as an incompatible runtime, rather than trusted.
    static let disabledTools = "bash,run_terminal_cmd,run_terminal_command,read_file,search_replace,list_dir,grep,kill_command_or_subagent,todo_write,get_command_or_subagent_output,spawn_subagent,scheduler_create,scheduler_delete,scheduler_list,monitor,search_tool,use_tool,workflow,enter_plan_mode,exit_plan_mode,ask_user_question,image_gen,image_edit,image_to_video,reference_to_video,write,Agent"
}

struct GrokBuildAccount: Sendable, Equatable {
    let models: [String]
    static func parse(_ output: String) throws -> Self {
        guard output.contains("You are logged in with grok.com.") else { throw GrokBuildError.signInRequired }
        let models = output.split(separator: "\n").compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("* ") || value.hasPrefix("- ") else { return nil }
            return value.dropFirst(2).split(separator: " ").first.map(String.init)
        }
        guard !models.isEmpty else { throw GrokBuildError.invalidResponse }
        return Self(models: models)
    }
}

enum GrokBuildError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled, signInRequired, signInFailed, modelUnavailable, invalidResponse, incompatibleRuntime, requestFailed, timedOut, outputTooLarge
    var errorDescription: String? {
        switch self {
        case .notInstalled: "Install the official Grok Build app helper, then return here and click Connect Grok."
        case .signInRequired: "Sign in to Grok Build with your grok.com account to use your subscription. An API-key login cannot be used for this connection."
        case .signInFailed: "Grok sign-in did not finish. Try again and complete the browser sign-in."
        case .modelUnavailable: "This model is not available through your Grok subscription. Choose a model listed in Grok Build, then test again."
        case .invalidResponse: "Grok Build returned an incomplete or unsupported response. Update Grok Build and reconnect."
        case .incompatibleRuntime: "This Grok Build version could not disable its tools. Update Grok Build and reconnect."
        case .requestFailed: "Grok could not complete the request. Check your connection and subscription usage, then try again."
        case .timedOut: "Grok did not finish before the time limit. Check the browser sign-in or retry the request."
        case .outputTooLarge: "The Grok response exceeded Freely's local output limit. Ask for a shorter answer."
        }
    }
}

/// Access to Process state is serialized; stdout is drained on one dedicated task.
/// Cancellation owns and waits for the child, including a bounded forced exit fallback.
private final class GrokSubprocess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private struct State {
        var started = false
        var cancelled = false
        var timedOut = false
        var escalation: Task<Void, Never>?
    }
    private let state = Mutex(State())
    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }
    func cancel(timedOut: Bool = false) {
        state.withLock { current in
            current.timedOut = current.timedOut || timedOut
            guard !current.cancelled else { return }
            current.cancelled = true
            guard current.started, process.isRunning else { return }
            process.terminate()
            current.escalation = Task.detached { [self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                state.withLock { current in
                    if current.started, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    func execute(receiveLine: @Sendable (Data) throws -> Void) throws -> Int32 {
        defer { state.withLock { $0.escalation?.cancel(); $0.escalation = nil } }
        try state.withLock { current in
            guard !current.cancelled else { throw CancellationError() }
            do { try process.run(); current.started = true }
            catch { throw GrokBuildError.notInstalled }
        }
        // The parent must close its copy so EOF is delivered after the child's exit.
        try output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        var buffer = Data(); var total = 0
        do {
            var storage = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &storage, storage.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw GrokBuildError.invalidResponse
                }
                let bytes = Data(storage.prefix(count))
                total += bytes.count
                guard total <= 4 * 1_024 * 1_024 else { throw GrokBuildError.outputTooLarge }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if !line.isEmpty { try receiveLine(line) }
                }
                guard buffer.count <= 1_024 * 1_024 else { throw GrokBuildError.outputTooLarge }
            }
            if !buffer.isEmpty { try receiveLine(buffer) }
        } catch {
            cancel(); process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        return try state.withLock { current in
            if current.timedOut { throw GrokBuildError.timedOut }
            if current.cancelled { throw CancellationError() }
            return process.terminationStatus
        }
    }
}
