import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

struct CoreAudioInputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let sampleRate: Double
    let channelCount: Int
}

enum CoreAudioInputError: LocalizedError {
    case operation(String, OSStatus)
    case unsupportedFormat(Int)
    case unavailableChannel(Int, Int)

    var errorDescription: String? {
        switch self {
        case let .operation(name, status): return "\(name) failed (CoreAudio \(status))"
        case let .unsupportedFormat(channels): return "Unsupported CoreAudio input format (\(channels) channels)"
        case let .unavailableChannel(requested, available): return "CH\(requested) is unavailable in the CoreAudio stream (\(available) channels)"
        }
    }
}

private func requireAudioStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioInputError.operation(operation, status) }
}

private func audioProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, as type: T.Type) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    try requireAudioStatus(AudioObjectGetPropertyData(id, &address, 0, nil, &size, value), "AudioObjectGetPropertyData(\(selector))")
    return value.pointee
}

func coreAudioInputDevices() throws -> [CoreAudioInputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices), mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal), mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var size: UInt32 = 0
    try requireAudioStatus(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "List audio devices")
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    try requireAudioStatus(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "Read audio devices")

    return try ids.compactMap { id in
        var configAddress = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration), mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeInput), mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var configSize: UInt32 = 0
        try requireAudioStatus(AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil, &configSize), "Read input channel count")
        guard configSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try requireAudioStatus(AudioObjectGetPropertyData(id, &configAddress, 0, nil, &configSize, raw), "Read input channel layout")
        let buffers = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        let name: CFString = try audioProperty(id, AudioObjectPropertySelector(kAudioObjectPropertyName), AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal), as: CFString.self)
        let uid: CFString = try audioProperty(id, AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID), AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal), as: CFString.self)
        let rate: Float64 = try audioProperty(id, AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate), AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal), as: Float64.self)
        return CoreAudioInputDevice(id: id, name: name as String, uid: uid as String, sampleRate: Double(rate), channelCount: channels)
    }
}

final class CoreAudioInputCapture {
    private let device: CoreAudioInputDevice
    private let onBuffer: (Data, CMTime, Int, Double) -> Void
    private var queue: AudioQueueRef?
    private var running = false
    private(set) var streamChannels = 0
    private var streamRate = 0.0
    private let lock = NSLock()

    init(device: CoreAudioInputDevice, onBuffer: @escaping (Data, CMTime, Int, Double) -> Void) {
        self.device = device
        self.onBuffer = onBuffer
    }

    func start() throws {
        let requestedRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        var format = AudioStreamBasicDescription(mSampleRate: requestedRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(device.channelCount * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(device.channelCount * 2), mChannelsPerFrame: UInt32(device.channelCount), mBitsPerChannel: 16, mReserved: 0)
        var newQueue: AudioQueueRef?
        try requireAudioStatus(AudioQueueNewInput(&format, { userData, queue, buffer, startTime, packetCount, _ in
            guard let userData else { return }
            let capture = Unmanaged<CoreAudioInputCapture>.fromOpaque(userData).takeUnretainedValue()
            capture.handleBuffer(queue: queue, buffer: buffer, startTime: startTime, packetCount: packetCount)
        }, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &newQueue), "AudioQueueNewInput")
        guard let newQueue else { throw CoreAudioInputError.operation("AudioQueueNewInput", -1) }
        do {
            var uid = device.uid as CFString
            try requireAudioStatus(withUnsafePointer(to: &uid) { AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }, "Select input device")
            var actual = AudioStreamBasicDescription()
            var actualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try requireAudioStatus(AudioQueueGetProperty(newQueue, kAudioQueueProperty_StreamDescription, &actual, &actualSize), "Read input format")
            guard actual.mFormatID == kAudioFormatLinearPCM,
                  actual.mBitsPerChannel == 16,
                  (actual.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0,
                  (actual.mFormatFlags & kAudioFormatFlagIsPacked) != 0,
                  (actual.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
                  actual.mChannelsPerFrame > 0,
                  actual.mBytesPerFrame == actual.mChannelsPerFrame * 2 else {
                throw CoreAudioInputError.unsupportedFormat(Int(actual.mChannelsPerFrame))
            }
            streamChannels = Int(actual.mChannelsPerFrame)
            streamRate = actual.mSampleRate
            let framesPerBuffer = UInt32(max(256, actual.mSampleRate / 50))
            let bytes = max(UInt32(4096), framesPerBuffer * actual.mBytesPerFrame)
            for _ in 0..<8 {
                var buffer: AudioQueueBufferRef?
                try requireAudioStatus(AudioQueueAllocateBuffer(newQueue, bytes, &buffer), "Allocate audio buffer")
                if let buffer { try requireAudioStatus(AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil), "Queue audio buffer") }
            }
            lock.lock(); queue = newQueue; running = true; lock.unlock()
            try requireAudioStatus(AudioQueueStart(newQueue, nil), "Start audio capture")
        } catch {
            lock.lock(); queue = nil; running = false; lock.unlock()
            AudioQueueDispose(newQueue, true)
            throw error
        }
    }

    func stop() {
        lock.lock(); let active = queue; queue = nil; running = false; lock.unlock()
        if let active { AudioQueueStop(active, true); AudioQueueDispose(active, true) }
    }

    private func handleBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef, startTime: UnsafePointer<AudioTimeStamp>, packetCount: UInt32) {
        lock.lock(); let active = running; lock.unlock()
        guard active else { return }
        let bytes = Int(buffer.pointee.mAudioDataByteSize)
        if packetCount > 0, bytes > 0 {
            let data = Data(bytes: buffer.pointee.mAudioData, count: bytes)
            let time: CMTime
            // kAudioTimeStampHostTimeValid is bit 1 in CoreAudioBaseTypes.
            if (startTime.pointee.mFlags.rawValue & (1 << 1)) != 0 {
                time = CMTime(value: Int64(AudioConvertHostTimeToNanos(startTime.pointee.mHostTime)), timescale: 1_000_000_000)
            } else {
                time = CMClockGetTime(CMClockGetHostTimeClock())
            }
            onBuffer(data, time, streamChannels, streamRate)
        }
        lock.lock(); let shouldRequeue = running; lock.unlock()
        if shouldRequeue { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
    }
}
