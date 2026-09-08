import AVFoundation
import CoreMedia
import Foundation
import os
import Synchronization

/// Copies native PCM while the callback owns it. Only these owned values cross isolation.
struct CapturedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// Native adapters convert their clock into ProcessInfo.systemUptime seconds before enqueueing.
    let timestamp: Double
    let sequence: UInt64
    var duration: Double { Double(samples.count) / sampleRate }
}

struct AudioIngressSnapshot: Sendable {
    let queuedSeconds: Double
    let droppedSeconds: Double
    let receivedFrames: UInt64
    let peak: Float
    let failure: String?
}

struct CapturedAudioLoss: Sendable, Equatable {
    let startTime: Double
    let endTime: Double
    /// Exact sample duration lost, independent of a coalesced interval's possibly wider span.
    let duration: Double
}

struct AudioIngressBatch: Sendable {
    let frames: [CapturedAudio]
    let losses: [CapturedAudioLoss]
}

/// A single callback producer publishes a consistent, bounded loss envelope without waiting.
/// Only the source worker consumes it; ordinary diagnostic snapshots never acknowledge losses.
private final class AudioLossMailbox: Sendable {
    private let version = Atomic<UInt64>(0)
    private let count = Atomic<UInt64>(0)
    private let acknowledged = Atomic<UInt64>(0)
    private let firstBits = Atomic<UInt64>(0)
    private let lastBits = Atomic<UInt64>(0)
    private let totalBits = Atomic<UInt64>(0)
    private let consumedBits = Atomic<UInt64>(0)
    var totalDuration: Double { Double(bitPattern: totalBits.load(ordering: .sequentiallyConsistent)) }
    var totalFrames: UInt64 { count.load(ordering: .sequentiallyConsistent) }
    func record(timestamp: Double, duration: Double) {
        let oldVersion = version.load(ordering: .sequentiallyConsistent)
        version.store(oldVersion &+ 1, ordering: .sequentiallyConsistent)
        let oldCount = count.load(ordering: .sequentiallyConsistent)
        if acknowledged.load(ordering: .sequentiallyConsistent) == oldCount {
            firstBits.store(timestamp.bitPattern, ordering: .sequentiallyConsistent)
            lastBits.store((timestamp + duration).bitPattern, ordering: .sequentiallyConsistent)
        } else {
            firstBits.store(min(timestamp, Double(bitPattern: firstBits.load(ordering: .sequentiallyConsistent))).bitPattern, ordering: .sequentiallyConsistent)
            lastBits.store(max(timestamp + duration, Double(bitPattern: lastBits.load(ordering: .sequentiallyConsistent))).bitPattern, ordering: .sequentiallyConsistent)
        }
        totalBits.store((totalDuration + duration).bitPattern, ordering: .sequentiallyConsistent)
        count.store(oldCount &+ 1, ordering: .sequentiallyConsistent)
        version.store(oldVersion &+ 2, ordering: .sequentiallyConsistent)
    }
    func consume() -> CapturedAudioLoss? {
        // No spin waiting: an overlapping callback remains pending for the next worker poll.
        let before = version.load(ordering: .sequentiallyConsistent)
        guard before & 1 == 0 else { return nil }
        let first = Double(bitPattern: firstBits.load(ordering: .sequentiallyConsistent))
        let last = Double(bitPattern: lastBits.load(ordering: .sequentiallyConsistent))
        let total = totalDuration
        let capturedCount = count.load(ordering: .sequentiallyConsistent)
        guard before == version.load(ordering: .sequentiallyConsistent) else { return nil }
        let previous = Double(bitPattern: consumedBits.load(ordering: .sequentiallyConsistent))
        consumedBits.store(total.bitPattern, ordering: .sequentiallyConsistent)
        acknowledged.store(capturedCount, ordering: .sequentiallyConsistent)
        guard total > previous else { return nil }
        return CapturedAudioLoss(startTime: first, endTime: last, duration: total - previous)
    }
}

/// Every slot owns exactly one retained immutable frame until take() atomically transfers that
/// retain to the consumer or closer. No code loads an unretained pointer that another thread can free.
private final class OwnedAudioFrame: Sendable {
    let value: CapturedAudio
    let durationNanoseconds: UInt64
    init(value: CapturedAudio, durationNanoseconds: UInt64) { self.value = value; self.durationNanoseconds = durationNanoseconds }
}
private final class AudioFrameSlot: Sendable {
    private let pointer = Atomic<Unmanaged<OwnedAudioFrame>?>(nil)
    func put(_ frame: OwnedAudioFrame) -> Bool {
        let owned = Unmanaged.passRetained(frame)
        let result = pointer.compareExchange(expected: nil, desired: owned, ordering: .acquiringAndReleasing)
        if !result.exchanged { owned.release() }
        return result.exchanged
    }
    func take() -> OwnedAudioFrame? { pointer.exchange(nil, ordering: .acquiringAndReleasing)?.takeRetainedValue() }
    deinit { pointer.exchange(nil, ordering: .acquiringAndReleasing)?.release() }
}
private final class AudioFailureMessage: Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// SPSC per source: a serial native callback is the sole producer; SourcePipeline is the sole
/// draining consumer. Diagnostic snapshots and close use atomics and never contend with the producer.
/// The fixed ring has256 slots and at most2 seconds of retained audio. Actual full-buffer overflow
/// drops the newest incoming frame and records its exact duration; buffered frame order is preserved.
final class AudioIngress: Sendable {
    private let slots: [AudioFrameSlot]
    private let writeCursor = Atomic<UInt64>(0)
    private let readCursor = Atomic<UInt64>(0)
    private let publishedNanoseconds = Atomic<UInt64>(0)
    private let consumedNanoseconds = Atomic<UInt64>(0)
    private let receivedFrames = Atomic<UInt64>(0)
    private let peakBits = Atomic<UInt32>(0)
    private let failure = AtomicLazyReference<AudioFailureMessage>()
    private let losses = AudioLossMailbox()
    private let accepting = Atomic<Bool>(true)
    var isAccepting: Bool { accepting.load(ordering: .acquiring) }
    let maximumDuration: Double
    private let maximumNanoseconds: UInt64
    private let maximumFrames = 256

    init(maximumDuration: Double = 2) {
        let duration = maximumDuration.isFinite ? max(0.02, min(2, maximumDuration)) : 2
        self.maximumDuration = duration; maximumNanoseconds = UInt64((duration * 1_000_000_000).rounded())
        slots = (0..<256).map { _ in AudioFrameSlot() }
    }

    func receive(_ sampleBuffer: CMSampleBuffer, timestampOverride: Double? = nil) {
        guard accepting.load(ordering: .acquiring) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return } // An empty heartbeat represents no lost audio.
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            fail("Audio capture supplied an unreadable buffer. Resume the source.")
            return
        }
        let format = asbd.pointee
        // A route with an unexpectedly huge native block is rejected, never allowed to allocate freely.
        guard count > 0, count <= 32_768, (8_000...384_000).contains(format.mSampleRate),
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 8,
              format.mFormatID == kAudioFormatLinearPCM else {
            fail("Unsupported audio format. Select another input device and resume.")
            return
        }
        let timestamp = timestampOverride ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { fail("Audio device supplied an invalid timestamp. Resume the source."); return }
        var requiredSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: &requiredSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil)
        guard queryStatus == noErr, requiredSize > 0, requiredSize <= 512 else {
            fail("The audio buffer layout is unsupported (\(queryStatus), \(requiredSize) bytes). Resume the source.")
            return
        }
        // Query the native layout first; retained memory lives only in this call.
        withUnsafeTemporaryAllocation(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment) { storage in
            guard let base = storage.baseAddress else { return }
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            let list = base.assumingMemoryBound(to: AudioBufferList.self)
            var retained: CMBlockBuffer?
            var size = 0
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: list,
                bufferListSize: requiredSize, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retained)
            guard status == noErr else { fail("Unable to copy audio (\(status)). Resume the source."); return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bits = Int(format.mBitsPerChannel)
            let bytes = bits / 8
            let isSigned = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            guard (isFloat && bits == 32) || (!isFloat && isSigned && (bits == 16 || bits == 32)),
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  !buffers.isEmpty, buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == Int(format.mChannelsPerFrame) else {
                fail("The selected device's PCM format is unsupported. Select another device.")
                return
            }
            var mono = [Float](repeating: 0, count: count)
            var valid = true
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData,
                      Int(buffer.mDataByteSize) >= count * channels * bytes else { valid = false; break }
                for index in 0..<count {
                    for channel in 0..<channels {
                        let offset = index * channels + channel
                        let value: Float
                        if isFloat { value = data.assumingMemoryBound(to: Float.self)[offset] }
                        else if bits == 16 { value = Float(data.assumingMemoryBound(to: Int16.self)[offset]) / 32_768 }
                        else { value = Float(data.assumingMemoryBound(to: Int32.self)[offset]) / 2_147_483_648 }
                        mono[index] += value.isFinite ? value / Float(format.mChannelsPerFrame) : 0
                    }
                }
            }
            if valid { offer(samples: mono, sampleRate: format.mSampleRate, timestamp: timestamp) }
            else { fail("Audio buffer size changed unexpectedly. Resume the source.") }
            withExtendedLifetime(retained) {}
        }
    }

    /// Also used by deterministic adapter tests. No borrowed memory enters storage.
    func offer(samples: [Float], sampleRate: Double, timestamp: Double) {
        guard accepting.load(ordering: .acquiring), (8_000...384_000).contains(sampleRate),
              timestamp.isFinite, !samples.isEmpty else { return }
        let duration = Double(samples.count) / sampleRate
        guard (timestamp + duration).isFinite else { fail("Audio device supplied an invalid time interval. Resume the source."); return }
        let sequence = receivedFrames.wrappingAdd(1, ordering: .relaxed).newValue
        peakBits.store(samples.reduce(Float(0)) { max($0, abs($1)) }.bitPattern, ordering: .relaxed)
        guard duration <= maximumDuration else { losses.record(timestamp: timestamp, duration: duration); return }
        let nanoseconds = UInt64((duration * 1_000_000_000).rounded())
        let write = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        let queued = publishedNanoseconds.load(ordering: .relaxed) &- consumedNanoseconds.load(ordering: .acquiring)
        guard write &- read < UInt64(maximumFrames), queued + nanoseconds <= maximumNanoseconds else {
            losses.record(timestamp: timestamp, duration: duration); return
        }
        guard accepting.load(ordering: .acquiring) else { return }
        let frame = OwnedAudioFrame(value: CapturedAudio(samples: samples, sampleRate: sampleRate,
            timestamp: timestamp, sequence: sequence), durationNanoseconds: nanoseconds)
        publishedNanoseconds.wrappingAdd(nanoseconds, ordering: .releasing)
        let slot = slots[Int(write % UInt64(maximumFrames))]
        guard slot.put(frame) else {
            // This cannot occur under the documented single-producer contract. Fail explicitly,
            // balance the reservation and retain loss evidence instead of overwriting an owned frame.
            publishedNanoseconds.wrappingSubtract(nanoseconds, ordering: .releasing)
            losses.record(timestamp: timestamp, duration: duration)
            fail("Audio source callbacks overlapped unexpectedly. Resume the source.")
            return
        }
        writeCursor.store(write &+ 1, ordering: .releasing)
        // A close racing this publication must not leave a retained frame behind. Atomic take
        // gives exactly one owner to this producer, the consumer, or the closer.
        if !accepting.load(ordering: .acquiring), let discarded = slot.take() {
            consumedNanoseconds.wrappingAdd(discarded.durationNanoseconds, ordering: .releasing)
        }
    }

    func drain() -> [CapturedAudio] { drainBatch().frames }
    func drainBatch() -> AudioIngressBatch {
        guard accepting.load(ordering: .acquiring) else { return AudioIngressBatch(frames: [], losses: []) }
        let end = writeCursor.load(ordering: .acquiring)
        var read = readCursor.load(ordering: .relaxed)
        var frames: [CapturedAudio] = []
        frames.reserveCapacity(Int(min(UInt64(maximumFrames), end &- read)))
        while read != end {
            let owned = slots[Int(read % UInt64(maximumFrames))].take()
            if let owned { consumedNanoseconds.wrappingAdd(owned.durationNanoseconds, ordering: .releasing) }
            read &+= 1
            readCursor.store(read, ordering: .releasing)
            if let owned { frames.append(owned.value) }
        }
        let loss = losses.consume()
        guard accepting.load(ordering: .acquiring) else { return AudioIngressBatch(frames: [], losses: []) }
        return AudioIngressBatch(frames: frames, losses: loss.map { [$0] } ?? [])
    }
    func snapshot() -> AudioIngressSnapshot {
        let consumed = consumedNanoseconds.load(ordering: .acquiring)
        let published = publishedNanoseconds.load(ordering: .acquiring)
        // Cross-counter reads are approximate during concurrent traffic; the enforced capacity
        // is a hard upper bound. No snapshot inspects or borrows queued frame pointers.
        let queued = min(maximumDuration, Double(published &- consumed) / 1_000_000_000)
        return AudioIngressSnapshot(queuedSeconds: accepting.load(ordering: .acquiring) ? queued : 0,
            droppedSeconds: losses.totalDuration, receivedFrames: receivedFrames.load(ordering: .relaxed),
            peak: Float(bitPattern: peakBits.load(ordering: .relaxed)), failure: failure.load()?.message)
    }
    func fail(_ message: String) {
        guard accepting.load(ordering: .acquiring), failure.load() == nil else { return }
        _ = failure.storeIfNil(AudioFailureMessage(String(message.prefix(512))))
    }
    func close() {
        accepting.store(false, ordering: .releasing)
        for slot in slots {
            if let owned = slot.take() { consumedNanoseconds.wrappingAdd(owned.durationNanoseconds, ordering: .releasing) }
        }
    }

}

/// Native AVAudioConverter runs on the STT worker, never in the capture callback.
/// Each source owns a converter; the output retains the original frame's represented time.
final class AudioNormalizer {
    private var converter: AVAudioConverter?
    private var inputRate: Double = 0
    func convert(_ frame: CapturedAudio) throws -> [Float] {
        guard (8_000...384_000).contains(frame.sampleRate), frame.samples.count <= 768_000 else { throw AudioCaptureError.invalidFormat }
        if frame.sampleRate == 16_000 {
            if converter != nil { reset() }
            return frame.samples
        }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: frame.sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false) else { throw AudioCaptureError.invalidFormat }
        if inputRate != frame.sampleRate || converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
            inputRate = frame.sampleRate
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frame.samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(frame.samples.count) * 16_000 / frame.sampleRate) + 64)),
              let destination = input.floatChannelData?[0] else { throw AudioCaptureError.invalidFormat }
        input.frameLength = AVAudioFrameCount(frame.samples.count)
        frame.samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress { destination.update(from: base, count: pointer.count) }
        }
        // The converter invokes this callback synchronously. Ownership is transferred into
        // this lock and there are no other accesses to the PCM buffer during conversion.
        let inputState = OSAllocatedUnfairLock(uncheckedState: (buffer: input, offset: AVAudioFrameCount(0)))
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requestedPackets, inputStatus in
            inputState.withLockUnchecked { value in
                let remaining = value.buffer.frameLength - value.offset
                guard remaining > 0 else { inputStatus.pointee = .noDataNow; return nil }
                // Returning more than requested drops the tail with some hardware converters.
                let count = min(remaining, requestedPackets)
                guard count > 0,
                      let chunk = AVAudioPCMBuffer(pcmFormat: value.buffer.format, frameCapacity: count),
                      let source = value.buffer.floatChannelData?[0], let destination = chunk.floatChannelData?[0] else {
                    inputStatus.pointee = .noDataNow; return nil
                }
                chunk.frameLength = count
                destination.update(from: source.advanced(by: Int(value.offset)), count: Int(count))
                value.offset += count
                inputStatus.pointee = .haveData
                return chunk
            }
        }
        if let error { throw error }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw AudioCaptureError.invalidFormat }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
    func reset() { converter = nil; inputRate = 0 }
}

enum AudioCaptureError: LocalizedError {
    case denied, noDevice, noApplication, invalidFormat, configuration(String)
    var errorDescription: String? {
        switch self {
        case .denied: "Permission denied. Enable capture in System Settings, then resume."
        case .noDevice: "The selected microphone is unavailable. Choose an available microphone."
        case .noApplication: "The selected meeting application is unavailable. Select it again when running."
        case .invalidFormat: "The audio format could not be converted. Choose another device."
        case .configuration(let message): message
        }
    }
}
