import EndpointVAD
import Foundation

func normalizedWords(_ text: String) -> [String] {
    text.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber && $0 != "'") }.map(String.init)
}

func recognizesQuestionTail(_ text: String, reference: String) -> Bool {
    let expected = Array(normalizedWords(reference).suffix(2))
    let actual = normalizedWords(text)
    guard !expected.isEmpty, actual.count >= expected.count else { return false }
    return (0...(actual.count - expected.count)).contains { Array(actual[$0..<($0 + expected.count)]) == expected }
}

extension STTGate {
    static func runEndpoint(engine: String, manifest: URL, cache: URL, limit: Double, paced: Bool, step: Double, source: String) async throws {
        guard engine == "fluid-tdt" || engine == "whisperkit" else { throw GateError.invalidEngine }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let floorVariable = source == "localUser" ? "STT_GATE_MIC_RMS_FLOOR" : "STT_GATE_SYSTEM_RMS_FLOOR"
        let rmsFloor = Float(ProcessInfo.processInfo.environment[floorVariable] ?? "0.004") ?? 0.004
        let minimumSpeech = Int32(ProcessInfo.processInfo.environment["STT_GATE_MIN_SPEECH_SAMPLES"] ?? "2560") ?? 2560
        guard let first = fixtures.first, let vad = gate_vad_create_config(rmsFloor, minimumSpeech) else { throw GateError.arguments }
        defer { gate_vad_destroy(vad) }
        let referenceBase = first.sourceStart ?? 0
        let referenceWords = fixtures.flatMap { $0.words ?? [] }.sorted { $0.start < $1.start }
        let questions = fixtures.flatMap { $0.questions ?? [] }.sorted { $0.end < $1.end }
        let runner = Runner(engine: engine)
        let load = ProcessInfo.processInfo.systemUptime
        try await runner.load(cache: cache)
        try emit(["event": "load", "engine": engine, "source": source, "mode": "endpoint",
                  "paced": paced, "rmsFloor": rmsFloor, "minimumSpeechSamples": minimumSpeech,
                  "seconds": ProcessInfo.processInfo.systemUptime - load, "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
        let origin = ProcessInfo.processInfo.systemUptime
        var offeredSamples = 0
        let maximumSamples = Int(limit * 16000)
        var segment = 0
        var lastDecodeEnd = 0.0
        var lastFinalEnd = 0.0
        var previousTail = ""
        var previousText = ""
        var vadCPUSeconds = 0.0
        var frameCount = 0
        for (fixtureIndex, fixture) in fixtures.enumerated() {
            if offeredSamples >= maximumSamples { break }
            let samples = try readPCM(manifest.deletingLastPathComponent().appendingPathComponent(fixture.file))
            let count = min(samples.count, maximumSamples - offeredSamples)
            for pos in stride(from: 0, to: count, by: 320) {
                let end = min(count, pos + 320)
                let timestamp = Double(offeredSamples) / 16000
                offeredSamples += end - pos
                let sourceEnd = Double(offeredSamples) / 16000
                if paced {
                    let delay = origin + sourceEnd - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                }
                let vadStart = ProcessInfo.processInfo.systemUptime
                let accepted = samples.withUnsafeBufferPointer {
                    gate_vad_append(vad, $0.baseAddress!.advanced(by: pos), Int32(end - pos), timestamp)
                }
                guard accepted != 0 else { throw GateError.audioFormat }
                let state = gate_vad_state(vad)
                vadCPUSeconds += ProcessInfo.processInfo.systemUptime - vadStart
                frameCount += 1
                let eof = offeredSamples >= maximumSamples || (fixtureIndex == fixtures.count - 1 && end == count)
                let final = state.should_finalize != 0 || (eof && state.sample_count > 0)
                let shouldDecode = state.can_decode != 0 && (final || sourceEnd - lastDecodeEnd >= step - 0.000001)
                var text = previousText
                var processing = 0.0
                var done = ProcessInfo.processInfo.systemUptime
                if shouldDecode {
                    let owned = Array(UnsafeBufferPointer(start: gate_vad_samples(vad), count: Int(state.sample_count)))
                    let begin = ProcessInfo.processInfo.systemUptime
                    text = try await runner.transcribe(owned)
                    done = ProcessInfo.processInfo.systemUptime
                    processing = done - begin
                    try emit(["event": "partial", "engine": engine, "source": source, "fixture": "\(source)-vad-\(segment)",
                              "sourceEnd": sourceEnd, "windowStart": state.start_time, "fixtureEnd": sourceEnd - state.start_time,
                              "wallElapsed": done - origin, "inferenceSeconds": processing,
                              "backlogSeconds": paced ? max(0, begin - origin - sourceEnd) : 0,
                              "text": text, "changed": text != previousText, "inputSeconds": Double(state.sample_count) / 16000])
                    previousText = text
                    lastDecodeEnd = sourceEnd
                }
                if final {
                    let reason = state.maximum_reached != 0 ? "maximumWindow" : state.silence_samples >= 7200 ? "silence" : "endOfFixture"
                    let intervalWords = referenceWords.filter { $0.start - referenceBase >= state.start_time && $0.start - referenceBase < sourceEnd }
                    let referenceEnd = intervalWords.map { $0.end - referenceBase }.max()
                    try emit(["event": "final", "engine": engine, "source": source, "fixture": "\(source)-vad-\(segment)",
                              "split": fixture.split, "duration": Double(state.sample_count) / 16000,
                              "sourceEnd": sourceEnd, "windowStart": state.start_time, "vadSpeechEnd": state.speech_end,
                              "wallElapsed": done - origin, "finalizationFromVADSeconds": done - origin - state.speech_end,
                              "referenceSpeechEnd": referenceEnd.map { $0 as Any } ?? NSNull(),
                              "finalizationFromReferenceSeconds": referenceEnd.map { done - origin - $0 as Any } ?? NSNull(),
                              "reason": reason, "decoded": state.can_decode != 0, "text": state.can_decode != 0 ? text : "",
                              "reference": intervalWords.map(\.text).joined(separator: " "), "completeFixture": true,
                              "flushSeconds": 0.0])
                    for question in questions where question.end - referenceBase > lastFinalEnd && question.end - referenceBase <= sourceEnd {
                        let recognized = state.can_decode != 0 && question.end - referenceBase >= state.start_time && recognizesQuestionTail(previousTail + " " + text, reference: question.text)
                        try emit(["event": "questionFinal", "engine": engine, "source": source,
                                  "questionEnd": question.end - referenceBase, "questionReference": question.text,
                                  "recognizedTail": recognized, "delaySeconds": done - origin - (question.end - referenceBase),
                                  "endpointReason": reason, "windowStart": state.start_time, "sourceEnd": sourceEnd])
                    }
                    previousTail = normalizedWords(previousTail + " " + text).suffix(20).joined(separator: " ")
                    previousText = ""
                    lastFinalEnd = sourceEnd
                    segment += 1
                    lastDecodeEnd = sourceEnd
                    gate_vad_reset(vad)
                }
            }
        }
        let duration = Double(offeredSamples) / 16000
        let stop = ProcessInfo.processInfo.systemUptime
        await runner.close()
        try emit(["event": "end", "engine": engine, "source": source, "mode": "endpoint", "audioSeconds": duration,
                  "paced": paced,
                  "frames20ms": frameCount, "segments": segment, "vadCPUSeconds": vadCPUSeconds,
                  "wallSeconds": ProcessInfo.processInfo.systemUptime - origin, "cleanupSeconds": ProcessInfo.processInfo.systemUptime - stop,
                  "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                  "reference": referenceWords.filter { $0.start - referenceBase < duration }.map(\.text).joined(separator: " "),
                  "annotatedQuestionCount": questions.filter { $0.end - referenceBase <= duration }.count])
    }
}
