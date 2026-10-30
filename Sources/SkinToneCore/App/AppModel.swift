@preconcurrency import AVFoundation
import AppKit
import Foundation
import OSLog

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
            activityApplyWork?.cancel()
            pendingProfile = nil
            persistCurrentSession()
            scheduleRealtimeColorApply()
        }
    }
    @Published public var hardwareSettings = HardwareSettings() {
        didSet {
            guard !isRestoringProfile else { return }
            activityApplyWork?.cancel()
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
    private var activityApplyWork: DispatchWorkItem?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var activeDeviceID: String?
    private var connectionGeneration = 0
    private var connectingHardware = false
    private var hasStarted = false
    private var isSleeping = false
    private var hardwareReconnectNotBefore = 0.0
    private let logger = Logger(subsystem: "studio.skintone.camera", category: "Hardware")
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
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let disconnectedID = name == AVCaptureDevice.wasDisconnectedNotification
                    ? (note.object as? AVCaptureDevice)?.uniqueID : nil
                Task { @MainActor in
                    guard let self else { return }
                    if disconnectedID == self.selectedCameraID {
                        self.disconnectSelectedCamera()
                    }
                    self.refreshCameras()
                }
            })
        }
        captureEngine.onCameraActivity = { [weak self] in self?.reapplyAfterCameraActivity() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isSleeping = true
                self?.activityApplyWork?.cancel()
                self?.stopManualFocusWatchdog()
            }
        })
        workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSleeping = false
                self.refreshCameras()
                self.reapplyAfterCameraActivity()
                if let controller = self.uvcController { self.startManualFocusWatchdog(for: controller) }
            }
        })
    }

    deinit {
        focusWatchdogTimer?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
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
        let devices = CameraCaptureEngine.availableDevices().filter(\.isConnected)
        let previousChoice = cameras.first { $0.id == selectedCameraID }
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uniqueID, $0) })
        cameras = devices.map {
            CameraChoice(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
        if !selectedCameraID.isEmpty, devicesByID[selectedCameraID] == nil {
            // Keep the user's selected webcam when it briefly disconnects. Do not silently
            // open an iPhone or another camera during a USB reset.
            cameras.append(CameraChoice(id: selectedCameraID,
                                        name: previousChoice?.name ?? "Selected camera (disconnected)",
                                        isExternal: true))
            disconnectSelectedCamera()
            return
        }
        if selectedCameraID.isEmpty {
            if let rememberedID = sessionStore.selectedCameraID, devicesByID[rememberedID] != nil {
                selectedCameraID = rememberedID
            } else {
                selectedCameraID = cameras.first?.id ?? ""
            }
        }
        if CameraSelectionPolicy.needsConnection(selectedID: selectedCameraID,
                                                  connectedIDs: devices.map(\.uniqueID),
                                                  activeID: activeDeviceID) {
            selectCamera(id: selectedCameraID)
        }
    }

    private func disconnectSelectedCamera() {
        stopManualFocusWatchdog()
        activityApplyWork?.cancel()
        colorApplyWork?.cancel()
        focusApplyWork?.cancel()
        connectionGeneration += 1
        connectingHardware = false
        activeDeviceID = nil
        uvcController = nil
        capabilities = CameraCapabilities()
        controlStatus = .previewOnly("The selected camera is disconnected.")
        captureEngine.select(device: nil)
    }

    public func selectCamera(id: String) {
        guard let device = devicesByID[id] else { return }
        guard activeDeviceID != id else { return }
        activeDeviceID = id
        connectionGeneration += 1
        let generation = connectionGeneration
        selectedCameraID = id
        sessionStore.rememberSelectedCamera(id: id)
        capabilities = CameraCapabilities()
        controlStatus = .checking
        uvcController = nil
        colorApplyWork?.cancel()
        focusApplyWork?.cancel()
        activityApplyWork?.cancel()
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

        captureEngine.select(device: device)
        connectController(to: device, expectedID: id, generation: generation)
    }

    /// Hardware controls do not need an open preview stream. Stream starts (including those in
    /// another app) separately reassert the current look after camera firmware has settled.
    private func connectController(to device: AVCaptureDevice, expectedID: String, generation: Int, attempt: Int = 0) {
        connectingHardware = true
        hardwareQueue.async { [weak self] in
            let result = Result { try UVCController(device: device) }
            Task { @MainActor in
                guard let self, self.selectedCameraID == expectedID,
                      self.connectionGeneration == generation else { return }
                self.connectingHardware = false
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
                    self.logger.error("Opening camera controls: \(error.localizedDescription, privacy: .public)")
                    if let error = error as? UVCCameraError, case .notUSBVideoClass = error { return }
                    if attempt < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt))) { [weak self] in
                            guard let self, !self.isSleeping, self.uvcController == nil,
                                  !self.connectingHardware, self.connectionGeneration == generation,
                                  device.isConnected else { return }
                            self.connectController(to: device, expectedID: expectedID,
                                                   generation: generation, attempt: attempt + 1)
                        }
                    }
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
        activityApplyWork?.cancel()
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
        activityApplyWork?.cancel()
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

    private func reapplyAfterCameraActivity() {
        activityApplyWork?.cancel()
        guard !isSleeping else { return }
        guard let controller = uvcController else {
            if !connectingHardware, activeDeviceID == selectedCameraID,
               let device = devicesByID[selectedCameraID], device.isConnected,
               device.modelID.hasPrefix("UVC Camera") {
                connectController(to: device, expectedID: selectedCameraID, generation: connectionGeneration)
            }
            return
        }
        let color = colorSettings
        let hardware = hardwareSettings
        let box = DispatchWorkBox()
        let work = DispatchWorkItem { [weak self] in
            guard box.value?.isCancelled == false else { return }
            do {
                // Do not reset the color baseline or briefly enable autofocus during a handoff.
                try controller.applyHardwareLook(color)
                if hardware.autoFocus {
                    if controller.capabilities.autoFocus { try controller.setAutoFocus(true) }
                } else {
                    try controller.reassertManualFocus(normalizedFocus: hardware.focus)
                }
                if hardware.precisionAntiFlicker {
                    try controller.applyPrecisionAntiFlicker(frequency: hardware.flickerFrequency)
                } else if controller.capabilities.powerLineFrequency {
                    try controller.setPowerLineMode(hardware.powerLineMode)
                }
            } catch {
                self?.logger.error("Reapplying camera settings: \(error.localizedDescription, privacy: .public)")
            }
        }
        box.value = work
        activityApplyWork = work
        hardwareQueue.asyncAfter(deadline: .now() + 0.8, execute: work)
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
              !isSleeping,
              !hardwareSettings.autoFocus else { return }

        let focus = hardwareSettings.focus
        var consecutiveErrors = 0
        let timer = DispatchSource.makeTimerSource(queue: hardwareQueue)
        timer.schedule(deadline: .now() + .milliseconds(750),
                        repeating: .milliseconds(750),
                        leeway: .milliseconds(120))
        timer.setEventHandler { [weak self, controller] in
            do {
                try controller.maintainManualFocus(normalizedFocus: focus)
                consecutiveErrors = 0
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors == 1 {
                    self?.logger.error("Focus check failed: \(error.localizedDescription, privacy: .public)")
                }
                if consecutiveErrors == 3 || consecutiveErrors.isMultiple(of: 40) {
                    Task { @MainActor [weak self] in self?.reconnectHardware(afterFailureOf: controller) }
                }
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

    private func reconnectHardware(afterFailureOf controller: UVCController) {
        guard !isSleeping, uvcController === controller,
              ProcessInfo.processInfo.systemUptime >= hardwareReconnectNotBefore,
              let device = devicesByID[selectedCameraID], device.isConnected else { return }
        hardwareReconnectNotBefore = ProcessInfo.processInfo.systemUptime + 30
        stopManualFocusWatchdog()
        activityApplyWork?.cancel()
        pendingProfile = StudioProfile(name: "Current settings", color: colorSettings, hardware: hardwareSettings)
        uvcController = nil
        connectionGeneration += 1
        connectController(to: device, expectedID: selectedCameraID, generation: connectionGeneration)
    }
}
