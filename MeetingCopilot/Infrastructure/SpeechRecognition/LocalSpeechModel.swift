import CopilotCore
import CoreML
import FluidAudio
import Foundation

struct SpeechHypothesis: Sendable {
    let text: String
    let confidence: Double?
}
protocol SpeechTranscribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> SpeechHypothesis
    func stop() async
}

/// Each capture source gets one independent manager. Each bounded re-inference starts a
/// fresh TDT decoder state: reusing the preceding window's state would duplicate tokens.
actor FluidSpeechTranscriber: SpeechTranscribing {
    private var manager: AsrManager?
    init(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        self.manager = manager
    }
    func transcribe(_ samples: [Float]) async throws -> SpeechHypothesis {
        try Task.checkCancellation()
        guard let manager, !samples.isEmpty, samples.count <= 240_000 else {
            throw AppError(domain: .transcription, category: .invalidData,
                userAction: "Resume transcription to reset the local decoder.", diagnosticCode: "invalid_analysis_window")
        }
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoder)
        try Task.checkCancellation()
        return SpeechHypothesis(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: nil)
    }
    func stop() async {
        let previous = manager; manager = nil
        await previous?.cleanup()
    }
}

/// A bounded two-source warm cache. Models are independently loaded for each source;
/// no decoder, mutable prediction state, or SDK download manager is shared.
actor LocalSpeechModelCache {
    private var models: [CopilotCore.AudioSource: AsrModels] = [:]
    private var verifiedDirectory: URL?
    let installer: ModelInstaller
    init(installer: ModelInstaller) { self.installer = installer }

    func transcriber(for source: CopilotCore.AudioSource) async throws -> FluidSpeechTranscriber {
        if let model = models[source] { return try await FluidSpeechTranscriber(models: model) }
        let directory: URL
        if let verifiedDirectory { directory = verifiedDirectory }
        else {
            directory = try await installer.verifiedInstallation()
            try Task.checkCancellation()
            verifiedDirectory = directory
        }
        let loaded = try await Self.loadVerifiedModels(from: directory)
        try Task.checkCancellation()
        models[source] = loaded
        return try await FluidSpeechTranscriber(models: loaded)
    }
    func clear() { models.removeAll(); verifiedDirectory = nil }
    var cachedSourceCount: Int { models.count }

    /// Only local verified paths are supplied to Core ML. No SDK fallback can fetch unpinned assets.
    private static func loadVerifiedModels(from directory: URL) async throws -> AsrModels {
        let neural = MLModelConfiguration()
        neural.computeUnits = .cpuAndNeuralEngine
        neural.allowLowPrecisionAccumulationOnGPU = true
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        cpu.allowLowPrecisionAccumulationOnGPU = true
        let preprocessor = try await MLModel.load(contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu)
        try Task.checkCancellation()
        let encoder = try await MLModel.load(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: neural)
        try Task.checkCancellation()
        let decoder = try await MLModel.load(contentsOf: directory.appendingPathComponent("Decoder.mlmodelc"), configuration: neural)
        try Task.checkCancellation()
        let joint = try await MLModel.load(contentsOf: directory.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: neural)
        try Task.checkCancellation()
        let raw = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
        var vocabulary: [Int: String] = [:]
        for (key, value) in raw {
            guard let index = Int(key) else { throw ModelInstallError.invalidManifest }
            vocabulary[index] = value
        }
        guard vocabulary.count >= 8_192 else { throw ModelInstallError.invalidManifest }
        return AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder,
            joint: joint, configuration: neural, vocabulary: vocabulary, version: .v3)
    }
}
