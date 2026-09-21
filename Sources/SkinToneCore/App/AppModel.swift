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
            persistCurrentSession()
            scheduleRealtimeColorApply()
        }
    }
    @Published public var hardwareSettings = HardwareSettings() {
        didSet {
            guard !isRestoringProfile else { return }
            pendingProfile = nil
            persistCurrentSession()
        }
    }
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
    private var focusWatchdogTimer: DispatchSourceTimer?
    private var isRestoringProfile = false
    private var pendingProfile: StudioProfile?
    private let sessionStore: CameraSessionStore

    public convenience init() {
        self.init(sessionStore: CameraSessionStore())
    }

    public init(sessionStore: CameraSessionStore) {
        self.sessionStore = sessionStore
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    deinit {
        focusWatchdogTimer?.cancel()
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
        if !selectedCameraID.isEmpty, devicesByID[selectedCameraID] == nil {
            stopManualFocusWatchdog()
            uvcController = nil
        }
        if selectedCameraID.isEmpty || devicesByID[selectedCameraID] == nil {
            if let rememberedID = sessionStore.selectedCameraID, devicesByID[rememberedID] != nil {
                selectedCameraID = rememberedID
            } else {
                selectedCameraID = cameras.first?.id ?? ""
            }
        }
        if !selectedCameraID.isEmpty { selectCamera(id: selectedCameraID) }
    }

    public func selectCamera(id: String) {
        guard let device = devicesByID[id] else { return }
        selectedCameraID = id
        sessionStore.rememberSelectedCamera(id: id)
        capabilities = CameraCapabilities()
        controlStatus = .checking
        uvcController = nil
        colorApplyWork?.cancel()
        focusApplyWork?.cancel()
        stopManualFocusWatchdog()

        isRestoringProfile = true
        if let saved = sessionStore.settings(for: id) {
            colorSettings = saved.color
            hardwareSettings = saved.hardware
            pendingProfile = StudioProfile(name: "Last session", color: saved.color, hardware: saved.hardware)
        } else {
            colorSettings = .cameraNeutral
            hardwareSettings = HardwareSettings()
            pendingProfile = nil
        }
        isRestoringProfile = false

        let expectedID = id
        captureEngine.start(device: device) { [weak self] captureResult in
            Task { @MainActor in
                guard let self, self.selectedCameraID == expectedID else { return }
                switch captureResult {
                case .success:
                    self.connectController(to: device, expectedID: expectedID)
                case .failure(let error):
                    self.controlStatus = .previewOnly(error.localizedDescription)
                    self.message = error.localizedDescription
                }
            }
        }
    }

    /// Opens the UVC control channel only after AVFoundation has started streaming. Some cameras
    /// reset their lens controls as the stream comes online and would otherwise discard launch writes.
    private func connectController(to device: AVCaptureDevice, expectedID: String) {
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
                        self.startManualFocusWatchdog(for: controller)
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
        stopManualFocusWatchdog()
        performHardwareAction { [weak self] controller in
            try controller.applyFocusMode(autoFocus: enabled, normalizedFocus: focus)
            if !enabled {
                try controller.stabilizeManualFocus(normalizedFocus: focus)
                Task { @MainActor [weak self] in
                    guard let self, self.uvcController === controller else { return }
                    self.startManualFocusWatchdog(for: controller)
                }
            }
        }
    }

    public func applyFocus() {
        guard let controller = uvcController else { return }
        guard !hardwareSettings.autoFocus else {
            stopManualFocusWatchdog()
            return
        }
        let focus = hardwareSettings.focus
        startManualFocusWatchdog(for: controller)
        focusApplyWork?.cancel()
        let box = DispatchWorkBox()
        let work = DispatchWorkItem { [weak self] in
            guard box.value?.isCancelled == false else { return }
            do { try controller.reassertManualFocus(normalizedFocus: focus) }
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
        stopManualFocusWatchdog()
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
                    self.startManualFocusWatchdog(for: controller)
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
        stopManualFocusWatchdog()
        pendingProfile = profile
        isRestoringProfile = true
        colorSettings = profile.color
        hardwareSettings = profile.hardware
        isRestoringProfile = false
        persistCurrentSession()
        guard let controller = uvcController else { return }
        restore(profile, using: controller)
    }

    private func restore(_ profile: StudioProfile, using controller: UVCController) {
        pendingProfile = nil
        let color = profile.color
        let hardware = profile.hardware
        let expectedCameraID = selectedCameraID
        hardwareQueue.async { [weak self] in
            do {
                try controller.resetColorToDefaults()
                try controller.applyHardwareLook(color)
                try controller.applyFocusMode(autoFocus: hardware.autoFocus,
                                              normalizedFocus: hardware.focus)
                if hardware.precisionAntiFlicker {
                    try controller.applyPrecisionAntiFlicker(frequency: hardware.flickerFrequency)
                } else {
                    try controller.setPowerLineMode(hardware.powerLineMode)
                }
                if !hardware.autoFocus {
                    try controller.stabilizeManualFocus(normalizedFocus: hardware.focus)
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.selectedCameraID == expectedCameraID,
                              self.uvcController === controller else { return }
                        self.startManualFocusWatchdog(for: controller)
                    }
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

    private func persistCurrentSession() {
        sessionStore.save(color: colorSettings, hardware: hardwareSettings, for: selectedCameraID)
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

    /// Keeps manual focus locked after webcam firmware re-enables autofocus or changes the
    /// focus register in response to a USB/streaming event. The watchdog only reads the two
    /// focus controls on each tick and writes them back when a drift is detected.
    private func startManualFocusWatchdog(for controller: UVCController) {
        stopManualFocusWatchdog()
        guard uvcController === controller,
              capabilities.focus != nil,
              !hardwareSettings.autoFocus else { return }

        let focus = hardwareSettings.focus
        let timer = DispatchSource.makeTimerSource(queue: hardwareQueue)
        timer.schedule(deadline: .now() + .milliseconds(750),
                        repeating: .milliseconds(750),
                        leeway: .milliseconds(120))
        timer.setEventHandler { [controller] in
            do {
                try controller.maintainManualFocus(normalizedFocus: focus)
            } catch {
                // A transient USB error should not interrupt the live preview. The next tick
                // retries, while explicit user actions still surface their own errors in the UI.
            }
        }
        focusWatchdogTimer = timer
        timer.resume()
    }

    private func stopManualFocusWatchdog() {
        focusWatchdogTimer?.setEventHandler {}
        focusWatchdogTimer?.cancel()
        focusWatchdogTimer = nil
    }
}
