@preconcurrency import AVFoundation
import AppKit
import CoreImage
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
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    fileprivate func display(_ image: CGImage) {
        layer?.contents = image
    }
}

public struct CameraPreview: NSViewRepresentable {
    private let engine: CameraCaptureEngine

    public init(engine: CameraCaptureEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        engine.previewSurface = view
        return view
    }

    public func updateNSView(_ nsView: PreviewSurface, context: Context) {
        engine.previewSurface = nsView
    }
}

public final class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var previewSurface: PreviewSurface?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "studio.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "studio.camera.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let context: CIContext
    private var currentInput: AVCaptureDeviceInput?
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()

    public override init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    public static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        return discovery.devices.sorted {
            let leftExternal = $0.deviceType == .external
            let rightExternal = $1.deviceType == .external
            if leftExternal != rightExternal { return leftExternal }
            return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    public func start(device: AVCaptureDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                if let currentInput = self.currentInput {
                    self.session.removeInput(currentInput)
                }
                if self.session.outputs.isEmpty, self.session.canAddOutput(self.output) {
                    self.session.addOutput(self.output)
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw NSError(domain: "SkinToneStudio.Camera", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "This camera is already in use or unavailable."])
                }
                self.session.addInput(input)
                self.currentInput = input
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Limit display conversion to ~30 fps even if a camera is delivering 60 fps.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime >= 1.0 / 31.0 else { return }
        lastFrameTime = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            let input = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = context.createCGImage(input, from: input.extent) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.previewSurface?.display(cgImage)
            }
        }
    }
}
