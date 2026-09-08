import Foundation

struct ResponsesRequest: Encodable {
    let model: String
    let stream = true
    let store = false
    let reasoning: Reasoning
    let maxOutputTokens: Int
    let promptCacheKey: String
    let input: [Message]

    struct Reasoning: Encodable { let effort: XAIReasoningEffort }
    struct Message: Encodable { let role: String; let content: Content }
    enum Content: Encodable {
        case text(String)
        case parts([Part])
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }
    struct Part: Encodable {
        let type: String
        let text: String?
        let imageURL: String?
        let detail: String?
        enum CodingKeys: String, CodingKey { case type, text, detail; case imageURL = "image_url" }
    }
    enum CodingKeys: String, CodingKey {
        case model, stream, store, reasoning, input
        case maxOutputTokens = "max_output_tokens", promptCacheKey = "prompt_cache_key"
    }

    init(request: LLMRequest, configuration: XAIConfiguration) throws {
        guard !configuration.model.isEmpty, configuration.model.utf8.count <= 128,
              configuration.normalOutputTokens > 0, configuration.detailedOutputTokens > 0,
              configuration.normalOutputTokens <= 32_768, configuration.detailedOutputTokens <= 32_768,
              configuration.maxRetries >= 0, configuration.maxRetries <= 2,
              configuration.requestStartsPerMinute > 0, configuration.requestStartsPerMinute <= 120,
              configuration.firstOutputTimeout > .zero, configuration.inactivityTimeout > .zero,
              configuration.normalDeadline > .zero, configuration.detailedDeadline > .zero,
              !request.sessionCacheKey.isEmpty, request.sessionCacheKey.utf8.count <= 128 else { throw XAIError.invalidConfiguration }
        let outputTokens = request.detailed ? configuration.detailedOutputTokens : configuration.normalOutputTokens
        let imageTokens = request.image?.estimatedTokens ?? 0
        guard request.estimatedInputTokens > 0, request.estimatedInputTokens <= 16_000,
              imageTokens >= 0, imageTokens <= 8_000,
              request.estimatedInputTokens + imageTokens <= 24_000,
              request.estimatedInputTokens + imageTokens + outputTokens + 1_024 <= configuration.modelContextLimit,
              request.trustedInstructions.utf8.count + request.selectedContext.utf8.count <= 131_072,
              !request.selectedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XAIError.contextTooLarge }
        var parts = [Part(type: "input_text", text: request.selectedContext, imageURL: nil, detail: nil)]
        if let image = request.image {
            let signatureOK = switch image.format {
            case .png: image.bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            case .jpeg: image.bytes.starts(with: [255, 216, 255])
            }
            guard signatureOK, image.bytes.count <= 5 * 1_024 * 1_024, image.estimatedTokens > 0 else { throw XAIError.invalidImage }
            parts.append(Part(type: "input_image", text: nil,
                              imageURL: "data:\(image.format.rawValue);base64,\(image.bytes.base64EncodedString())", detail: "high"))
        }
        model = configuration.model
        reasoning = Reasoning(effort: configuration.reasoningEffort)
        maxOutputTokens = outputTokens
        promptCacheKey = request.sessionCacheKey
        input = [Message(role: "system", content: .text(request.trustedInstructions)), Message(role: "user", content: .parts(parts))]
    }
}
