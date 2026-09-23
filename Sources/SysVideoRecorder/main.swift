import AppKit
import AVFoundation
import CoreMedia

enum OutputFormat: String, CaseIterable {
    case mp4H264 = "MP4 · H.264"
    case mp4HEVC = "MP4 · HEVC"
    case movH264 = "MOV · H.264"
    case movHEVC = "MOV · HEVC"

    var fileType: AVFileType { rawValue.hasPrefix("MP4") ? .mp4 : .mov }
    var codec: AVVideoCodecType { rawValue.contains("HEVC") ? .hevc : .h264 }
    var extensionName: String { fileType == .mp4 ? "mp4" : "mov" }
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
}

enum RecorderError: LocalizedError { case writerSetup; var errorDescription: String? { "Unable to create the video encoder." } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CameraController?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_030, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let preview = AVCaptureVideoPreviewLayer()
    private let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let output = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Preparing…")
    private let playbackButton = NSButton(title: "▶ Play", target: nil, action: nil)
    private let playbackSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let playbackTime = NSTextField(labelWithString: "00:00 / 00:00")
    private var formats: [AVCaptureDevice.Format] = []
    private var microphones: [AVCaptureDevice] = []
    private var destination: URL?
    private weak var stage: NSView?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playbackTimer: Timer?
    private var playbackBar: NSStackView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        requestCamera()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildUI() {
        window.title = "sysvideo-rec · Web Media Inspector"
        window.center()
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.945, alpha: 1).cgColor
        window.contentView = root

        let stage = NSView(frame: NSRect(x: 16, y: 154, width: 998, height: 440))
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
        bar.frame = NSRect(x: 16, y: 82, width: 998, height: 58)
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.cgColor
        bar.layer?.cornerRadius = 12
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        microphone.widthAnchor.constraint(equalToConstant: 165).isActive = true
        resolution.widthAnchor.constraint(equalToConstant: 165).isActive = true
        output.widthAnchor.constraint(equalToConstant: 130).isActive = true
        recordButton.bezelColor = NSColor(calibratedRed: 0.73, green: 0.11, blue: 0.11, alpha: 1)
        recordButton.contentTintColor = .white
        status.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        status.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(bar)

        let playback = NSStackView(views: [fieldLabel("Playback"), playbackButton, playbackSlider, playbackTime])
        playback.orientation = .horizontal
        playback.spacing = 10
        playback.alignment = .centerY
        playback.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        playback.frame = NSRect(x: 16, y: 18, width: 998, height: 46)
        playback.autoresizingMask = [.width, .maxYMargin]
        playback.wantsLayer = true
        playback.layer?.backgroundColor = NSColor.white.cgColor
        playback.layer?.cornerRadius = 12
        playback.layer?.borderWidth = 1
        playback.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        playback.isHidden = true
        playbackSlider.translatesAutoresizingMaskIntoConstraints = false
        playbackSlider.widthAnchor.constraint(equalToConstant: 500).isActive = true
        playbackTime.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        playbackTime.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackSlider.target = self
        playbackSlider.action = #selector(seekPlayback)
        playbackSlider.isContinuous = true
        root.addSubview(playback)
        playbackBar = playback
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
        if controller.isRecording { finishRecording(); return }
        clearPlayback()
        let format = OutputFormat.allCases[output.indexOfSelectedItem]
        let panel = NSSavePanel(); panel.title = "Save recorded video"; panel.nameFieldStringValue = "Camera-\(Self.timestamp()).\(format.extensionName)"; panel.allowedContentTypes = format.fileType == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.controller?.startRecording(to: url, format: format); self.destination = url; self.recordButton.title = "Stop and save"; self.microphone.isEnabled = false; self.resolution.isEnabled = false; self.output.isEnabled = false; self.status.stringValue = "Recording" }
            catch { self.showError("Could not start recording: \(error.localizedDescription)") }
        }
    }

    private func finishRecording() {
        guard let controller else { return }
        recordButton.isEnabled = false; status.stringValue = "Writing file…"
        let complete: (Result<Void, Error>) -> Void = { result in
            self.recordButton.isEnabled = true; self.recordButton.title = "Start recording"; self.microphone.isEnabled = !self.microphones.isEmpty; self.resolution.isEnabled = true; self.output.isEnabled = true
            switch result {
            case .success:
                self.status.stringValue = "Saved: \(self.destination?.lastPathComponent ?? "video")"
                if let destination = self.destination { self.preparePlayback(url: destination) }
            case .failure(let error):
                self.showError("Could not save: \(error.localizedDescription)")
            }
        }
        controller.stopRecording(completion: complete)
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
        playbackBar?.isHidden = false
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
        playbackBar?.isHidden = true
        playbackButton.title = "▶ Play"
        playbackSlider.doubleValue = 0
        playbackTime.stringValue = "00:00 / 00:00"
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        if player.rate == 0 {
            if duration.isFinite, player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
            playbackButton.title = "❚❚ Pause"
        } else {
            player.pause()
            playbackButton.title = "▶ Play"
        }
    }

    @objc private func seekPlayback() {
        guard let player else { return }
        player.seek(to: CMTime(seconds: playbackSlider.doubleValue, preferredTimescale: 600))
        updatePlaybackUI()
    }

    @objc private func updatePlaybackUI() {
        guard let player else { return }
        let current = max(0, player.currentTime().seconds)
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return }
        playbackSlider.maxValue = duration
        playbackSlider.doubleValue = min(current, duration)
        playbackTime.stringValue = "\(Self.playbackTime(current)) / \(Self.playbackTime(duration))"
        if current >= duration - 0.05, player.rate == 0 { playbackButton.title = "▶ Play" }
    }

    private static func playbackTime(_ seconds: Double) -> String {
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
