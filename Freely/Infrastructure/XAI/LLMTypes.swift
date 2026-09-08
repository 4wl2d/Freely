import Foundation

public protocol LLMProviding: Sendable {
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error>
    func cancelAll() async
}

/// Contains only the context already selected by the domain context builder.
public struct LLMRequest: Sendable {
    public let trustedInstructions: String
    public let selectedContext: String
    public let estimatedInputTokens: Int
    public let sessionCacheKey: String
    public let image: LLMImage?
    public let detailed: Bool
    public let diagnosticSessionID: UUID?
    public let diagnosticRequestID: UUID

    public init(trustedInstructions: String, selectedContext: String, estimatedInputTokens: Int,
                sessionCacheKey: String, image: LLMImage? = nil, detailed: Bool = false, diagnosticSessionID: UUID? = nil, diagnosticRequestID: UUID = UUID()) {
        self.diagnosticSessionID = diagnosticSessionID
        self.diagnosticRequestID = diagnosticRequestID
        self.trustedInstructions = trustedInstructions
        self.selectedContext = selectedContext
        self.estimatedInputTokens = estimatedInputTokens
        self.sessionCacheKey = sessionCacheKey
        self.image = image
        self.detailed = detailed
    }
}

public struct LLMImage: Sendable {
    public enum Format: String, Sendable { case png = "image/png", jpeg = "image/jpeg" }
    public let bytes: Data
    public let format: Format
    /// Conservative application allocation, not a provider-reported token count.
    public let estimatedTokens: Int
    public init(bytes: Data, format: Format, estimatedTokens: Int = 8_000) {
        self.bytes = bytes
        self.format = format
        self.estimatedTokens = estimatedTokens
    }
}

public struct LLMUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedInputTokens: Int?
    public let reasoningTokens: Int?
    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?, cachedInputTokens: Int?, reasoningTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case usage(LLMUsage)
    case completed
    case incomplete(LLMIncompleteReason)
    case retryScheduled(attempt: Int, delaySeconds: Double)
    case providerPrivacy(zeroDataRetention: Bool?)
}

public enum LLMIncompleteReason: String, Sendable { case outputLimit, contentFilter, unknown }
public enum XAIReasoningEffort: String, Sendable, Codable, CaseIterable { case low, medium, high, xhigh }

public struct XAIConfiguration: Sendable {
    public var model: String = "grok-4.6"
    public var reasoningEffort: XAIReasoningEffort = .low
    public var normalOutputTokens: Int = 4_096
    public var detailedOutputTokens: Int = 8_192
    public var firstOutputTimeout: Duration = .seconds(10)
    public var inactivityTimeout: Duration = .seconds(15)
    public var normalDeadline: Duration = .seconds(60)
    public var detailedDeadline: Duration = .seconds(120)
    public var maxRetries: Int = 2
    public var requestStartsPerMinute: Int = 12
    public var modelContextLimit: Int = 500_000
    public init() {}
}

/// All descriptions are fixed application strings; provider messages, payloads and keys never enter diagnostics.
public enum XAIError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential
    case invalidConfiguration
    case contextTooLarge
    case invalidImage
    case unauthorized(status: Int)
    case rateLimited(retryAfter: Double?)
    case localRateLimited
    case server(status: Int)
    case rejected(status: Int)
    case offline
    case network
    case firstOutputTimeout
    case inactivityTimeout
    case deadlineExceeded
    case malformedStream
    case earlyEOF
    case providerFailure
    case outputBufferOverflow

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Add an xAI API key in Settings. API access and billing are separate from consumer subscriptions."
        case .invalidConfiguration: "Check the configured Grok model, reasoning effort and request limits."
        case .contextTooLarge: "The selected context exceeds the request budget. Reduce selected context or the image."
        case .invalidImage: "The selected screenshot is empty, unsupported or too large. Capture a smaller PNG or JPEG."
        case .unauthorized: "xAI denied access. Check the API key, model access and API billing in the xAI Console."
        case .rateLimited: "xAI rate limited the request. Wait for the indicated backoff before trying again."
        case .localRateLimited: "The configured requests-per-minute limit has been reached. Try again shortly."
        case .server: "xAI is temporarily unavailable. Partial answers are preserved; retry when ready."
        case .rejected: "xAI rejected the request. Check the model and supported request settings."
        case .offline: "The network is offline. Local transcription can continue."
        case .network: "The connection was interrupted. Any partial answer has been preserved."
        case .firstOutputTimeout: "xAI did not start an answer before the first-output timeout."
        case .inactivityTimeout: "The answer stream stopped responding. Any partial answer has been preserved."
        case .deadlineExceeded: "The answer reached its total time limit. Any partial answer has been preserved."
        case .malformedStream: "xAI returned a malformed answer stream. Any partial answer has been preserved."
        case .earlyEOF: "The answer connection closed before a terminal response. The answer is interrupted."
        case .providerFailure: "xAI reported a failed generation. Any partial answer has been preserved."
        case .outputBufferOverflow: "Answer consumption fell behind the bounded stream. The interrupted answer can be retried."
        }
    }
}
