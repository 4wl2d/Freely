import Foundation

/// Only public answer deltas are forwarded. Reasoning, CLI diagnostics and user/tool frames
/// are never presented as answers. Completion requires both a result frame and a clean exit.
struct GrokBuildStreamParser {
    private var initialized = false
    private var finished = false
    private var outputBytes = 0
    private var resultEvents: [LLMEvent] = []

    mutating func consume(_ data: Data) throws -> [LLMEvent] {
        guard data.count <= 1_024 * 1_024,
              let message = try? JSONDecoder().decode(Message.self, from: data) else { throw GrokBuildError.invalidResponse }
        switch message.type {
        case "system" where message.subtype == "init":
            guard !initialized, message.tools?.isEmpty == true, message.mcp_servers?.isEmpty == true else {
                throw GrokBuildError.incompatibleRuntime
            }
            initialized = true
            return [.providerPrivacy(zeroDataRetention: nil)]
        case "stream_event":
            guard initialized, !finished else { throw GrokBuildError.invalidResponse }
            if message.event?.content_block?.type == "tool_use" || message.event?.content_block?.type == "server_tool_use" {
                throw GrokBuildError.incompatibleRuntime
            }
            if message.event?.type == "content_block_delta", message.event?.delta?.type == "text_delta",
               let text = message.event?.delta?.text {
                outputBytes += text.utf8.count
                guard outputBytes <= 128 * 1_024 else { throw GrokBuildError.outputTooLarge }
                return [.textDelta(text)]
            }
        case "result":
            guard initialized, !finished else { throw GrokBuildError.invalidResponse }
            guard message.is_error == false else { throw GrokBuildError.requestFailed }
            finished = true
            // Also support clients that send a final answer without partial messages.
            var events: [LLMEvent] = []
            if outputBytes == 0, let text = message.result, !text.isEmpty {
                guard text.utf8.count <= 128 * 1_024 else { throw GrokBuildError.outputTooLarge }
                outputBytes = text.utf8.count; events.append(.textDelta(text))
            }
            guard outputBytes > 0 else { throw GrokBuildError.invalidResponse }
            if let usage = message.usage {
                resultEvents.append(.usage(LLMUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
                    totalTokens: nil, cachedInputTokens: usage.cache_read_input_tokens, reasoningTokens: nil)))
            }
            switch message.stop_reason {
            case "end_turn": resultEvents.append(.completed)
            case "max_tokens", "max_turn_requests": resultEvents.append(.incomplete(.outputLimit))
            case "refusal": resultEvents.append(.incomplete(.contentFilter))
            default: throw GrokBuildError.invalidResponse
            }
            return events
        default: break
        }
        return []
    }
    func finish() throws -> [LLMEvent] {
        guard initialized, finished, outputBytes > 0 else { throw GrokBuildError.invalidResponse }
        return resultEvents
    }
    private struct Message: Decodable {
        let type: String
        let subtype: String?
        let tools: [String]?
        let mcp_servers: [Server]?
        let event: Event?
        let is_error: Bool?
        let result: String?
        let stop_reason: String?
        let usage: Usage?
    }
    private struct Server: Decodable {}
    private struct Event: Decodable { let type: String; let delta: Delta?; let content_block: Block? }
    private struct Delta: Decodable { let type: String?; let text: String? }
    private struct Block: Decodable { let type: String }
    private struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int?; let cache_read_input_tokens: Int? }
}
