import CryptoKit
import Foundation
import Testing
@testable import Freely

private actor ModelFetchGate {
    private(set) var started = false
    func waitForCancellation() async throws { started = true; try await Task.sleep(for: .seconds(60)) }
}

struct ModelInstallerTests {
    private let content = Data("pinned test model bytes\n".utf8)
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("FreelyModelTest-\(UUID().uuidString)", isDirectory: true) }
    private func manifest(path: String = "weights.bin", data: Data? = nil) -> ModelManifest {
        let data = data ?? content
        let revision = String(repeating: "a", count: 40)
        return ModelManifest(schemaVersion: 1, id: "fixture", name: "Test-only fixture", repository: "fixture/model", revision: revision,
            adapter: "Test target", adapterVersion: "1", license: "CC0", licenseURL: URL(string: "https://example.com/license")!, bytes: Int64(data.count),
            files: [.init(path: path, url: URL(string: "https://huggingface.co/fixture/model/resolve/\(revision)/\(path)")!, size: Int64(data.count),
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())])
    }
    private func cleanup(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.removeItem(at: root)
        }
    }
    private func installFixture(at root: URL) async throws -> URL {
        let installer = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { [content] _, target in try content.write(to: target) })
        return try await installer.install()
    }

    @Test func installVerifyRepairAndRemoveUseActualFilesystemTransaction() async throws {
        let root = root()
        let target = try await installFixture(at: root)
        let marker = target.appendingPathComponent("old-directory-marker")
        try Data("old".utf8).write(to: marker)
        let installer = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { [content] _, target in try content.write(to: target) })
        #expect(try await installer.verifiedInstallation() == target)
        #expect(try await installer.install() == target)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: target.appendingPathComponent("weights.bin")) == content)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("active-model").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".install-") })
        try await installer.removeInstalledModel()
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try await installer.removeInstalledModel()
        try cleanup(root)
    }

    @Test func checksumFailurePreservesOldModelAndRemovesStaging() async throws {
        let root = root()
        let target = try await installFixture(at: root)
        let corrupt = Data(repeating: 120, count: content.count)
        let installer = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { _, target in try corrupt.write(to: target) })
        do { _ = try await installer.install(); Issue.record("Expected checksum failure") }
        catch { #expect(error as? ModelInstallError == .checksumMismatch) }
        #expect(try Data(contentsOf: target.appendingPathComponent("weights.bin")) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".install-") })
        try cleanup(root)
    }

    @Test func actualRenamePermissionFailurePreservesPreviousInstallation() async throws {
        let root = root()
        let target = try await installFixture(at: root)
        let marker = target.appendingPathComponent("old-directory-marker")
        try Data("old".utf8).write(to: marker)
        let installer = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { [content] _, destination in
            try content.write(to: destination)
            // Real filesystem failure at publication; no fake transaction implementation is used.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        })
        do { _ = try await installer.install(); Issue.record("Expected publication failure") }
        catch { #expect(error as? ModelInstallError == .publicationFailed) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: target.appendingPathComponent("weights.bin")) == content)
        // The next real install owns the lock, clears interrupted staging, and completes repair.
        _ = try await installFixture(at: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".install-") })
        try cleanup(root)
    }

    @Test func cancelledDownloadCleansStagingAndReleasesProcessLock() async throws {
        let root = root()
        let target = try await installFixture(at: root)
        let gate = ModelFetchGate()
        let installer = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { _, destination in
            try Data("partial".utf8).write(to: destination)
            try await gate.waitForCancellation()
        })
        let task = Task { try await installer.install() }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        let competing = try ModelInstaller(root: root, manifest: manifest(), fetchFile: { [content] _, destination in try content.write(to: destination) })
        do { _ = try await competing.install(); Issue.record("Expected process lock conflict") }
        catch { #expect(error as? ModelInstallError == .busy) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try Data(contentsOf: target.appendingPathComponent("weights.bin")) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".install-") })
        _ = try await competing.install()
        try cleanup(root)
    }

    @Test func lowSpaceStopsBeforeDownloadOrPublication() async throws {
        let root = root()
        let installer = try ModelInstaller(root: root, manifest: manifest(), availableCapacity: { _ in 0 }, fetchFile: { _, _ in Issue.record("Download must not start with insufficient disk space") })
        do { _ = try await installer.install(); Issue.record("Expected low-space rejection") }
        catch { #expect(error as? ModelInstallError == .insufficientSpace(required: Int64(content.count) * 2 + 256 * 1_024 * 1_024)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [".install.lock"])
        try cleanup(root)
    }

    @Test func rejectsMalformedManifestWithoutOverflow() {
        let valid = manifest()
        let impossible = ModelManifest(schemaVersion: valid.schemaVersion, id: valid.id, name: valid.name, repository: valid.repository,
            revision: valid.revision, adapter: valid.adapter, adapterVersion: valid.adapterVersion, license: valid.license,
            licenseURL: valid.licenseURL, bytes: valid.bytes,
            files: [.init(path: "bad", url: valid.files[0].url, size: Int64.max, sha256: valid.files[0].sha256),
                    .init(path: "other", url: valid.files[0].url, size: Int64.max, sha256: valid.files[0].sha256)])
        #expect(throws: ModelInstallError.invalidManifest) { try impossible.validate() }
        #expect(throws: ModelInstallError.invalidManifest) { try manifest(path: "../escape").validate() }
    }

    @Test func hashesActualBytesAndRejectsParentAndLeafSymlinks() async throws {
        let root = root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("weights.bin")
        try content.write(to: file)
        try await ModelInstaller.verify(file: manifest().files[0], at: file)
        let leaf = root.appendingPathComponent("weights.bin")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: file)
        do { try await ModelInstaller.verify(file: manifest().files[0], at: leaf); Issue.record("Expected leaf symlink rejection") }
        catch { #expect(error as? ModelInstallError == .unsafeFile) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: real)
        do { try await ModelInstaller.verify(directory: root, manifest: manifest(path: "linked/weights.bin")); Issue.record("Expected parent symlink rejection") }
        catch { #expect(error as? ModelInstallError == .unsafeFile) }
        #expect(try Data(contentsOf: file) == content)
        try cleanup(root)
    }
}
