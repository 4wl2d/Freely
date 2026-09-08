import os

/// Categories contain only application-authored states, opaque IDs, counts and timings.
/// Meeting text, images, credentials and private reasoning never belong in a log message.
enum FreelyLog {
    static let session = Logger(subsystem: "local.freely.app", category: "session")
    static let audio = Logger(subsystem: "local.freely.app", category: "audio")
    static let stt = Logger(subsystem: "local.freely.app", category: "stt")
    static let transcript = Logger(subsystem: "local.freely.app", category: "transcript")
    static let context = Logger(subsystem: "local.freely.app", category: "context")
    static let screen = Logger(subsystem: "local.freely.app", category: "screen")
    static let llm = Logger(subsystem: "local.freely.app", category: "llm")
    static let overlay = Logger(subsystem: "local.freely.app", category: "overlay")
    static let permissions = Logger(subsystem: "local.freely.app", category: "permissions")
    static let modelDistribution = Logger(subsystem: "local.freely.app", category: "model-distribution")
    static let performance = Logger(subsystem: "local.freely.app", category: "performance")
}
