import AudioToolbox
import CoreMedia
import Foundation

func videoAudioLevel(from data: Data, inputChannels: Int, selectedChannel: Int?) -> (level: Double, peak: Double)? {
    guard inputChannels > 0,
          selectedChannel.map({ (0..<inputChannels).contains($0) }) ?? true else { return nil }
    let frames = data.count / (inputChannels * MemoryLayout<Int16>.size)
    guard frames > 0 else { return nil }
    let meteredChannels = selectedChannel == nil ? min(inputChannels, 2) : 1
    var sum = 0.0
    var peak = 0.0
    data.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for frame in 0..<frames {
            for channel in 0..<meteredChannels {
                let value = Double(samples[frame * inputChannels + (selectedChannel ?? channel)]) / Double(Int16.max)
                sum += value * value
                peak = max(peak, abs(value))
            }
        }
    }
    return (sqrt(sum / Double(frames * meteredChannels)), peak)
}

/// Takes the exact CoreAudio input channel selected by the user and gives
/// AVAssetWriter a mono (or first-two-channel stereo) PCM sample buffer.
func videoAudioSampleBuffer(
    from data: Data,
    sampleRate: Double,
    inputChannels: Int,
    selectedChannel: Int?,
    at time: CMTime
) -> (buffer: CMSampleBuffer, level: Double, peak: Double)? {
    guard inputChannels > 0,
          selectedChannel.map({ (0..<inputChannels).contains($0) }) ?? true,
          sampleRate > 0 else { return nil }
    let frameCount = data.count / (inputChannels * MemoryLayout<Int16>.size)
    guard frameCount > 0 else { return nil }
    let outputChannels = selectedChannel == nil ? min(inputChannels, 2) : 1
    var output = Data(count: frameCount * outputChannels * MemoryLayout<Int16>.size)
    var sum = 0.0
    var peak = 0.0
    data.withUnsafeBytes { sourceRaw in
        output.withUnsafeMutableBytes { outputRaw in
            let source = sourceRaw.bindMemory(to: Int16.self)
            let destination = outputRaw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<outputChannels {
                    let inputChannel = selectedChannel ?? channel
                    let sample = source[frame * inputChannels + inputChannel]
                    destination[frame * outputChannels + channel] = sample
                    let value = Double(sample) / Double(Int16.max)
                    sum += value * value
                    peak = max(peak, abs(value))
                }
            }
        }
    }

    var format = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(outputChannels * 2),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(outputChannels * 2),
        mChannelsPerFrame: UInt32(outputChannels),
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var description: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
          let description else { return nil }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: output.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: output.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
          let block else { return nil }
    let copyStatus = output.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: output.count)
    }
    guard copyStatus == kCMBlockBufferNoErr else { return nil }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
        presentationTimeStamp: time,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr,
          let sampleBuffer else { return nil }
    return (sampleBuffer, sqrt(sum / Double(frameCount * outputChannels)), peak)
}
