import Darwin
import Foundation

/// Explicit projection: never encode ApplicationModel, preferences, errors or transcripts.
struct DiagnosticReport: Encodable, Sendable {
    let schemaVersion = 1
    let generatedAt = Date()
    let privacy = "Contains app states, counts, timings, opaque correlation IDs and classified errors. Excludes audio, text, images, credentials, device names, application/window titles and file paths."
    let environment: [String: String]
    let state: [String: String]
    let recording: DiagnosticSnapshot

    init(recording: DiagnosticSnapshot, state: [String: DiagnosticValue], bundle: Bundle = .main) {
        self.recording = recording
        self.state = state.mapValues(\.text)
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        environment = [
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled",
            "revision": bundle.object(forInfoDictionaryKey: "FreelyBuildRevision") as? String ?? "unknown",
            "workingTree": bundle.object(forInfoDictionaryKey: "FreelyBuildWorkingTree") as? String ?? "unknown",
            "configuration": configuration,
            "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "processID": String(process.processIdentifier),
            "processorCount": String(process.processorCount),
            "physicalMemoryBytes": String(process.physicalMemory),
            "residentMemoryBytes": Self.residentMemoryBytes().map(String.init) ?? "unavailable",
            "thermalState": String(process.thermalState.rawValue)
        ]
    }
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}
