@preconcurrency import AVFoundation
import Foundation

private final class DispatchWorkBox {
    weak var value: DispatchWorkItem?
}

public enum CameraControlStatus: Equatable {
    case checking
    case ready
    case previewOnly(String)

    public var title: String {
        switch self {
        case .checking: "Checking controls"
        case .ready: "Hardware controls ready"
        case .previewOnly: "Hardware controls unavailable"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var cameras: [CameraChoice] = []
    @Published public var selectedCameraID = ""
    @Published public var colorSettings = ColorSettings() {
        didSet {
            guard !isRestoringProfile else { return }
            pendingProfile = nil
            scheduleRealtimeColorApply()
        }
    }
    @Published public var hardwareSettings = HardwareSettings()
    @Published public private(set) var capabilities = CameraCapabilities()
    @Published public private(set) var controlStatus: CameraControlStatus = .checking
    @Published public private(set) var permissionDenied = false
    @Published public var message: String?

    public let captureEngine = CameraCaptureEngine()
    public let profiles = ProfileStore()

    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var uvcController: UVCController?
    private let hardwareQueue = DispatchQueue(label: "studio.camera.hardware", qos: .userInitiated)
    private var notificationTokens: [NSObjectProtocol] = []
    private var colorApplyWork: DispatchWorkItem?
    private var focusApplyWork: DispatchWorkItem?
    private var isRestoringProfile = false
    private var pendingProfile: StudioProfile?

    public init() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refreshCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionDenied = !granted
                    if granted { self.refreshCameras() }
                }
            }
        default:
            permissionDenied = true
        }
    }

    public func refreshCameras() {
        let devices = CameraCaptureEngine.availableDevices()
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uniqueID, $0) })
        cameras = devices.map {
            CameraChoice(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
        if selectedCameraID.isEmpty || devicesByID[selectedCameraID] == nil {
            selectedCameraID = cameras.first?.id ?? ""
        }
        if !selectedCameraID.isEmpty { selectCamera(id: selectedCameraID) }
    }

    public func selectCamera(id: String) {
        guard let device = devicesByID[id] else { return }
        selectedCameraID = id
        capabilities = CameraCapabilities()
        controlStatus = .checking
        uvcController = nil

        captureEngine.start(device: device) { [weak self] result in
            if case .failure(let error) = result { self?.message = error.localizedDescription }
        }

        let expectedID = id
        hardwareQueue.async { [weak self] in
            let result = Result {
                let controller = try UVCController(device: device)
                try controller.resetColorToDefaults()
                return controller
            }
            Task { @MainActor in
                guard let self, self.selectedCameraID == expectedID else { return }
                switch result {
                case .success(let controller):
                    self.uvcController = controller
                    self.capabilities = controller.capabilities
                    self.controlStatus = .ready
                    if let profile = self.pendingProfile {
                        self.restore(profile, using: controller)
                    } else {
                        if let focus = controller.capabilities.focus {
                            self.hardwareSettings.focus = focus.normalizedValue(for: focus.current)
                        }
                        if let autoFocus = controller.capabilities.autoFocusEnabled {
                            self.hardwareSettings.autoFocus = autoFocus
                        }
                        if let powerLineMode = controller.capabilities.powerLineMode {
                            self.hardwareSettings.powerLineMode = powerLineMode
                        }
                        self.scheduleRealtimeColorApply()
                    }
                case .failure(let error):
                    self.controlStatus = .previewOnly(error.localizedDescription)
                }
            }
        }
    }

    public func chooseStartingPoint(_ point: SkinToneStartingPoint) {
        colorSettings.apply(point)
    }

    public func applyAutoFocus() {
        let enabled = hardwareSettings.autoFocus
        let focus = hardwareSettings.focus
        performHardwareAction { controller in
            try controller.setAutoFocus(enabled)
            if !enabled {
                try controller.setFocus(normalized: focus)
            }
        }
    }

    public func applyFocus() {
        guard let controller = uvcController else { return }
        let focus = hardwareSettings.focus
        focusApplyWork?.cancel()
        let box = DispatchWorkBox()
        let work = DispatchWorkItem { [weak self] in
            guard box.value?.isCancelled == false else { return }
            do { try controller.setFocus(normalized: focus) }
            catch { Task { @MainActor in self?.message = error.localizedDescription } }
        }
        box.value = work
        focusApplyWork = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    public func applyPowerLineMode() {
        let mode = hardwareSettings.powerLineMode
        performHardwareAction { try $0.setPowerLineMode(mode) }
    }

    public func applyAntiFlicker() {
        let frequency = hardwareSettings.flickerFrequency
        performHardwareAction {
            try $0.applyPrecisionAntiFlicker(frequency: frequency)
        }
    }

    public func resetCamera() {
        guard let controller = uvcController else {
            message = "This camera does not expose compatible UVC hardware controls."
            return
        }
        colorApplyWork?.cancel()
        focusApplyWork?.cancel()
        pendingProfile = nil
        hardwareQueue.async { [weak self] in
            do {
                try controller.resetToDefaults()
                let hardware = controller.currentHardwareSettings()
                Task { @MainActor in
                    guard let self else { return }
                    self.colorSettings = .cameraNeutral
                    self.hardwareSettings = hardware
                    self.message = "Camera settings restored to their factory defaults."
                }
            } catch {
                Task { @MainActor in self?.message = error.localizedDescription }
            }
        }
    }

    public func load(_ profile: StudioProfile) {
        colorApplyWork?.cancel()
        focusApplyWork?.cancel()
        pendingProfile = profile
        isRestoringProfile = true
        colorSettings = profile.color
        hardwareSettings = profile.hardware
        isRestoringProfile = false
        guard let controller = uvcController else { return }
        restore(profile, using: controller)
    }

    private func restore(_ profile: StudioProfile, using controller: UVCController) {
        let color = profile.color
        let hardware = profile.hardware
        hardwareQueue.async { [weak self] in
            do {
                try controller.resetColorToDefaults()
                try controller.applyHardwareLook(color)
                try controller.setAutoFocus(hardware.autoFocus)
                if !hardware.autoFocus { try controller.setFocus(normalized: hardware.focus) }
                if hardware.precisionAntiFlicker {
                    try controller.applyPrecisionAntiFlicker(frequency: hardware.flickerFrequency)
                } else {
                    try controller.setPowerLineMode(hardware.powerLineMode)
                }
            } catch {
                Task { @MainActor in self?.message = error.localizedDescription }
            }
        }
    }

    private func scheduleRealtimeColorApply() {
        guard let controller = uvcController else { return }
        let settings = colorSettings
        colorApplyWork?.cancel()
        let box = DispatchWorkBox()
        let work = DispatchWorkItem { [weak self] in
            guard box.value?.isCancelled == false else { return }
            do { try controller.applyHardwareLook(settings) }
            catch { Task { @MainActor in self?.message = error.localizedDescription } }
        }
        box.value = work
        colorApplyWork = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    private func performHardwareAction(success: String? = nil,
                                       _ action: @escaping (UVCController) throws -> Void) {
        guard let controller = uvcController else {
            message = "This camera does not expose compatible UVC hardware controls."
            return
        }
        hardwareQueue.async { [weak self] in
            do {
                try action(controller)
                if let success { Task { @MainActor in self?.message = success } }
            } catch {
                Task { @MainActor in self?.message = error.localizedDescription }
            }
        }
    }
}
