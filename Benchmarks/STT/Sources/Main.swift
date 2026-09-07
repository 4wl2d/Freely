@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
@preconcurrency import WhisperKit
import Foundation

struct Fixture: Decodable, Sendable {
    let id: String
    let file: String
    let reference: String
    let duration: Double
    let split: String
    let sourceStart: Double?
    let words: [ReferenceWord]?
    let questions: [ReferenceQuestion]?
}
struct ReferenceWord: Decodable, Sendable { let start: Double; let end: Double; let text: String; let channel: String }
struct ReferenceQuestion: Decodable, Sendable { let end: Double; let text: String; let channel: String }

enum GateError: Error { case arguments, audioFormat, invalidEngine }

actor Runner {
    let engine: String
    var tdt: AsrManager?
    var eou: StreamingEouAsrManager?
    var whisper: WhisperKit?
    private(set) var inferenceActive = false

    init(engine: String) { self.engine = engine }

    func load(cache: URL) async throws {
        switch engine {
        case "fluid-tdt":
            let root = cache.deletingLastPathComponent().appendingPathComponent("parakeet-tdt-0.6b-v3")
            let config = MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)
            let cpu = MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuOnly)
            let preprocessor = try await MLModel.load(contentsOf: root.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu)
            try Task.checkCancellation()
            let encoder = try await MLModel.load(contentsOf: root.appendingPathComponent("Encoder.mlmodelc"), configuration: config)
            try Task.checkCancellation()
            let decoder = try await MLModel.load(contentsOf: root.appendingPathComponent("Decoder.mlmodelc"), configuration: config)
            try Task.checkCancellation()
            let joint = try await MLModel.load(contentsOf: root.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: config)
            let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("parakeet_vocab.json")))
            var vocabulary: [Int: String] = [:]
            for (key, value) in strings {
                guard let index = Int(key) else { throw GateError.audioFormat }
                vocabulary[index] = value
            }
            let models = AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
                                   configuration: config, vocabulary: vocabulary, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            tdt = manager
        case "fluid-eou":
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let manager = StreamingEouAsrManager(configuration: config, chunkSize: .ms320, eouDebounceMs: 450)
            try await manager.loadModels(from: cache.appendingPathComponent("parakeet-eou-streaming/320ms"))
            eou = manager
        case "whisperkit":
            whisper = try await WhisperKit(WhisperKitConfig(
                model: "openai_whisper-base.en", downloadBase: cache,
                modelFolder: cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-base.en").path,
                tokenizerFolder: cache.appendingPathComponent("models/openai/whisper-base.en"),
                verbose: false, logLevel: .none, download: false))
        default: throw GateError.invalidEngine
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        inferenceActive = true
        defer { inferenceActive = false }
        if let tdt {
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            return try await tdt.transcribe(samples, decoderState: &state).text
        }
        if let whisper {
            let result = try await whisper.transcribe(audioArray: samples, decodeOptions: DecodingOptions(language: "en"))
            return result.map(\.text).joined(separator: " ")
        }
        guard let eou else { throw GateError.invalidEngine }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ptr = buffer.floatChannelData?[0] else { throw GateError.audioFormat }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in ptr.update(from: source.baseAddress!, count: samples.count) }
        _ = try await eou.process(audioBuffer: buffer)
        return await eou.getPartialTranscript()
    }

    func finish() async throws -> String? {
        guard let eou else { return nil }
        let text = try await eou.finish()
        await eou.reset()
        return text
    }

    func close() async {
        if let tdt { await tdt.cleanup() }
        if let eou { await eou.cleanup() }
        whisper = nil
    }
}

private let outputLock = NSLock()

func emit(_ values: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    outputLock.withLock {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

func readPCM(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % 4 == 0 else { throw GateError.audioFormat }
    return data.withUnsafeBytes { raw in
        stride(from: 0, to: raw.count, by: 4).map {
            Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
        }
    }
}

@main struct STTGate {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            FileHandle.standardError.write(Data("Usage: stt-gate ENGINE CORPUS.json CACHE [limitSeconds=60] [pace=0] [stepSeconds=1] [source=systemAudio]\n".utf8))
            throw GateError.arguments
        }
        let engine = args[1], manifest = URL(fileURLWithPath: args[2]), cache = URL(fileURLWithPath: args[3])
        let limit = args.count > 4 ? Double(args[4]) ?? 60 : 60
        let paced = args.count > 5 && args[5] == "1"
        let step = args.count > 6 ? Double(args[6]) ?? 1 : 1
        let source = args.count > 7 ? args[7] : "systemAudio"
        let endpoint = args.contains("--endpoint")
        guard step.isFinite, step > 0, step <= 15, limit.isFinite, limit >= 0 else { throw GateError.arguments }
        if source == "cancel" {
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
            guard let fixture = fixtures.first else { throw GateError.arguments }
            let samples = try readPCM(manifest.deletingLastPathComponent().appendingPathComponent(fixture.file))
            let runner = Runner(engine: engine)
            try await runner.load(cache: cache)
            for attempt in 0..<9 {
                let delay = [5, 20, 50][attempt % 3]
                let task = Task { try await runner.transcribe(samples) }
                try await Task.sleep(for: .milliseconds(delay))
                let active = await runner.inferenceActive
                let stop = ProcessInfo.processInfo.systemUptime
                task.cancel()
                var completedNormally = false
                do { _ = try await task.value; completedNormally = true }
                catch is CancellationError { }
                catch { throw error }
                try emit(["event": "cancellation", "engine": engine, "attempt": attempt,
                          "cancelDelayMilliseconds": delay, "requestActiveAtCancel": active,
                          "cancelToTerminationSeconds": ProcessInfo.processInfo.systemUptime - stop,
                          "resultReturnedAfterCancel": completedNormally])
            }
            await runner.close()
            return
        }
        if source == "dual" {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for identity in ["localUser", "systemAudio"] {
                    let selectedManifest = identity == "systemAudio" && args.count > 8 && !args[8].hasPrefix("--") ? URL(fileURLWithPath: args[8]) : manifest
                    group.addTask {
                        if endpoint {
                            try await runEndpoint(engine: engine, manifest: selectedManifest, cache: cache, limit: limit, paced: paced, step: step, source: identity)
                        } else {
                            try await run(engine: engine, manifest: selectedManifest, cache: cache, limit: limit, paced: paced, step: step, source: identity)
                        }
                    }
                }
                try await group.waitForAll()
            }
        } else {
            if endpoint {
                try await runEndpoint(engine: engine, manifest: manifest, cache: cache, limit: limit, paced: paced, step: step, source: source)
            } else {
                try await run(engine: engine, manifest: manifest, cache: cache, limit: limit, paced: paced, step: step, source: source)
            }
        }
    }

    static func run(engine: String, manifest: URL, cache: URL, limit: Double, paced: Bool, step: Double, source: String) async throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let runner = Runner(engine: engine)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await runner.load(cache: cache)
        try emit(["event": "load", "engine": engine, "seconds": ProcessInfo.processInfo.systemUptime - loadStart, "source": source,
                  "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
        var audioSeconds = 0.0
        let replayStart = ProcessInfo.processInfo.systemUptime
        for fixture in fixtures {
            if audioSeconds >= limit { break }
            let samples = try readPCM(manifest.deletingLastPathComponent().appendingPathComponent(fixture.file))
            let count = min(samples.count, Int((limit - audioSeconds) * 16000))
            var pos = 0
            var previous = ""
            while pos < count {
                let end = min(count, pos + Int(step * 16000))
                let sourceEnd = audioSeconds + Double(end) / 16000
                if paced {
                    let wait = replayStart + sourceEnd - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                }
                let input = engine == "fluid-eou" ? Array(samples[pos..<end]) : Array(samples[0..<end])
                let begin = ProcessInfo.processInfo.systemUptime
                let text = try await runner.transcribe(input)
                let done = ProcessInfo.processInfo.systemUptime
                try emit(["event": "partial", "engine": engine, "source": source, "fixture": fixture.id,
                          "sourceEnd": sourceEnd, "fixtureEnd": Double(end) / 16000,
                          "wallElapsed": done - replayStart, "inferenceSeconds": done - begin,
                          "backlogSeconds": paced ? max(0, begin - replayStart - sourceEnd) : 0,
                          "inputSeconds": Double(input.count) / 16000, "changed": text != previous, "text": text])
                previous = text
                pos = end
            }
            let finalStart = ProcessInfo.processInfo.systemUptime
            let final = try await runner.finish() ?? previous
            try emit(["event": "final", "engine": engine, "source": source, "fixture": fixture.id,
                      "split": fixture.split, "duration": Double(count) / 16000, "text": final,
                      "reference": fixture.reference, "completeFixture": count == samples.count,
                      "wallElapsed": ProcessInfo.processInfo.systemUptime - replayStart,
                      "flushSeconds": ProcessInfo.processInfo.systemUptime - finalStart])
            audioSeconds += Double(count) / 16000
        }
        let stopStart = ProcessInfo.processInfo.systemUptime
        await runner.close()
        try emit(["event": "end", "engine": engine, "source": source, "audioSeconds": audioSeconds,
                  "wallSeconds": ProcessInfo.processInfo.systemUptime - replayStart,
                  "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                  "cleanupSeconds": ProcessInfo.processInfo.systemUptime - stopStart])
    }
}
