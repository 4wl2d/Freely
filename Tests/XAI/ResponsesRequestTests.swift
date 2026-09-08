import Foundation
import Testing
@testable import Freely

struct ResponsesRequestTests {
    private func request(image: LLMImage? = nil, tokens: Int = 100, detailed: Bool = false) -> LLMRequest {
        .init(trustedInstructions: "Trusted instructions", selectedContext: "Only selected meeting text", estimatedInputTokens: tokens,
              sessionCacheKey: "opaque-session", image: image, detailed: detailed)
    }
    @Test func requestContainsOnlySelectedContextAndMandatoryPrivacyFields() throws {
        let bytes = try JSONEncoder().encode(ResponsesRequest(request: request(), configuration: .init()))
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == true)
        #expect(object["model"] as? String == "grok-4.6")
        #expect(object["max_output_tokens"] as? Int == 4_096)
        #expect((object["reasoning"] as? [String: String]) == ["effort": "low"])
        #expect(object["prompt_cache_key"] as? String == "opaque-session")
        for absent in ["tools", "tool_choice", "previous_response_id", "include", "metadata"] { #expect(object[absent] == nil) }
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input[0]["content"] as? String == "Trusted instructions")
        let content = try #require(input[1]["content"] as? [[String: String]])
        #expect(content == [["type": "input_text", "text": "Only selected meeting text"]])
    }
    @Test func visualStaysInlineAndCombinedBudgetIsEnforced() throws {
        let png = LLMImage(bytes: Data([137, 80, 78, 71, 13, 10, 26, 10]), format: .png)
        let bytes = try JSONEncoder().encode(ResponsesRequest(request: request(image: png, tokens: 16_000), configuration: .init()))
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(json.contains("input_image"))
        #expect(json.contains("base64,"))
        #expect(!json.contains("https:"))
        #expect(throws: XAIError.contextTooLarge) { try ResponsesRequest(request: request(image: png, tokens: 16_001), configuration: .init()) }
        #expect(throws: XAIError.invalidImage) { try ResponsesRequest(request: request(image: .init(bytes: Data("secret text".utf8), format: .png)), configuration: .init()) }
    }
    @Test func configuredOutputCapReservesModelContextAndDetailedCapIsExplicit() throws {
        let normal = try ResponsesRequest(request: request(), configuration: .init())
        let detailed = try ResponsesRequest(request: request(detailed: true), configuration: .init())
        #expect(normal.maxOutputTokens == 4_096)
        #expect(detailed.maxOutputTokens == 8_192)
        var config = XAIConfiguration()
        config.modelContextLimit = 4_096
        #expect(throws: XAIError.contextTooLarge) { try ResponsesRequest(request: request(), configuration: config) }
    }
    @Test func retryClassificationAndDates() {
        #expect(XAILLMProvider.httpError(status: 401, retryAfter: nil) == .unauthorized(status: 401))
        #expect(XAILLMProvider.httpError(status: 403, retryAfter: nil) == .unauthorized(status: 403))
        #expect(!XAILLMProvider.isRetryable(.unauthorized(status: 401)))
        #expect(!XAILLMProvider.isRetryable(.rejected(status: 400)))
        #expect(!XAILLMProvider.isRetryable(.malformedStream))
        #expect(XAILLMProvider.isRetryable(.server(status: 503)))
        #expect(XAILLMProvider.parseRetryAfter("3") == 3)
        #expect(XAILLMProvider.parseRetryAfter("nan") == nil)
        #expect(XAILLMProvider.parseRetryAfter("-1") == nil)
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(XAILLMProvider.parseRetryAfter("Thu, 01 Jan 1970 00:00:09 GMT", now: epoch) == 9)
        #expect(XAILLMProvider.retryDelay(failure: .rateLimited(retryAfter: 9), attempt: 0, jitter: 0.8) == 9)
    }
}
