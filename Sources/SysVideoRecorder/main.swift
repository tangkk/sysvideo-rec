import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum OutputFormat: String, CaseIterable {
    case mp4H264 = "MP4 · H.264"
    case mp4HEVC = "MP4 · HEVC"
    case movH264 = "MOV · H.264"
    case movHEVC = "MOV · HEVC"

    var fileType: AVFileType { rawValue.hasPrefix("MP4") ? .mp4 : .mov }
    var codec: AVVideoCodecType { rawValue.contains("HEVC") ? .hevc : .h264 }
    var extensionName: String { fileType == .mp4 ? "mp4" : "mov" }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    let videoOutput = AVCaptureVideoDataOutput()
    private let device: AVCaptureDevice
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
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
        startedAt = nil
        isRecording = true
    }

    func stopRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            guard let writer = self.writer, let input = self.writerInput else { completion(.failure(RecorderError.writerSetup)); return }
            input.markAsFinished()
            writer.finishWriting {
                let result: Result<Void, Error> = writer.status == .completed ? .success(()) : .failure(writer.error ?? RecorderError.writerSetup)
                self.writer = nil; self.writerInput = nil; self.startedAt = nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, let writer, let input = writerInput else { return }
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

@available(macOS 12.3, *)
final class ScreenController: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "screen.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var size = CGSize.zero
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var startedAt: CMTime?
    private(set) var isRecording = false
    var onFrame: ((CMSampleBuffer) -> Void)?

    func startPreview() async throws -> String {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw RecorderError.writerSetup }
        size = CGSize(width: display.width, height: display.height)
        let config = SCStreamConfiguration()
        config.width = display.width; config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return "屏幕：\(display.width) × \(display.height)"
    }

    func stopPreview() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func startRecording(to url: URL, format: OutputFormat) throws {
        guard !isRecording, size.width > 0 else { throw RecorderError.writerSetup }
        let bitrate = max(4_000_000, min(24_000_000, Int(size.width * size.height) * 5))
        let settings: [String: Any] = [AVVideoCodecKey: format.codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalKey: 60]]
        writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput?.expectsMediaDataInRealTime = true
        guard let writer, let input = writerInput, writer.canAdd(input) else { throw RecorderError.writerSetup }
        writer.add(input); startedAt = nil; isRecording = true
    }

    func stopRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            guard let writer = self.writer, let input = self.writerInput else { completion(.failure(RecorderError.writerSetup)); return }
            input.markAsFinished()
            writer.finishWriting {
                let result: Result<Void, Error> = writer.status == .completed ? .success(()) : .failure(writer.error ?? RecorderError.writerSetup)
                self.writer = nil; self.writerInput = nil; self.startedAt = nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        DispatchQueue.main.async { self.onFrame?(sampleBuffer) }
        guard isRecording, let writer, let input = writerInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startedAt == nil { guard writer.startWriting() else { isRecording = false; return }; writer.startSession(atSourceTime: time); startedAt = time }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { isRecording = false }
}

@available(macOS 12.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CameraController?
    private var screenController: ScreenController?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let preview = AVCaptureVideoPreviewLayer()
    private let screenPreview = AVSampleBufferDisplayLayer()
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let output = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "准备中…")
    private var formats: [AVCaptureDevice.Format] = []
    private var destination: URL?
    private var isScreenMode: Bool { source.indexOfSelectedItem == 1 }

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
        preview.frame = NSRect(x: 16, y: 82, width: 828, height: 512); preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        screenPreview.frame = preview.frame; screenPreview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; screenPreview.videoGravity = .resizeAspect; screenPreview.isHidden = true
        root.layer = CALayer(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.addSublayer(preview); root.layer?.addSublayer(screenPreview)
        let bar = NSStackView(views: [NSTextField(labelWithString: "来源"), source, NSTextField(labelWithString: "分辨率"), resolution, NSTextField(labelWithString: "保存格式"), output, recordButton, status])
        bar.orientation = .horizontal; bar.spacing = 10; bar.alignment = .centerY
        bar.frame = NSRect(x: 16, y: 18, width: 828, height: 40); bar.autoresizingMask = [.width, .maxYMargin]
        source.widthAnchor.constraint(equalToConstant: 85).isActive = true
        resolution.widthAnchor.constraint(equalToConstant: 165).isActive = true
        output.widthAnchor.constraint(equalToConstant: 130).isActive = true
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(bar)
        OutputFormat.allCases.forEach { output.addItem(withTitle: $0.rawValue) }
        source.addItems(withTitles: ["摄像头", "屏幕"])
        source.target = self; source.action = #selector(changeSource)
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
        formats = controller.availableFormats()
        formats.forEach { resolution.addItem(withTitle: controller.label(for: $0)) }
        if let index = formats.firstIndex(where: { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == 1920 && d.height == 1080 }) { resolution.selectItem(at: index); try? controller.select(formats[index]) }
        controller.session.startRunning()
        recordButton.isEnabled = true; status.stringValue = "已连接：\(device.localizedName)"
    }

    @objc private func changeSource() {
        guard !((controller?.isRecording ?? false) || (screenController?.isRecording ?? false)) else { return }
        if isScreenMode {
            controller?.session.stopRunning(); preview.isHidden = true; screenPreview.isHidden = false
            resolution.removeAllItems(); resolution.addItem(withTitle: "连接屏幕中…"); resolution.isEnabled = false; recordButton.isEnabled = false
            guard #available(macOS 12.3, *) else { showError("录屏需要 macOS 12.3 或更高版本。"); return }
            let screen = ScreenController(); screen.onFrame = { [weak self] sample in self?.screenPreview.enqueue(sample) }; screenController = screen
            Task { do { let label = try await screen.startPreview(); await MainActor.run { self.resolution.removeAllItems(); self.resolution.addItem(withTitle: label); self.status.stringValue = "屏幕预览已就绪"; self.recordButton.isEnabled = true } } catch { await MainActor.run { self.showError("无法录制屏幕。请在“系统设置 → 隐私与安全性 → 屏幕录制”中允许终端访问。") } } }
        } else {
            screenPreview.flushAndRemoveImage(); screenPreview.isHidden = true; preview.isHidden = false
            Task { await screenController?.stopPreview() }; screenController = nil
            resolution.removeAllItems(); formats.forEach { resolution.addItem(withTitle: controller?.label(for: $0) ?? "") }; resolution.isEnabled = true
            controller?.session.startRunning(); recordButton.isEnabled = controller != nil; status.stringValue = "摄像头预览已就绪"
        }
    }

    @objc private func changeResolution() {
        guard let controller, resolution.indexOfSelectedItem >= 0 else { return }
        do { try controller.select(formats[resolution.indexOfSelectedItem]); status.stringValue = "分辨率已切换" }
        catch { showError("切换分辨率失败：\(error.localizedDescription)") }
    }

    @objc private func toggleRecording() {
        guard controller != nil else { return }
        if (isScreenMode ? screenController?.isRecording : controller?.isRecording) == true { finishRecording(); return }
        let format = OutputFormat.allCases[output.indexOfSelectedItem]
        let panel = NSSavePanel(); panel.title = "保存录制视频"; panel.nameFieldStringValue = "Camera-\(Self.timestamp()).\(format.extensionName)"; panel.allowedContentTypes = format.fileType == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { if self.isScreenMode { try self.screenController?.startRecording(to: url, format: format) } else { try self.controller?.startRecording(to: url, format: format) }; self.destination = url; self.recordButton.title = "停止并保存"; self.source.isEnabled = false; self.resolution.isEnabled = false; self.output.isEnabled = false; self.status.stringValue = "正在录制" }
            catch { self.showError("无法开始录制：\(error.localizedDescription)") }
        }
    }

    private func finishRecording() {
        guard let controller else { return }
        recordButton.isEnabled = false; status.stringValue = "正在写入文件…"
        let complete: (Result<Void, Error>) -> Void = { result in
            self.recordButton.isEnabled = true; self.recordButton.title = "开始录制"; self.source.isEnabled = true; self.resolution.isEnabled = !self.isScreenMode; self.output.isEnabled = true
            switch result { case .success: self.status.stringValue = "已保存：\(self.destination?.lastPathComponent ?? "视频")"; case .failure(let error): self.showError("保存失败：\(error.localizedDescription)") }
        }
        if isScreenMode { screenController?.stopRecording(completion: complete) } else { controller.stopRecording(completion: complete) }
    }

    private func showError(_ message: String) { status.stringValue = message; NSSound.beep() }
    private static func timestamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }
}

if #available(macOS 12.3, *) {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    fputs("sysvideo-rec requires macOS 12.3 or newer.\n", stderr)
}
