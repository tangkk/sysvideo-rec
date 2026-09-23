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
        return "\(d.width) × \(d.height)  (最高 \(Int(fps.rounded())) fps)"
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

enum RecorderError: LocalizedError { case writerSetup; var errorDescription: String? { "无法创建视频编码器。" } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CameraController?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_030, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let preview = AVCaptureVideoPreviewLayer()
    private let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let output = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "准备中…")
    private var formats: [AVCaptureDevice.Format] = []
    private var microphones: [AVCaptureDevice] = []
    private var destination: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        requestCamera()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildUI() {
        window.title = "视频录制"
        window.center()
        let root = NSView(frame: window.contentView!.bounds); root.autoresizingMask = [.width, .height]
        window.contentView = root
        preview.videoGravity = .resizeAspect
        preview.frame = NSRect(x: 16, y: 82, width: 998, height: 512); preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer = CALayer(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.addSublayer(preview)
        let bar = NSStackView(views: [NSTextField(labelWithString: "麦克风"), microphone, NSTextField(labelWithString: "分辨率"), resolution, NSTextField(labelWithString: "保存格式"), output, recordButton, status])
        bar.orientation = .horizontal; bar.spacing = 10; bar.alignment = .centerY
        bar.frame = NSRect(x: 16, y: 18, width: 998, height: 40); bar.autoresizingMask = [.width, .maxYMargin]
        microphone.widthAnchor.constraint(equalToConstant: 165).isActive = true
        resolution.widthAnchor.constraint(equalToConstant: 165).isActive = true
        output.widthAnchor.constraint(equalToConstant: 130).isActive = true
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(bar)
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
            AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { granted ? self.setupCamera() : self.showError("请在“系统设置 → 隐私与安全性 → 相机”中允许访问相机。") } }
        default: showError("没有相机访问权限。请在“系统设置 → 隐私与安全性 → 相机”中允许访问相机。")
        }
    }

    private func setupCamera() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first, let controller = CameraController(device: device) else { showError("未找到可用摄像头。"); return }
        self.controller = controller; preview.session = controller.session
        loadMicrophones(prefer: device)
        formats = controller.availableFormats()
        formats.forEach { resolution.addItem(withTitle: controller.label(for: $0)) }
        if let index = formats.firstIndex(where: { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == 1920 && d.height == 1080 }) { resolution.selectItem(at: index); try? controller.select(formats[index]) }
        controller.session.startRunning()
        recordButton.isEnabled = true; status.stringValue = "已连接：\(device.localizedName)"
    }

    private func loadMicrophones(prefer camera: AVCaptureDevice? = nil) {
        microphones = AVCaptureDevice.devices(for: .audio)
        microphone.removeAllItems()
        microphones.forEach { microphone.addItem(withTitle: $0.localizedName) }
        guard !microphones.isEmpty else { microphone.addItem(withTitle: "未找到麦克风"); return }
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
        default: status.stringValue = "未授权麦克风"
        }
    }

    private func configureMicrophone(_ selected: AVCaptureDevice) {
        controller?.setMicrophone(selected)
        status.stringValue = "麦克风：\(selected.localizedName)"
    }

    @objc private func changeMicrophone() { applyMicrophone() }

    @objc private func changeResolution() {
        guard let controller, resolution.indexOfSelectedItem >= 0 else { return }
        do { try controller.select(formats[resolution.indexOfSelectedItem]); status.stringValue = "分辨率已切换" }
        catch { showError("切换分辨率失败：\(error.localizedDescription)") }
    }

    @objc private func toggleRecording() {
        guard let controller else { return }
        if controller.isRecording { finishRecording(); return }
        let format = OutputFormat.allCases[output.indexOfSelectedItem]
        let panel = NSSavePanel(); panel.title = "保存录制视频"; panel.nameFieldStringValue = "Camera-\(Self.timestamp()).\(format.extensionName)"; panel.allowedContentTypes = format.fileType == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.controller?.startRecording(to: url, format: format); self.destination = url; self.recordButton.title = "停止并保存"; self.microphone.isEnabled = false; self.resolution.isEnabled = false; self.output.isEnabled = false; self.status.stringValue = "正在录制" }
            catch { self.showError("无法开始录制：\(error.localizedDescription)") }
        }
    }

    private func finishRecording() {
        guard let controller else { return }
        recordButton.isEnabled = false; status.stringValue = "正在写入文件…"
        let complete: (Result<Void, Error>) -> Void = { result in
            self.recordButton.isEnabled = true; self.recordButton.title = "开始录制"; self.microphone.isEnabled = !self.microphones.isEmpty; self.resolution.isEnabled = true; self.output.isEnabled = true
            switch result { case .success: self.status.stringValue = "已保存：\(self.destination?.lastPathComponent ?? "视频")"; case .failure(let error): self.showError("保存失败：\(error.localizedDescription)") }
        }
        controller.stopRecording(completion: complete)
    }

    private func showError(_ message: String) { status.stringValue = message; NSSound.beep() }
    private static func timestamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
