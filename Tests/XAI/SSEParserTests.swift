import Foundation
import Testing
@testable import Freely

struct SSEParserTests {
    @Test func allByteBoundariesPreserveUnicodeAndMultipleEvents() throws {
        let input = Data(": heartbeat\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"café 👋\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8)
        for split in 0...input.count {
            var parser = SSEParser()
            var decoder = ResponsesStreamDecoder()
            let events = try parser.append(Data(input.prefix(split))) + parser.append(Data(input.dropFirst(split)))
            let output = try events.flatMap { try decoder.decode($0) }
            #expect(output == [.textDelta("café 👋"), .completed])
            #expect(decoder.terminal)
        }
    }

    @Test func multilineDataBOMAndBareCR() throws {
        var parser = SSEParser()
        let events = try parser.append(Data("\u{feff}: comment\rdata: {\rdata: \"type\":\"response.output_text.delta\",\rdata: \"delta\":\"yes\"}\r\r".utf8))
        var decoder = ResponsesStreamDecoder()
        #expect(try events.flatMap { try decoder.decode($0) } == [.textDelta("yes")])
    }

    @Test func unknownEventsAndReasoningAreNeverAnswerText() throws {
        var decoder = ResponsesStreamDecoder()
        for json in ["{\"type\":\"response.reasoning_text.delta\",\"delta\":\"private\"}",
                     "{\"type\":\"response.future\",\"delta\":{\"novel\":true}}"] {
            #expect(try decoder.decode(SSEEvent(name: nil, data: json)).isEmpty)
        }
    }

    @Test func incompleteAndUsageRemainTyped() throws {
        var decoder = ResponsesStreamDecoder()
        let json = "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"total_tokens\":30,\"input_tokens_details\":{\"cached_tokens\":4},\"output_tokens_details\":{\"reasoning_tokens\":7}}}}"
        #expect(try decoder.decode(SSEEvent(name: nil, data: json)) == [
            .usage(.init(inputTokens: 10, outputTokens: 20, totalTokens: 30, cachedInputTokens: 4, reasoningTokens: 7)),
            .incomplete(.outputLimit)
        ])
    }

    @Test func invalidUTF8RejectedInsteadOfReplacementCharacter() throws {
        var parser = SSEParser()
        #expect(throws: XAIError.malformedStream) { try parser.append(Data([100, 97, 116, 97, 58, 32, 0xC3, 0x28, 10])) }
        var partial = SSEParser()
        _ = try partial.append(Data([0xF0, 0x9F]))
        #expect(throws: XAIError.malformedStream) { try partial.finish() }
    }

    @Test func boundCoversLongLinesAndManyDataFields() throws {
        var longLine = SSEParser(maxEventBytes: 16)
        #expect(throws: XAIError.malformedStream) { try longLine.append(Data(String(repeating: "x", count: 17).utf8)) }
        var manyFields = SSEParser(maxEventBytes: 16)
        #expect(throws: XAIError.malformedStream) { try manyFields.append(Data("data:\ndata:\ndata:\n".utf8)) }
    }

    @Test func malformedTerminalAndOutOfOrderEventsFail() throws {
        for json in ["not json", "{\"type\":\"response.output_text.delta\"}",
                     "{\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}"] {
            var decoder = ResponsesStreamDecoder()
            #expect(throws: XAIError.malformedStream) { try decoder.decode(SSEEvent(name: nil, data: json)) }
        }
        var decoder = ResponsesStreamDecoder()
        let event = SSEEvent(name: nil, data: "{\"type\":\"response.output_text.delta\",\"delta\":\"a\",\"sequence_number\":1}")
        _ = try decoder.decode(event)
        #expect(throws: XAIError.malformedStream) { try decoder.decode(event) }
    }

    @Test func providerFailureAndLegacyDoneAreNotCompletion() throws {
        var failed = ResponsesStreamDecoder()
        #expect(throws: XAIError.providerFailure) { try failed.decode(SSEEvent(name: nil, data: "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}")) }
        var done = ResponsesStreamDecoder()
        #expect(throws: XAIError.earlyEOF) { try done.decode(SSEEvent(name: nil, data: "[DONE]")) }
    }

    @Test func eofDoesNotDispatchUnterminatedEvent() throws {
        var parser = SSEParser()
        #expect(try parser.append(Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}".utf8)).isEmpty)
        try parser.finish()
    }
}
