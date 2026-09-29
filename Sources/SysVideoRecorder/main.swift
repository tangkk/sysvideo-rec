import AppKit
import AVFoundation
import CoreMedia

final class BlackArrowPopUpButton: NSPopUpButton {
    override init(frame frameRect: NSRect, pullsDown flag: Bool) {
        super.init(frame: frameRect, pullsDown: flag)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        // Clipping to the button's own rounded shape means the black well
        // below can never spill outside the visible bezel, however it's sized.
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).addClip()

        let arrowRect = NSRect(x: bounds.maxX - 22, y: bounds.minY, width: 22, height: bounds.height)
        NSColor.black.setFill()
        NSBezierPath(rect: arrowRect).fill()

        // NSPopUpButton draws with a flipped coordinate system, so the vertex
        // needs the larger y value to point downward.
        NSColor.white.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.3
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: arrowRect.minX + 6, y: arrowRect.midY - 2.5))
        arrow.line(to: NSPoint(x: arrowRect.midX, y: arrowRect.midY + 2.5))
        arrow.line(to: NSPoint(x: arrowRect.maxX - 6, y: arrowRect.midY - 2.5))
        arrow.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }
}

enum OutputFormat: String, CaseIterable {
    case mp4H264 = "MP4 · H.264"
    case mp4HEVC = "MP4 · HEVC"
    case movH264 = "MOV · H.264"
    case movHEVC = "MOV · HEVC"

    var fileType: AVFileType { rawValue.hasPrefix("MP4") ? .mp4 : .mov }
    var codec: AVVideoCodecType { rawValue.contains("HEVC") ? .hevc : .h264 }
    var extensionName: String { fileType == .mp4 ? "mp4" : "mov" }
}

/// Computes a quick RMS/peak level from a raw microphone sample buffer, for
/// driving a live waveform display. Not involved in the actual recorded
/// audio path (AVAssetWriterInput consumes the original sample buffer).
func audioLevel(from sampleBuffer: CMSampleBuffer) -> (level: Double, peak: Double)? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
        return nil
    }
    let asbd = asbdPointer.pointee
    let channelCount = Int(asbd.mChannelsPerFrame)
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard channelCount > 0, frameCount > 0 else { return nil }

    var neededSize = 0
    var blockBuffer: CMBlockBuffer?
    let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &neededSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard sizingStatus == noErr, neededSize > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: neededSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard let firstBuffer = buffers.first, let data = firstBuffer.mData else { return nil }
    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let bitsPerChannel = Int(asbd.mBitsPerChannel)

    var sum = 0.0
    var peak = 0.0
    var count = 0

    if isFloat, bitsPerChannel == 32 {
        let available = min(frameCount * channelCount, Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<available {
            let normalized = Double(samples[i])
            sum += normalized * normalized
            peak = max(peak, abs(normalized))
            count += 1
        }
    } else if isSignedInteger, bitsPerChannel == 16 {
        let available = min(frameCount * channelCount, Int(firstBuffer.mDataByteSize) / MemoryLayout<Int16>.size)
        let samples = data.assumingMemoryBound(to: Int16.self)
        for i in 0..<available {
            let normalized = Double(samples[i]) / Double(Int16.max)
            sum += normalized * normalized
            peak = max(peak, abs(normalized))
            count += 1
        }
    } else {
        return nil
    }

    guard count > 0 else { return nil }
    return (sqrt(sum / Double(count)), peak)
}

/// Trims a passthrough (no re-encode) time range out of a recorded video into
/// a new file, mirroring sysaudio-rec's ffmpeg `-c copy` trim.
func exportTrimmedVideo(
    source: URL,
    destination: URL,
    start: Double,
    end: Double,
    fileType: AVFileType,
    completion: @escaping (Result<Void, Error>) -> Void
) {
    let asset = AVURLAsset(url: source)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        completion(.failure(RecorderError.writerSetup))
        return
    }
    exportSession.outputURL = destination
    exportSession.outputFileType = fileType
    exportSession.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        end: CMTime(seconds: end, preferredTimescale: 600)
    )
    exportSession.exportAsynchronously {
        DispatchQueue.main.async {
            if exportSession.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(exportSession.error ?? RecorderError.writerSetup))
            }
        }
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let device: AVCaptureDevice
    private var microphoneInput: AVCaptureDeviceInput?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var startedAt: CMTime?
    private(set) var isRecording = false

    /// Called (off the main thread) with a quick RMS/peak level for every
    /// microphone buffer received while recording, for driving a live waveform.
    var meterHandler: ((Double, Double) -> Void)?
    private var lastMeterNanos: UInt64 = 0

    init?(device: AVCaptureDevice) {
        self.device = device
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { return nil }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        session.commitConfiguration()
    }

    func availableFormats() -> [AVCaptureDevice.Format] {
        device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 320 && dimensions.height >= 240
        }.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }
    }

    func label(for format: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return "\(d.width) × \(d.height)  (up to \(Int(fps.rounded())) fps)"
    }

    func select(_ format: AVCaptureDevice.Format) throws {
        guard !isRecording else { return }
        try device.lockForConfiguration()
        device.activeFormat = format
        let range = format.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
        if let range { device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(min(30, range.maxFrameRate))) }
        device.unlockForConfiguration()
    }

    func setMicrophone(_ microphone: AVCaptureDevice) {
        guard !isRecording, let input = try? AVCaptureDeviceInput(device: microphone) else { return }
        session.beginConfiguration()
        if let microphoneInput { session.removeInput(microphoneInput) }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        guard session.canAddInput(input), session.canAddOutput(audioOutput) else { session.commitConfiguration(); return }
        session.addInput(input)
        microphoneInput = input
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(audioOutput)
        session.commitConfiguration()
    }

    func startRecording(to url: URL, format: OutputFormat) throws {
        guard !isRecording else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let bitrate = max(2_000_000, min(16_000_000, Int(dimensions.width * dimensions.height) * 5))
        let settings: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                               AVVideoMaxKeyFrameIntervalKey: 60]
        ]
        writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput?.expectsMediaDataInRealTime = true
        guard let writer, let writerInput, writer.canAdd(writerInput) else { throw RecorderError.writerSetup }
        writer.add(writerInput)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) && writer.canAdd(audioInput) { writer.add(audioInput); audioWriterInput = audioInput }
        startedAt = nil
        isRecording = true
    }

    func stopRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            guard let writer = self.writer, let input = self.writerInput else { completion(.failure(RecorderError.writerSetup)); return }
            input.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            writer.finishWriting {
                let result: Result<Void, Error> = writer.status == .completed ? .success(()) : .failure(writer.error ?? RecorderError.writerSetup)
                self.writer = nil; self.writerInput = nil; self.audioWriterInput = nil; self.startedAt = nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, let writer else { return }
        if output === audioOutput {
            emitMeter(for: sampleBuffer)
            guard startedAt != nil, let input = audioWriterInput else { return }
            if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
            return
        }
        guard let input = writerInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startedAt == nil {
            guard writer.startWriting() else { isRecording = false; return }
            writer.startSession(atSourceTime: time)
            startedAt = time
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    private func emitMeter(for sampleBuffer: CMSampleBuffer) {
        guard let meterHandler else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // ~60Hz metering, same throttle as sysaudio-rec, keeps this cheap
        // enough for the realtime capture queue.
        guard now - lastMeterNanos >= 16_000_000 else { return }
        lastMeterNanos = now
        guard let (level, peak) = audioLevel(from: sampleBuffer) else { return }
        meterHandler(level, peak)
    }
}

enum RecorderError: LocalizedError { case writerSetup; var errorDescription: String? { "Unable to create the video encoder." } }

/// Same rolling window + drawing formula as the original scrolling waveform.
/// Recording stops appending to it, so once stopped the bars simply stay put
/// — the trim UI only adds a selection overlay on top, it never redraws the
/// bars with different data.
final class LiveWaveformView: NSView {
    private var samples: [CGFloat] = []
    private var duration: Double = 0
    private var selStart: CGFloat = 0
    private var selEnd: CGFloat = 1
    private var playheadFraction: CGFloat?
    private(set) var isEditable = false

    private enum DragMode {
        case newSelection
        case moveStart
        case moveEnd
    }
    private var dragMode: DragMode?
    private var dragAnchor: CGFloat = 0
    private let minSelectionFraction: CGFloat = 0.01
    private let handleTolerance: CGFloat = 7

    var onSelectionChanged: ((Double, Double) -> Void)?

    func append(level: Double, peak: Double) {
        samples.append(CGFloat(min(1, max(level, peak))))
        if samples.count > 360 { samples.removeFirst(samples.count - 360) }
        needsDisplay = true
    }

    /// Called once a recording stops and its duration is known. This does not
    /// change what's drawn for the waveform bars themselves (append() is simply
    /// no longer called) — it only turns on the draggable trim selection overlay.
    func configureForPlayback(duration: Double) {
        self.duration = duration
        selStart = 0
        selEnd = 1
        playheadFraction = 0
        isEditable = true
        needsDisplay = true
    }

    func resetForNewRecording() {
        samples.removeAll()
        duration = 0
        selStart = 0
        selEnd = 1
        playheadFraction = nil
        isEditable = false
        dragMode = nil
        needsDisplay = true
    }

    func resetSelectionToFullRange() {
        guard isEditable else { return }
        selStart = 0
        selEnd = 1
        needsDisplay = true
        onSelectionChanged?(0, duration)
    }

    /// Moves the playhead marker to the given playback position, in seconds.
    func setPlayheadTime(_ seconds: Double) {
        guard isEditable, duration > 0 else { return }
        let fraction = CGFloat(max(0, min(1, seconds / duration)))
        guard playheadFraction != fraction else { return }
        playheadFraction = fraction
        needsDisplay = true
    }

    private func fraction(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return max(0, min(1, bounds.width > 0 ? point.x / bounds.width : 0))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let startX = selStart * bounds.width
        let endX = selEnd * bounds.width

        if abs(point.x - startX) <= handleTolerance {
            dragMode = .moveStart
        } else if abs(point.x - endX) <= handleTolerance {
            dragMode = .moveEnd
        } else {
            dragMode = .newSelection
            let clicked = fraction(for: event)
            dragAnchor = clicked
            selStart = clicked
            selEnd = clicked
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable, duration > 0, let mode = dragMode else { return }
        let current = fraction(for: event)

        switch mode {
        case .newSelection:
            if current < dragAnchor {
                selStart = current
                selEnd = dragAnchor
            } else {
                selStart = dragAnchor
                selEnd = current
            }
        case .moveStart:
            selStart = min(current, selEnd - minSelectionFraction)
        case .moveEnd:
            selEnd = max(current, selStart + minSelectionFraction)
        }
        needsDisplay = true
        onSelectionChanged?(Double(selStart) * duration, Double(selEnd) * duration)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        bounds.fill()
        let midY = bounds.midY

        if isEditable, duration > 0 {
            let selectionRect = NSRect(
                x: selStart * bounds.width,
                y: 0,
                width: (selEnd - selStart) * bounds.width,
                height: bounds.height
            )
            NSColor.systemBlue.withAlphaComponent(0.14).setFill()
            selectionRect.fill()
        }

        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        let center = NSBezierPath()
        center.move(to: NSPoint(x: bounds.minX, y: midY))
        center.line(to: NSPoint(x: bounds.maxX, y: midY))
        center.stroke()

        if !samples.isEmpty {
            let barWidth = max(1, bounds.width / CGFloat(samples.count) - 1)
            NSColor.systemRed.setFill()
            for (index, sample) in samples.enumerated() {
                let amplitude = max(0.02, sqrt(sample)) * bounds.height * 0.42
                let x = CGFloat(index) * (barWidth + 1)
                NSBezierPath(rect: NSRect(x: x, y: midY - amplitude, width: barWidth, height: amplitude * 2)).fill()
            }
        }

        if isEditable, duration > 0 {
            NSColor.systemBlue.setFill()
            let startX = selStart * bounds.width
            let endX = selEnd * bounds.width
            NSBezierPath(rect: NSRect(x: startX - 1.5, y: 0, width: 3, height: bounds.height)).fill()
            NSBezierPath(rect: NSRect(x: endX - 1.5, y: 0, width: 3, height: bounds.height)).fill()
        }

        if isEditable, duration > 0, let playheadFraction {
            let x = playheadFraction * bounds.width
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: x - 1, y: 0, width: 2, height: bounds.height)).fill()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x - 5, y: bounds.height))
            marker.line(to: NSPoint(x: x + 5, y: bounds.height))
            marker.line(to: NSPoint(x: x, y: bounds.height - 8))
            marker.close()
            marker.fill()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CameraController?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_030, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let preview = AVCaptureVideoPreviewLayer()
    private let microphone = BlackArrowPopUpButton(frame: .zero, pullsDown: false)
    private let resolution = BlackArrowPopUpButton(frame: .zero, pullsDown: false)
    private let output = BlackArrowPopUpButton(frame: .zero, pullsDown: false)
    private let recordButton = NSButton(title: "● Record", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Preparing…")
    private let waveform = LiveWaveformView(frame: .zero)
    private let trimLabel = NSTextField(labelWithString: "Trim: 00:00 – 00:00")
    private let resetTrimButton = NSButton(title: "Reset Trim", target: nil, action: nil)
    private let clearButton = NSButton(title: "✕ Clear", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save As…", target: nil, action: nil)
    private let playbackButton = NSButton(title: "▶ Play", target: nil, action: nil)
    private let playbackSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let playbackTime = NSTextField(labelWithString: "00:00 / 00:00")
    private var formats: [AVCaptureDevice.Format] = []
    private var microphones: [AVCaptureDevice] = []
    private weak var stage: NSView?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playbackTimer: Timer?

    private var recordingTempURL: URL?
    private var recordingFormat: OutputFormat?
    private var suggestedSaveURL: URL?
    private var trimBoundsInitialized = false
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var trimDuration: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        requestCamera()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let tempURL = recordingTempURL { try? FileManager.default.removeItem(at: tempURL) }
    }

    private func buildUI() {
        window.title = "sysvideo-rec · Web Media Inspector"
        window.center()
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.945, alpha: 1).cgColor
        window.contentView = root

        let stage = NSView(frame: NSRect(x: 16, y: 324, width: 998, height: 440))
        stage.autoresizingMask = [.width, .height]
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        stage.layer?.cornerRadius = 16
        stage.layer?.masksToBounds = true
        stage.layer?.borderWidth = 1
        stage.layer?.borderColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        root.addSubview(stage)
        self.stage = stage
        preview.videoGravity = .resizeAspect
        preview.frame = stage.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        stage.layer?.addSublayer(preview)

        func fieldLabel(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            label.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
            return label
        }
        let bar = NSStackView(views: [fieldLabel("Microphone"), microphone, fieldLabel("Resolution"), resolution, fieldLabel("Format"), output, recordButton, status])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.frame = NSRect(x: 16, y: 252, width: 998, height: 58)
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.cgColor
        bar.layer?.cornerRadius = 12
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        microphone.widthAnchor.constraint(equalToConstant: 165).isActive = true
        resolution.widthAnchor.constraint(equalToConstant: 165).isActive = true
        output.widthAnchor.constraint(equalToConstant: 130).isActive = true
        microphone.contentTintColor = .black
        resolution.contentTintColor = .black
        output.contentTintColor = .black
        recordButton.bezelColor = NSColor(calibratedRed: 0.73, green: 0.11, blue: 0.11, alpha: 1)
        recordButton.contentTintColor = .white
        status.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        status.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(bar)

        let waveformCard = NSView(frame: NSRect(x: 16, y: 128, width: 998, height: 110))
        waveformCard.autoresizingMask = [.width, .maxYMargin]
        waveformCard.wantsLayer = true
        waveformCard.layer?.backgroundColor = NSColor.white.cgColor
        waveformCard.layer?.cornerRadius = 12
        waveformCard.layer?.borderWidth = 1
        waveformCard.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        root.addSubview(waveformCard)
        waveform.frame = waveformCard.bounds.insetBy(dx: 8, dy: 8)
        waveform.autoresizingMask = [.width, .height]
        waveform.wantsLayer = true
        waveform.layer?.cornerRadius = 8
        waveformCard.addSubview(waveform)
        waveform.onSelectionChanged = { [weak self] start, end in
            guard let self else { return }
            self.trimStart = start
            self.trimEnd = end
            self.trimLabel.stringValue = "Trim: \(Self.playbackTimeString(start)) – \(Self.playbackTimeString(end))"
            self.playbackSlider.minValue = start
            self.playbackSlider.maxValue = end
            if let player = self.player, player.rate == 0 {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                self.playbackSlider.doubleValue = start
                self.waveform.setPlayheadTime(start)
            }
        }

        let playback = NSStackView(views: [fieldLabel("Playback"), playbackButton, playbackSlider, playbackTime])
        playback.orientation = .horizontal
        playback.spacing = 10
        playback.alignment = .centerY
        playback.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        playback.frame = NSRect(x: 16, y: 72, width: 998, height: 46)
        playback.autoresizingMask = [.width, .maxYMargin]
        playback.wantsLayer = true
        playback.layer?.backgroundColor = NSColor.white.cgColor
        playback.layer?.cornerRadius = 12
        playback.layer?.borderWidth = 1
        playback.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        playbackSlider.translatesAutoresizingMaskIntoConstraints = false
        playbackSlider.widthAnchor.constraint(equalToConstant: 500).isActive = true
        playbackTime.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        playbackTime.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.isEnabled = false
        playbackSlider.target = self
        playbackSlider.action = #selector(seekPlayback)
        playbackSlider.isContinuous = true
        playbackSlider.isEnabled = false
        root.addSubview(playback)

        let hintLabel = NSTextField(labelWithString: "Drag on the waveform above to set the trim range")
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        trimLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trimLabel.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        let actions = NSStackView(views: [clearButton, resetTrimButton, trimLabel, hintLabel, NSView(), saveButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        actions.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        actions.frame = NSRect(x: 16, y: 18, width: 998, height: 46)
        actions.autoresizingMask = [.width, .maxYMargin]
        actions.wantsLayer = true
        actions.layer?.backgroundColor = NSColor.white.cgColor
        actions.layer?.cornerRadius = 12
        actions.layer?.borderWidth = 1
        actions.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        clearButton.target = self
        clearButton.action = #selector(clearRecording)
        clearButton.isEnabled = false
        resetTrimButton.target = self
        resetTrimButton.action = #selector(resetTrim)
        resetTrimButton.isEnabled = false
        saveButton.target = self
        saveButton.action = #selector(saveRecording)
        saveButton.isEnabled = false
        saveButton.keyEquivalent = "\r"
        root.addSubview(actions)

        OutputFormat.allCases.forEach { output.addItem(withTitle: $0.rawValue) }
        microphone.target = self; microphone.action = #selector(changeMicrophone)
        microphone.isEnabled = false
        resolution.target = self; resolution.action = #selector(changeResolution)
        recordButton.target = self; recordButton.action = #selector(toggleRecording)
        recordButton.isEnabled = false
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { granted ? self.setupCamera() : self.showError("Allow camera access in System Settings → Privacy & Security → Camera.") } }
        default: showError("Camera access is not allowed. Enable it in System Settings → Privacy & Security → Camera.")
        }
    }

    private func setupCamera() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first, let controller = CameraController(device: device) else { showError("No camera was found."); return }
        self.controller = controller; preview.session = controller.session
        controller.meterHandler = { [weak self] level, peak in
            DispatchQueue.main.async { self?.waveform.append(level: level, peak: peak) }
        }
        loadMicrophones(prefer: device)
        formats = controller.availableFormats()
        formats.forEach { resolution.addItem(withTitle: controller.label(for: $0)) }
        if let index = formats.firstIndex(where: { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == 1920 && d.height == 1080 }) { resolution.selectItem(at: index); try? controller.select(formats[index]) }
        controller.session.startRunning()
        recordButton.isEnabled = true; status.stringValue = "Connected: \(device.localizedName)"
    }

    private func loadMicrophones(prefer camera: AVCaptureDevice? = nil) {
        microphones = AVCaptureDevice.devices(for: .audio)
        microphone.removeAllItems()
        microphones.forEach { microphone.addItem(withTitle: $0.localizedName) }
        guard !microphones.isEmpty else { microphone.addItem(withTitle: "No microphone found"); return }
        let preferred = microphones.firstIndex { candidate in
            guard let camera else { return false }
            let name = candidate.localizedName.lowercased()
            let cameraName = camera.localizedName.lowercased()
            return name.contains(cameraName) || cameraName.contains(name) || name.contains("webcam") || name.contains("usb") || name.contains("external")
        } ?? 0
        microphone.selectItem(at: preferred); microphone.isEnabled = true
        applyMicrophone()
    }

    private func applyMicrophone() {
        guard microphones.indices.contains(microphone.indexOfSelectedItem) else { return }
        let selected = microphones[microphone.indexOfSelectedItem]
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: configureMicrophone(selected)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { granted in if granted { DispatchQueue.main.async { self.configureMicrophone(selected) } } }
        default: status.stringValue = "Microphone access is not allowed"
        }
    }

    private func configureMicrophone(_ selected: AVCaptureDevice) {
        controller?.setMicrophone(selected)
        status.stringValue = "Microphone: \(selected.localizedName)"
    }

    @objc private func changeMicrophone() { applyMicrophone() }

    @objc private func changeResolution() {
        guard let controller, resolution.indexOfSelectedItem >= 0 else { return }
        do { try controller.select(formats[resolution.indexOfSelectedItem]); status.stringValue = "Resolution updated" }
        catch { showError("Could not change resolution: \(error.localizedDescription)") }
    }

    @objc private func toggleRecording() {
        guard let controller else { return }
        if controller.isRecording { stopRecording(); return }
        discardPendingRecording()
        let format = OutputFormat.allCases[output.indexOfSelectedItem]
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sysvideo-rec-\(UUID().uuidString).\(format.extensionName)")
        do {
            try controller.startRecording(to: tempURL, format: format)
            recordingTempURL = tempURL
            recordingFormat = format
            recordButton.title = "■ Stop recording"
            microphone.isEnabled = false; resolution.isEnabled = false; output.isEnabled = false
            status.stringValue = "Recording"
        } catch {
            showError("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let controller else { return }
        recordButton.isEnabled = false; status.stringValue = "Finishing video…"
        let complete: (Result<Void, Error>) -> Void = { result in
            self.recordButton.isEnabled = true; self.recordButton.title = "● Record"; self.microphone.isEnabled = !self.microphones.isEmpty; self.resolution.isEnabled = true; self.output.isEnabled = true
            switch result {
            case .success:
                guard let tempURL = self.recordingTempURL else { return }
                self.status.stringValue = "Recording ready — trim it, then Save As…"
                self.suggestedSaveURL = self.freshSuggestedSaveURL()
                self.clearButton.isEnabled = true
                self.preparePlayback(url: tempURL)
            case .failure(let error):
                self.showError("Could not finish recording: \(error.localizedDescription)")
                self.recordingTempURL = nil
            }
        }
        controller.stopRecording(completion: complete)
    }

    private func freshSuggestedSaveURL() -> URL {
        let format = recordingFormat ?? .mp4H264
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("Camera-\(Self.timestamp()).\(format.extensionName)")
    }

    private func preparePlayback(url: URL) {
        clearPlayback()
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        let layer = AVPlayerLayer(player: newPlayer)
        layer.videoGravity = .resizeAspect
        layer.frame = stage?.bounds ?? .zero
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        stage?.layer?.addSublayer(layer)
        playerLayer = layer
        preview.isHidden = true
        playbackButton.isEnabled = true
        playbackSlider.isEnabled = true
        let newTimer = Timer(timeInterval: 0.1, target: self, selector: #selector(updatePlaybackUI), userInfo: nil, repeats: true)
        RunLoop.main.add(newTimer, forMode: .common)
        playbackTimer = newTimer
        updatePlaybackUI()
    }

    private func clearPlayback() {
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        preview.isHidden = false
        playbackButton.title = "▶ Play"
        playbackButton.isEnabled = false
        playbackSlider.doubleValue = 0
        playbackSlider.isEnabled = false
        playbackTime.stringValue = "00:00 / 00:00"
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            playbackButton.title = "❚❚ Pause"
            let current = player.currentTime().seconds
            if current < trimStart - 0.01 || current >= trimEnd - 0.02 {
                // seek(to:) is asynchronous — play() called right after it can
                // start from the pre-seek position if the seek hasn't landed
                // yet, silently ignoring the trim start. Only play once the
                // seek's completion handler confirms it actually moved.
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player?.play()
                }
            } else {
                player.play()
            }
        } else {
            player.pause()
            playbackButton.title = "▶ Play"
        }
    }

    @objc private func seekPlayback() {
        guard let player else { return }
        let clamped = min(max(playbackSlider.doubleValue, trimStart), trimEnd)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        waveform.setPlayheadTime(clamped)
        updatePlaybackUI()
    }

    @objc private func updatePlaybackUI() {
        guard let player else { return }
        var current = max(0, player.currentTime().seconds)
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return }

        if !trimBoundsInitialized {
            trimBoundsInitialized = true
            trimDuration = duration
            trimStart = 0
            trimEnd = duration
            trimLabel.stringValue = "Trim: \(Self.playbackTimeString(0)) – \(Self.playbackTimeString(duration))"
            waveform.configureForPlayback(duration: duration)
            resetTrimButton.isEnabled = true
            saveButton.isEnabled = true
            playbackSlider.minValue = 0
            playbackSlider.maxValue = duration
        }

        // Preview playback never runs past the trimmed range.
        if player.rate != 0, current >= trimEnd - 0.03 {
            player.pause()
            player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
            playbackButton.title = "▶ Play"
            current = trimStart
        }

        let displayed = max(0, min(current, duration))
        playbackSlider.doubleValue = displayed
        playbackTime.stringValue = "\(Self.playbackTimeString(displayed)) / \(Self.playbackTimeString(duration))"
        waveform.setPlayheadTime(displayed)
    }

    @objc private func resetTrim() {
        waveform.resetSelectionToFullRange()
    }

    @objc private func saveRecording() {
        guard let tempURL = recordingTempURL, let format = recordingFormat else { return }
        let start = trimStart
        let end = trimEnd
        guard start < end else {
            status.stringValue = "Trim start must be before trim end"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Recording"
        let suggested = suggestedSaveURL ?? freshSuggestedSaveURL()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = format.fileType == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.performSave(from: tempURL, to: destination, start: start, end: end, duration: self.trimDuration, fileType: format.fileType)
        }
    }

    private func performSave(from source: URL, to destination: URL, start: Double, end: Double, duration: Double, fileType: AVFileType) {
        status.stringValue = "Saving…"
        saveButton.isEnabled = false
        let isFullRange = start <= 0.05 && end >= duration - 0.05

        if isFullRange {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: source, to: destination)
                    DispatchQueue.main.async {
                        self.status.stringValue = "Saved: \(destination.path)"
                        self.saveButton.isEnabled = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.status.stringValue = "Save failed: \(error.localizedDescription)"
                        self.saveButton.isEnabled = true
                    }
                }
            }
            return
        }

        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: destination) }
        exportTrimmedVideo(source: source, destination: destination, start: start, end: end, fileType: fileType) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status.stringValue = "Saved: \(destination.path)"
            case .failure(let error):
                self.status.stringValue = "Save failed: \(error.localizedDescription)"
            }
            self.saveButton.isEnabled = true
        }
    }

    @objc private func clearRecording() {
        discardPendingRecording()
        status.stringValue = "Ready to record"
    }

    private func discardPendingRecording() {
        clearPlayback()
        if let tempURL = recordingTempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        recordingTempURL = nil
        recordingFormat = nil
        suggestedSaveURL = nil
        waveform.resetForNewRecording()

        trimBoundsInitialized = false
        trimStart = 0
        trimEnd = 0
        trimDuration = 0
        trimLabel.stringValue = "Trim: 00:00 – 00:00"
        resetTrimButton.isEnabled = false
        saveButton.isEnabled = false
        clearButton.isEnabled = false
        playbackSlider.minValue = 0
        playbackSlider.maxValue = 1
    }

    private static func playbackTimeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func showError(_ message: String) { status.stringValue = message; NSSound.beep() }
    private static func timestamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
