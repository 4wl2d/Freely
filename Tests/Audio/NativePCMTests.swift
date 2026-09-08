import AVFoundation
import CoreMedia
import Testing
@testable import Freely

struct NativePCMTests {
    @Test func copiesFloatStereoBeforeNativeBufferIsReleased() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        pcm.frameLength = 1_024
        let channels = try #require(pcm.floatChannelData)
        for index in 0..<1_024 { channels[0][index] = 0.2; channels[1][index] = 0.6 }
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr)
        let desc = try #require(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: 40, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: desc, sampleCount: 1_024,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr)
        let buffer = try #require(sampleBuffer)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        let ingress = AudioIngress()
        ingress.receive(buffer)
        for index in 0..<1_024 { channels[0][index] = 0; channels[1][index] = 0 }
        #expect(ingress.snapshot().failure == nil)
        let frame = try #require(ingress.drain().first)
        #expect(frame.samples.count == 1_024)
        #expect(abs(frame.samples[0] - 0.4) < 0.0001)
        #expect(frame.timestamp == 40)
        #expect(frame.sampleRate == 48_000)
    }
}
