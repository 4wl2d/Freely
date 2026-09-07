import os

/// Categories contain only application-authored states, opaque IDs, counts and timings.
/// Meeting text, images, credentials and private reasoning never belong in a log message.
enum CopilotLog {
    static let session = Logger(subsystem: "local.meetingcopilot.app", category: "session")
    static let audio = Logger(subsystem: "local.meetingcopilot.app", category: "audio")
    static let stt = Logger(subsystem: "local.meetingcopilot.app", category: "stt")
    static let transcript = Logger(subsystem: "local.meetingcopilot.app", category: "transcript")
    static let context = Logger(subsystem: "local.meetingcopilot.app", category: "context")
    static let screen = Logger(subsystem: "local.meetingcopilot.app", category: "screen")
    static let llm = Logger(subsystem: "local.meetingcopilot.app", category: "llm")
    static let overlay = Logger(subsystem: "local.meetingcopilot.app", category: "overlay")
    static let permissions = Logger(subsystem: "local.meetingcopilot.app", category: "permissions")
    static let modelDistribution = Logger(subsystem: "local.meetingcopilot.app", category: "model-distribution")
    static let performance = Logger(subsystem: "local.meetingcopilot.app", category: "performance")
}
