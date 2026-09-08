import Foundation

public struct SSEEvent: Sendable, Equatable {
    public let name: String?
    public let data: String
}

/// Byte-oriented framing preserves split UTF-8 scalars. Decoding happens only at complete lines.
public struct SSEParser: Sendable {
    private var line = Data()
    private var dataLines: [String] = []
    private var name: String?
    private var skipLF = false
    private var eventBytes = 0
    private var firstLine = true
    private let maxEventBytes: Int

    public init(maxEventBytes: Int = 262_144) {
        self.maxEventBytes = max(1, maxEventBytes)
        line.reserveCapacity(512)
    }

    public mutating func append(_ byte: UInt8) throws -> SSEEvent? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            return try consumeLine()
        }
        guard line.count < maxEventBytes else { throw XAIError.malformedStream }
        line.append(byte)
        return nil
    }

    public mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = try append(byte) { events.append(event) }
        }
        return events
    }

    public mutating func finish() throws {
        // An unterminated event is intentionally never dispatched as a successful terminal event.
        if !line.isEmpty {
            guard String(data: line, encoding: .utf8) != nil else { throw XAIError.malformedStream }
        }
        line.removeAll(keepingCapacity: false)
        dataLines.removeAll(keepingCapacity: false)
        name = nil
        eventBytes = 0
    }

    private mutating func consumeLine() throws -> SSEEvent? {
        guard var text = String(data: line, encoding: .utf8) else { throw XAIError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); name = nil; eventBytes = 0 }
            return dataLines.isEmpty ? nil : SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
        }
        eventBytes += text.utf8.count + 1
        guard eventBytes <= maxEventBytes else { throw XAIError.malformedStream }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = parts[0]
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value)
        case "event": name = value
        default: break // id/retry are not used: reconnecting this POST could create another paid generation.
        }
        return nil
    }
}

struct ResponsesStreamDecoder {
    private(set) var terminal = false
    private var sequence: Int?

    mutating func decode(_ event: SSEEvent) throws -> [LLMEvent] {
        guard !terminal else { return [] }
        // Responses completion is established only by a typed terminal event, never a legacy sentinel.
        if event.data == "[DONE]" { throw XAIError.earlyEOF }
        guard let data = event.data.data(using: .utf8) else { throw XAIError.malformedStream }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw XAIError.malformedStream }
        if let name = event.name, name != "message", name != header.type { throw XAIError.malformedStream }
        if let current = header.sequenceNumber {
            if let previous = sequence, current <= previous { throw XAIError.malformedStream }
            sequence = current
        }
        let recognized = ["response.output_text.delta", "response.refusal.delta", "response.completed", "response.incomplete", "response.failed", "error"]
        guard recognized.contains(header.type) else { return [] }
        let payload: Envelope
        do { payload = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw XAIError.malformedStream }
        switch payload.type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = payload.delta else { throw XAIError.malformedStream }
            return delta.isEmpty ? [] : [.textDelta(delta)]
        case "response.completed", "response.incomplete", "response.failed":
            guard let response = payload.response else { throw XAIError.malformedStream }
            let expected = String(payload.type.dropFirst("response.".count))
            guard response.status == expected else { throw XAIError.malformedStream }
            terminal = true
            var events: [LLMEvent] = response.usage.map { [.usage($0.value)] } ?? []
            switch response.status {
            case "completed": events.append(.completed)
            case "incomplete":
                let reason: LLMIncompleteReason = switch response.incompleteDetails?.reason {
                case "max_output_tokens": .outputLimit
                case "content_filter": .contentFilter
                default: .unknown
                }
                events.append(.incomplete(reason))
            default: throw XAIError.providerFailure
            }
            return events
        case "error": throw XAIError.providerFailure
        default: return [] // In particular reasoning, reasoning summaries and encrypted content are never emitted.
        }
    }

    private struct Header: Decodable {
        let type: String
        let sequenceNumber: Int?
        enum CodingKeys: String, CodingKey { case type; case sequenceNumber = "sequence_number" }
    }
    private struct Envelope: Decodable {
        let type: String
        let delta: String?
        let sequenceNumber: Int?
        let response: Response?
        enum CodingKeys: String, CodingKey { case type, delta, response; case sequenceNumber = "sequence_number" }
    }
    private struct Response: Decodable {
        let status: String
        let usage: Usage?
        let incompleteDetails: Incomplete?
        enum CodingKeys: String, CodingKey { case status, usage; case incompleteDetails = "incomplete_details" }
    }
    private struct Incomplete: Decodable { let reason: String? }
    private struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let inputTokensDetails: InputDetails?
        let outputTokensDetails: OutputDetails?
        struct InputDetails: Decodable { let cachedTokens: Int?; enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" } }
        struct OutputDetails: Decodable { let reasoningTokens: Int?; enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" } }
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens", totalTokens = "total_tokens"
            case inputTokensDetails = "input_tokens_details", outputTokensDetails = "output_tokens_details"
        }
        var value: LLMUsage { .init(inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens,
                                   cachedInputTokens: inputTokensDetails?.cachedTokens, reasoningTokens: outputTokensDetails?.reasoningTokens) }
    }
}
