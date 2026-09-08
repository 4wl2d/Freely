import CryptoKit
import Darwin
import Foundation
import os

struct ModelManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let size: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let id: String
    let name: String
    let repository: String
    let revision: String
    let adapter: String
    let adapterVersion: String
    let license: String
    let licenseURL: URL
    let bytes: Int64
    let files: [File]

    func validate() throws {
        let hex = Set("0123456789abcdefABCDEF")
        let safeName = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.")
        let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard schemaVersion == 1, !files.isEmpty, files.count <= 128,
              !id.isEmpty, id.count <= 128, id.allSatisfy({ safeName.contains($0) && $0 != "." }),
              repositoryParts.count == 2, repositoryParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(safeName.contains) && $0 != "." && $0 != ".." }),
              revision.count == 40, revision.allSatisfy(hex.contains),
              bytes > 0, bytes <= 4 * 1_024 * 1_024 * 1_024,
              Set(files.map(\.path)).count == files.count else { throw ModelInstallError.invalidManifest }
        var sum: Int64 = 0
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.hasPrefix("/"), !components.isEmpty, file.path.utf8.count <= 2_048,
                  !file.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }),
                  file.url.scheme == "https", file.url.host == "huggingface.co",
                  file.url.user == nil, file.url.password == nil, file.url.port == nil,
                  file.url.query == nil, file.url.fragment == nil,
                  file.url.path == "/\(repository)/resolve/\(revision)/\(file.path)",
                  file.size > 0, file.size <= bytes, file.sha256.count == 64,
                  file.sha256.allSatisfy(hex.contains) else { throw ModelInstallError.invalidManifest }
            sum += file.size // Each of at most 128 entries was bounded to 4 GiB before addition.
        }
        guard sum == bytes else { throw ModelInstallError.invalidManifest }
    }
}

enum ModelInstallError: Error, Sendable, Equatable, LocalizedError {
    case invalidManifest, insufficientSpace(required: Int64), downloadFailed, sizeMismatch, checksumMismatch, notInstalled, busy
    case publicationFailed, unsafeFile, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The pinned model manifest is invalid. Reinstall the application."
        case .insufficientSpace(let required): "The model needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) of free disk space, including verification space. Free space and retry."
        case .downloadFailed: "The model download failed. Check the connection and retry. The verified model was preserved."
        case .sizeMismatch: "The model download has an unexpected size. Retry installation."
        case .checksumMismatch: "Model verification found corrupt data. Use Repair model before starting a session."
        case .notInstalled: "Download and verify the local speech model in Audio / STT settings."
        case .busy: "A model installation is already in progress. Cancel or wait for it to finish."
        case .publicationFailed: "The verified model could not be published. The previous model was preserved. Check storage access and retry."
        case .unsafeFile: "The installed model contains an unexpected symbolic link or file type. Remove it and reinstall the pinned model."
        case .storageUnavailable: "The model directory is unavailable. Check storage permissions and free disk space."
        }
    }
}

/// Process-safe ownership also lets the next launch remove interrupted staging directories safely.
private final class ModelInstallationLock: Sendable {
    private let descriptor: Int32
    init(root: URL, exclusive: Bool = true) throws {
        let descriptor = open(root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ModelInstallError.storageUnavailable }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw ModelInstallError.busy
        }
        self.descriptor = descriptor
    }
    deinit { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
}

struct ModelInstallProgress: Sendable {
    let phase: String
    let completedBytes: Int64
    let totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

/// The downloaded file is moved out of URLSession's temporary location before the delegate returns.
/// Lock isolation covers continuation, cancellation, and progress; no unchecked Sendable annotation.
private final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var result: Result<Void, Error>?
        var bytes: Int64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let target: URL
    private let expectedSize: Int64
    init(target: URL, expectedSize: Int64) { self.target = target; self.expectedSize = expectedSize }
    var bytes: Int64 { state.withLock { $0.bytes } }

    func run(url: URL) async throws {
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                let start = state.withLock { value in
                    if value.cancelled { continuation.resume(throwing: CancellationError()); return false }
                    value.continuation = continuation; value.task = task
                    return true
                }
                if start { task.resume() }
            }
        } onCancel: { cancel() }
    }
    private func cancel() {
        let task = state.withLock { value in value.cancelled = true; return value.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        state.withLock { $0.bytes = totalBytesWritten }
        if totalBytesWritten > expectedSize {
            state.withLock { $0.result = .failure(ModelInstallError.sizeMismatch) }
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ModelInstallError.downloadFailed
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == expectedSize else { throw ModelInstallError.sizeMismatch }
            try FileManager.default.moveItem(at: location, to: target)
            state.withLock { $0.result = .success(()) }
        } catch { state.withLock { $0.result = .failure(error) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = state.withLock { value -> (CheckedContinuation<Void, Error>?, Result<Void, Error>) in
            let result: Result<Void, Error>
            if value.cancelled { result = .failure(CancellationError()) }
            else if let stored = value.result { result = stored }
            else if let error { result = .failure(error) }
            else { result = .failure(ModelInstallError.downloadFailed) }
            let continuation = value.continuation
            value.continuation = nil; value.task = nil
            return (continuation, result)
        }
        completion.0?.resume(with: completion.1)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Hugging Face redirects public pinned assets to HTTPS object storage; never accept a transport downgrade.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

actor ModelInstaller {
    let root: URL
    let manifest: ModelManifest
    private var activeDownload: ModelFileDownload?
    private var progressState: ModelInstallProgress
    private var installing = false
    private var verifying = false
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let fetchFile: (@Sendable (ModelManifest.File, URL) async throws -> Void)?

    init(root: URL, manifest: ModelManifest,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64 = ModelInstaller.diskCapacity,
         fetchFile: (@Sendable (ModelManifest.File, URL) async throws -> Void)? = nil) throws {
        try manifest.validate()
        self.root = root; self.manifest = manifest
        self.availableCapacity = availableCapacity; self.fetchFile = fetchFile
        progressState = ModelInstallProgress(phase: "Not installed", completedBytes: 0, totalBytes: manifest.bytes)
    }
    func progress() -> ModelInstallProgress {
        ModelInstallProgress(phase: progressState.phase,
            completedBytes: progressState.completedBytes + (activeDownload?.bytes ?? 0), totalBytes: manifest.bytes)
    }
    var installationURL: URL { root.appendingPathComponent("\(manifest.id)-\(manifest.revision)", isDirectory: true) }

    /// Verifies hashes every time assets are admitted to a new loaded cache. No trust in a marker file.
    func verifiedInstallation() async throws -> URL {
        guard !installing, !verifying else { throw ModelInstallError.busy }
        verifying = true
        defer { verifying = false }
        let target = installationURL
        guard FileManager.default.fileExists(atPath: target.path) else { throw ModelInstallError.notInstalled }
        let ownership = try ModelInstallationLock(root: root, exclusive: false)
        defer { withExtendedLifetime(ownership) {} }
        try await Self.verify(directory: target, manifest: manifest)
        progressState = .init(phase: "Verified", completedBytes: manifest.bytes, totalBytes: manifest.bytes)
        return target
    }

    /// A complete new version is staged on the same filesystem and published with one atomic rename/swap.
    func install() async throws -> URL {
        try Task.checkCancellation()
        guard !installing, !verifying else { throw ModelInstallError.busy }
        installing = true
        defer { installing = false; activeDownload = nil }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let ownership = try ModelInstallationLock(root: root)
        defer { withExtendedLifetime(ownership) {} }
        try Self.removeInterruptedStaging(in: root)
        let capacity = try availableCapacity(root)
        let required = manifest.bytes * 2 + 256 * 1_024 * 1_024
        guard capacity >= required else { throw ModelInstallError.insufficientSpace(required: required) }
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var completed: Int64 = 0
            for file in manifest.files {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(file.path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                progressState = .init(phase: "Downloading model", completedBytes: completed, totalBytes: manifest.bytes)
                if let fetchFile { try await fetchFile(file, target) }
                else {
                    let download = ModelFileDownload(target: target, expectedSize: file.size)
                    activeDownload = download
                    try await download.run(url: file.url)
                    activeDownload = nil
                }
                try Task.checkCancellation()
                progressState = .init(phase: "Verifying model", completedBytes: completed, totalBytes: manifest.bytes)
                try await Self.verify(file: file, at: target)
                completed += file.size
            }
            try Task.checkCancellation()
            let target = installationURL
            if manager.fileExists(atPath: target.path) {
                let attributes = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ModelInstallError.unsafeFile }
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else { throw ModelInstallError.publicationFailed }
                // Publication already succeeded. Failure to remove the old directory is a cleanup warning, not a failed install.
                do { try manager.removeItem(at: staging) }
                catch { FreelyLog.record(.modelCleanupFailed, level: .warning, fields: [.state: .state("previous_installation"), .failure: .failure(error)]) }
            } else {
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw ModelInstallError.publicationFailed }
            }
            progressState = .init(phase: "Verified", completedBytes: manifest.bytes, totalBytes: manifest.bytes)
            FreelyLog.record(.modelInstalled, fields: [.bytes: .int(manifest.bytes)])
            return target
        } catch {
            if manager.fileExists(atPath: staging.path) {
                do { try manager.removeItem(at: staging) }
                catch { FreelyLog.record(.modelCleanupFailed, level: .warning, fields: [.state: .state("staging"), .failure: .failure(error)]) }
            }
            progressState = .init(phase: error is CancellationError ? "Cancelled" : "Installation failed", completedBytes: 0, totalBytes: manifest.bytes)
            throw error
        }
    }
    /// Called only after explicit user selection while no session/installation owns the model.
    func removeInstalledModel() throws {
        guard !installing, !verifying else { throw ModelInstallError.busy }
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        let ownership = try ModelInstallationLock(root: root)
        defer { withExtendedLifetime(ownership) {} }
        try Self.removeInterruptedStaging(in: root)
        if manager.fileExists(atPath: installationURL.path) { try manager.removeItem(at: installationURL) }
        let pointer = root.appendingPathComponent("active-model")
        if manager.fileExists(atPath: pointer.path) { try manager.removeItem(at: pointer) }
        progressState = .init(phase: "Not installed", completedBytes: 0, totalBytes: manifest.bytes)
    }
    static func verify(directory: URL, manifest: ModelManifest) async throws {
        try manifest.validate()
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ModelInstallError.unsafeFile }
        for file in manifest.files {
            try Task.checkCancellation()
            var parent = directory
            for part in file.path.split(separator: "/").dropLast() {
                parent.appendPathComponent(String(part), isDirectory: true)
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModelInstallError.unsafeFile }
            }
            try await verify(file: file, at: directory.appendingPathComponent(file.path))
        }
    }
    static func verify(file: ModelManifest.File, at url: URL) async throws {
        // Hash I/O is on a utility task; structured cancellation is explicitly forwarded and awaited.
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ModelInstallError.unsafeFile }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { do { try handle.close() } catch { /* read-only handle close does not invalidate verified bytes */ } }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw ModelInstallError.unsafeFile }
            guard attributes.st_size == file.size else { throw ModelInstallError.sizeMismatch }
            var hash = SHA256()
            var bytesRead: Int64 = 0
            while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                bytesRead += Int64(chunk.count)
                guard bytesRead <= file.size else { throw ModelInstallError.sizeMismatch }
                hash.update(data: chunk)
            }
            guard bytesRead == file.size else { throw ModelInstallError.sizeMismatch }
            let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard value == file.sha256.lowercased() else { throw ModelInstallError.checksumMismatch }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func diskCapacity(_ root: URL) throws -> Int64 {
        try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
    }
    private static func removeInterruptedStaging(in root: URL) throws {
        for candidate in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = candidate.lastPathComponent
            let prefixes = [".install-", ".previous-"]
            guard let prefix = prefixes.first(where: name.hasPrefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try FileManager.default.removeItem(at: candidate)
        }
    }
}
