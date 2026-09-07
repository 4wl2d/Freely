import Foundation
import Testing
@testable import MeetingCopilot

struct KeychainTests {
    @Test func invalidCredentialRejectedBeforeKeychainWrite() async {
        let store = KeychainCredentialStore(service: "com.meetingcopilot.invalid-test.\(UUID().uuidString)")
        for value in ["", "   ", "contains newline\ninside", String(repeating: "x", count: 4_097)] {
            do { try await store.save(value); Issue.record("Expected invalid credential") }
            catch { #expect(error is CredentialStoreError) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGCOPILOT_KEYCHAIN_TEST"] == "1"))
    func isolatedKeychainRoundtrip() async throws {
        let store = KeychainCredentialStore(service: "com.meetingcopilot.roundtrip-test.\(UUID().uuidString)")
        #expect(try await store.load() == nil)
        do {
            try await store.save("synthetic-roundtrip-only")
            #expect(try await store.load() == "synthetic-roundtrip-only")
            try await store.save("synthetic-updated")
            #expect(try await store.load() == "synthetic-updated")
            try await store.delete()
            #expect(try await store.load() == nil)
            try await store.delete()
        } catch {
            // Only our UUID-namespaced synthetic item is eligible for cleanup.
            do { try await store.delete() } catch { Issue.record("Synthetic Keychain cleanup failed") }
            throw error
        }
    }
}
