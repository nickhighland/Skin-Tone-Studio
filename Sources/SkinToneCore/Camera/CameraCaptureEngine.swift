@preconcurrency import AVFoundation
import AppKit
import CoreImage
import OSLog
import SwiftUI

public struct CameraChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isExternal: Bool

    public init(id: String, name: String, isExternal: Bool) {
        self.id = id
        self.name = name
        self.isExternal = isExternal
    }
}

public final class PreviewSurface: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.updateVisibility() })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in self?.updateVisibility() })
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        visibilityChanged?(visible && !NSApp.isHidden)
    }

    fileprivate func display(_ image: CGImage?) { layer?.contents = image }
}

public struct CameraPreview: NSViewRepresentable {
    private let engine: CameraCaptureEngine

    public init(engine: CameraCaptureEngine) { self.engine = engine }

    public func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.visibilityChanged = { [weak engine] visible in engine?.setPreviewVisible(visible) }
        engine.previewSurface = view
        return view
    }

    public func updateNSView(_ nsView: PreviewSurface, context: Context) {
        engine.previewSurface = nsView
    }

    public static func dismantleNSView(_ nsView: PreviewSurface, coordinator: ()) {
        nsView.visibilityChanged?(false)
        nsView.visibilityChanged = nil
    }
}

/// Camera controls live in AppModel/UVCController. This object owns only an optional preview,
/// and gives the video stream back to meeting apps whenever it is hidden or another app opens it.
@MainActor
public final class CameraCaptureEngine: ObservableObject {
    @Published public private(set) var state: CameraPreviewState = .idle
    public weak var previewSurface: PreviewSurface?
    public var onCameraActivity: (() -> Void)?

    private let worker = CameraCaptureWorker()
    private var workspaceTokens: [NSObjectProtocol] = []

    public init() {
        worker.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.state = state
                if state != .running { self.previewSurface?.display(nil) }
            }
        }
        worker.onCameraActivity = { [weak self] in
            Task { @MainActor in self?.onCameraActivity?() }
        }
        worker.frames.deliver = { [weak self] image in self?.previewSurface?.display(image) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.worker.setSuspended(true) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.worker.setSuspended(false) }
        })
        worker.beginMonitoring()
    }

    deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        worker.shutdown()
    }

    nonisolated public static func availableDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        return discovery.devices.sorted {
            let leftExternal = $0.deviceType == .external
            let rightExternal = $1.deviceType == .external
            if leftExternal != rightExternal { return leftExternal }
            return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    public func select(device: AVCaptureDevice?) { worker.select(device: device) }
    public func setPreviewVisible(_ visible: Bool) { worker.setVisible(visible) }
    public func retry() { worker.retry() }
}

/// A single latest frame is allowed to wait for the main thread. A hidden/busy UI cannot retain
/// an unbounded queue of full-size camera images, and stale sessions cannot repaint the preview.
private final class PreviewFrameRelay {
    var deliver: ((CGImage) -> Void)?
    private let lock = NSLock()
    private var generation = 0
    private var latest: CGImage?
    private var pendingDelivery = false

    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        latest = nil
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    func publish(_ image: CGImage, token: Int) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        latest = image
        let enqueue = !pendingDelivery
        pendingDelivery = true
        lock.unlock()
        guard enqueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let image = self.latest
            self.latest = nil
            self.pendingDelivery = false
            self.lock.unlock()
            if let image { self.deliver?(image) }
        }
    }
}

private final class PreviewFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let token: Int
    private let relay: PreviewFrameRelay
    private let receivedFrame: () -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastRenderTime = 0.0

    init(token: Int, relay: PreviewFrameRelay, receivedFrame: @escaping () -> Void) {
        self.token = token
        self.relay = relay
        self.receivedFrame = receivedFrame
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard relay.isCurrent(token), CMSampleBufferIsValid(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: buffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRenderTime >= 1.0 / 20.0 else { return }
        lastRenderTime = now
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: buffer)
            // Scale the preview only. Never change the camera's format for a small on-screen view.
            let scale = min(1, 1280 / input.extent.width)
            let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let rendered = context.createCGImage(image, from: image.extent),
                  relay.isCurrent(token) else { return }
            relay.publish(rendered, token: token)
            receivedFrame()
        }
    }
}

/// Mutable capture/device state is confined to queue. A new AVCaptureSession is built for each
/// recovery so old input, decoder, and output state cannot survive a failed browser handoff.
private final class CameraCaptureWorker {
    var onState: ((CameraPreviewState) -> Void)?
    var onCameraActivity: (() -> Void)?
    let frames = PreviewFrameRelay()

    private let queue = DispatchQueue(label: "studio.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "studio.camera.frames", qos: .userInitiated)
    private let logger = Logger(subsystem: "studio.skintone.camera", category: "Capture")
    private var device: AVCaptureDevice?
    private var deviceObservation: NSKeyValueObservation?
    private var formatObservation: NSKeyValueObservation?
    private var usageMonitor: CameraUsageMonitor?
    private var selectionGeneration = 0
    private var session: AVCaptureSession?
    private var processor: PreviewFrameProcessor?
    private var sessionTokens: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var lastOtherAppUse = false
    private var sessionStartedAt = 0.0

    private lazy var lifecycle = CaptureLifecycle(
        start: { [weak self] id in try self?.startSession(deviceID: id) },
        stop: { [weak self] in self?.stopSession() },
        stateChanged: { [weak self] state in
            self?.logger.info("Preview state: \(state.title, privacy: .public)")
            self?.onState?(state)
        },
        streamStarted: { [weak self] in self?.onCameraActivity?() },
        log: { [weak self] message in self?.logger.error("\(message, privacy: .public)") }
    )

    func beginMonitoring() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.pollOtherAppUse()
                self.lifecycle.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func select(device: AVCaptureDevice?) {
        queue.async { [self] in
            guard self.device?.uniqueID != device?.uniqueID || self.device?.isConnected != true else { return }
            selectionGeneration += 1
            let generation = selectionGeneration
            deviceObservation = nil
            formatObservation = nil
            self.device = device
            usageMonitor = device.map { CameraUsageMonitor(uid: $0.uniqueID) }
            lastOtherAppUse = CameraUsageMonitor.anotherAppIsUsingCamera(
                reportedByAVFoundation: device?.isInUseByAnotherApplication ?? false,
                ourCaptureIsActive: false, runningSomewhere: usageMonitor?.isRunningSomewhere())
            if let device {
                deviceObservation = device.observe(\.isInUseByAnotherApplication, options: [.new]) { [weak self] device, _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.selectionGeneration == generation else { return }
                        self.pollOtherAppUse()
                    }
                }
                formatObservation = device.observe(\.activeFormat, options: [.old, .new]) { [weak self] _, change in
                    guard let old = change.oldValue, let new = change.newValue, old !== new else { return }
                    self?.queue.async { [weak self] in
                        guard let self, self.selectionGeneration == generation,
                              self.lifecycle.state == .running,
                              ProcessInfo.processInfo.systemUptime - self.sessionStartedAt > 2 else { return }
                        self.lifecycle.failed("Camera format changed while previewing.")
                        self.pollOtherAppUse()
                    }
                }
            }
            lifecycle.select(deviceID: device?.uniqueID, inUseByAnotherApp: lastOtherAppUse)
        }
    }

    func setVisible(_ visible: Bool) { queue.async { [self] in lifecycle.setVisible(visible) } }
    func setSuspended(_ suspended: Bool) { queue.async { [self] in lifecycle.setSuspended(suspended) } }
    func retry() { queue.async { [self] in lifecycle.retry() } }

    func shutdown() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            deviceObservation = nil
            formatObservation = nil
            lifecycle.shutdown()
            stopSession()
            device = nil
        }
    }

    private func otherAppUseChanged(_ inUse: Bool) {
        guard inUse != lastOtherAppUse else { return }
        lastOtherAppUse = inUse
        logger.info("Another app using selected camera: \(inUse, privacy: .public)")
        lifecycle.setOtherAppUsingCamera(inUse)
        if inUse { onCameraActivity?() }
    }

    private func pollOtherAppUse() {
        guard let device else { return }
        let inUse = CameraUsageMonitor.anotherAppIsUsingCamera(
            reportedByAVFoundation: device.isInUseByAnotherApplication,
            ourCaptureIsActive: lifecycle.isCapturing,
            runningSomewhere: lifecycle.isCapturing ? nil : usageMonitor?.isRunningSomewhere())
        otherAppUseChanged(inUse)
    }

    private func startSession(deviceID: String) throws {
        guard let device, device.uniqueID == deviceID, device.isConnected,
              !device.isSuspended, !device.isInUseByAnotherApplication else {
            throw NSError(domain: "SkinToneStudio.Camera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The camera is unavailable or in use."])
        }
        stopSession()
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let newSession = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let token = frames.begin()
        let processor = PreviewFrameProcessor(token: token, relay: frames) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.frames.isCurrent(token) else { return }
                self.lifecycle.receivedFrame()
            }
        }
        output.setSampleBufferDelegate(processor, queue: frameQueue)

        newSession.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input), newSession.canAddOutput(output) else {
                throw NSError(domain: "SkinToneStudio.Camera", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The camera cannot provide a preview right now."])
            }
            newSession.addInput(input)
            newSession.addOutput(output)
            // macOS has no inputPriority preset. Match the currently active resolution where
            // possible; do not ask .high to choose a different device format on every reopen.
            let presets: [(Int32, Int32, AVCaptureSession.Preset)] = [
                (640, 480, .vga640x480), (960, 540, .qHD960x540),
                (1280, 720, .hd1280x720), (1920, 1080, .hd1920x1080),
                (3840, 2160, .hd4K3840x2160)
            ]
            if let preset = presets.first(where: { $0.0 == dimensions.width && $0.1 == dimensions.height })?.2,
               newSession.canSetSessionPreset(preset) {
                newSession.sessionPreset = preset
            }
        } catch {
            newSession.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            _ = frames.begin()
            throw error
        }
        newSession.commitConfiguration()
        self.session = newSession
        self.processor = processor

        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification, AVCaptureSession.didStopRunningNotification] {
            sessionTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: newSession, queue: nil
            ) { [weak self, weak newSession] note in
                let reason = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? note.name.rawValue
                self?.queue.async { [weak self, weak newSession] in
                    guard let self, let newSession, self.session === newSession else { return }
                    self.lifecycle.failed(reason)
                }
            })
        }
        newSession.startRunning()
        sessionStartedAt = ProcessInfo.processInfo.systemUptime
        guard newSession.isRunning else {
            stopSession()
            throw NSError(domain: "SkinToneStudio.Camera", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The camera preview did not start."])
        }
        // Success is published only after a valid, renderable video frame reaches the delegate.
    }

    private func stopSession() {
        _ = frames.begin()
        for token in sessionTokens { NotificationCenter.default.removeObserver(token) }
        sessionTokens.removeAll()
        let oldSession = session
        session = nil
        oldSession?.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }
            .forEach { $0.setSampleBufferDelegate(nil, queue: nil) }
        oldSession?.stopRunning()
        oldSession?.beginConfiguration()
        if let oldSession {
            for input in oldSession.inputs { oldSession.removeInput(input) }
            for output in oldSession.outputs { oldSession.removeOutput(output) }
            oldSession.commitConfiguration()
        }
        processor = nil
    }
}
