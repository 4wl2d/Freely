import CopilotCore
import Foundation
import Darwin

private struct Timing: Codable {
    let measuredOperations: UInt64
    let retainedSamples: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maximumMilliseconds: Double?
    init(_ value: MetricSnapshot) {
        measuredOperations = value.count; retainedSamples = value.retainedSamples
        p50Milliseconds = value.p50; p95Milliseconds = value.p95; maximumMilliseconds = value.maximum
    }
}
private struct GrowthSample: Codable {
    let replaySeconds: Double
    let residentBytes: UInt64?
    let retainedSegments: Int
    let retainedTranscriptBytes: Int
    let retainedQuestions: Int
    let retainedSummaryBytes: Int
}
private struct Report: Codable {
    let schemaVersion: Int
    let fixtureVersion: String
    let evidenceType: String
    let osVersion: String
    let cpuCount: Int
    let machineMemoryBytes: UInt64
    let replaySeconds: Double
    let actualElapsedSeconds: Double
    let eventsProcessed: Int
    let automaticQuestionsDetected: Int
    let expectedAutomaticQuestions: Int
    let maximumRetainedSegments: Int
    let maximumRetainedTranscriptBytes: Int
    let maximumRetainedQuestions: Int
    let maximumEstimatedContextTokens: Int
    let staleCallbacksRejected: Int
    let coreApply: Timing
    let stableTick: Timing
    let contextBuild: Timing
    let growth: [GrowthSample]
    let passedInvariants: Bool
    let limitations: [String]
}

private func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
}
private func milliseconds(since start: Double) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1_000 }

@main private struct CoreBenchmark {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print("Usage: CopilotCoreBenchmarks [--seconds 14400] [--output /path/report.json]\nAccelerated deterministic domain replay only; no audio inference or networking.")
            return
        }
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let seconds = min(86_400, max(60, Double(argument("--seconds") ?? "14400") ?? 14_400))
        let count = Int(seconds / 2)
        let engine = ConversationEngine()
        let epoch = SessionEpoch(1)
        await engine.begin(sessionID: .init(), epoch: epoch)
        var apply = BoundedMetric(capacity: count * 2)
        var tick = BoundedMetric(capacity: count)
        var context = BoundedMetric(capacity: count)
        var samples: [GrowthSample] = []
        var detected = 0, expected = 0, maxSegments = 0, maxBytes = 0, maxQuestions = 0, maxTokens = 0
        var staleRejected = 0
        var invariantPass = true
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            let time = Double(index) * 2
            let local = TranscriptSegment(source: .localUser, sequence: UInt64(index + 1),
                startTime: time, endTime: time + 0.6,
                text: "Our worker persists the tenant \(index % 17) request before acknowledging delivery.")
            var at = ProcessInfo.processInfo.systemUptime
            let localUpdate = await engine.apply(.upsert(local), sessionEpoch: epoch, now: time + 0.9)
            apply.record(milliseconds(since: at))
            invariantPass = invariantPass && localUpdate.newQuestion == nil
            let isQuestion = index % 30 == 0
            if isQuestion { expected += 1 }
            let remote = TranscriptSegment(source: .systemAudio, sequence: UInt64(index + 1),
                startTime: time + 0.7, endTime: time + 1.3,
                text: isQuestion ? "How would you preserve ordering after worker \(index % 11) restarts?" : "The remote service reported retry attempt \(index % 4) for an unavailable partition.")
            at = ProcessInfo.processInfo.systemUptime
            let update = await engine.apply(.upsert(remote), sessionEpoch: epoch, now: time + 1.7)
            apply.record(milliseconds(since: at))
            if let question = update.newQuestion {
                detected += 1
                at = ProcessInfo.processInfo.systemUptime
                let snapshot = try await engine.context(for: question)
                context.record(milliseconds(since: at))
                maxTokens = max(maxTokens, snapshot.estimatedTokens)
                invariantPass = invariantPass && snapshot.estimatedTokens <= 16_000
            }
            at = ProcessInfo.processInfo.systemUptime
            let idle = await engine.tick(now: time + 1.8, sessionEpoch: epoch)
            tick.record(milliseconds(since: at))
            invariantPass = invariantPass && idle.newQuestion == nil
            let retainedBytes = update.segments.reduce(0) { $0 + $1.text.utf8.count }
            let questions = await engine.recentQuestions().count
            maxSegments = max(maxSegments, update.segments.count)
            maxBytes = max(maxBytes, retainedBytes); maxQuestions = max(maxQuestions, questions)
            invariantPass = invariantPass && update.segments.count <= 2_000 && retainedBytes <= 2 * 1_024 * 1_024 && questions <= 20
            if index % 300 == 0 || index == count - 1 {
                samples.append(.init(replaySeconds: time + 2, residentBytes: residentBytes(),
                    retainedSegments: update.segments.count, retainedTranscriptBytes: retainedBytes,
                    retainedQuestions: questions, retainedSummaryBytes: await engine.rollingSummary()?.facts.utf8.count ?? 0))
            }
        }
        await engine.stop(epoch: .init(2))
        await engine.begin(sessionID: .init(), epoch: .init(3))
        for index in 0..<100 {
            let stale = TranscriptSegment(source: .systemAudio, sequence: UInt64(index), startTime: 1, endTime: 2, text: "Explain the obsolete session")
            let result = await engine.apply(.upsert(stale), sessionEpoch: epoch, now: 4)
            if result.result == .wrongEpoch { staleRejected += 1 }
        }
        invariantPass = invariantPass && detected == expected && staleRejected == 100
        let report = Report(schemaVersion: 1, fixtureVersion: "two-source-domain-v1", evidenceType: "accelerated-domain-replay",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, cpuCount: ProcessInfo.processInfo.processorCount,
            machineMemoryBytes: ProcessInfo.processInfo.physicalMemory, replaySeconds: Double(count * 2),
            actualElapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            eventsProcessed: count * 2, automaticQuestionsDetected: detected, expectedAutomaticQuestions: expected,
            maximumRetainedSegments: maxSegments, maximumRetainedTranscriptBytes: maxBytes,
            maximumRetainedQuestions: maxQuestions, maximumEstimatedContextTokens: maxTokens, staleCallbacksRejected: staleRejected,
            coreApply: .init(apply.snapshot), stableTick: .init(tick.snapshot), contextBuild: .init(context.snapshot),
            growth: samples, passedInvariants: invariantPass,
            limitations: ["Synthetic text fixtures, not a speech-recognition accuracy corpus.",
                "Accelerated execution does not measure real-time audio capture, model inference, thermal behavior, network latency, or native teardown.",
                "Resident memory includes the benchmark runner and bounded full-run timing samples, but no STT assets.",
                "Context token counts are conservative UTF-8 byte estimates, not provider usage."])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let output = argument("--output") {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
        if !invariantPass { throw AppError(domain: .context, category: .invalidData, recoverable: false,
            userAction: "Inspect the domain replay failure.", diagnosticCode: "benchmark_invariant_failure") }
    }
}
