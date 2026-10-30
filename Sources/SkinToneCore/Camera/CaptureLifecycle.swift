import Foundation

public enum CameraPreviewState: Equatable, Sendable {
    case idle
    case paused
    case inUseByAnotherApp
    case starting
    case running
    case recovering

    public var title: String {
        switch self {
        case .idle: "No camera connected"
        case .paused: "Preview paused"
        case .inUseByAnotherApp: "Camera in use by another app"
        case .starting: "Starting preview…"
        case .running: "Live camera output"
        case .recovering: "Reconnecting camera…"
        }
    }
}

/// All calls run on the capture queue. The clock and driver are injected so handoffs, lost
/// frames, and delayed retries can be exercised without opening a physical camera.
final class CaptureLifecycle {
    private(set) var state: CameraPreviewState = .idle {
        didSet { if state != oldValue { stateChanged(state) } }
    }
    private(set) var deviceID: String?
    private(set) var isCapturing = false
    private var visible = false
    private var suspended = false
    private var otherAppUsingCamera = false
    private var lastFrame = 0.0
    private var nextStart = 0.0
    private var failures = 0
    private var healthySince: TimeInterval?

    private let now: () -> TimeInterval
    private let start: (String) throws -> Void
    private let stop: () -> Void
    private let stateChanged: (CameraPreviewState) -> Void
    private let streamStarted: () -> Void
    private let log: (String) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         start: @escaping (String) throws -> Void,
         stop: @escaping () -> Void,
         stateChanged: @escaping (CameraPreviewState) -> Void,
         streamStarted: @escaping () -> Void,
         log: @escaping (String) -> Void = { _ in }) {
        self.now = now
        self.start = start
        self.stop = stop
        self.stateChanged = stateChanged
        self.streamStarted = streamStarted
        self.log = log
    }

    func select(deviceID: String?, inUseByAnotherApp: Bool) {
        guard self.deviceID != deviceID else {
            setOtherAppUsingCamera(inUseByAnotherApp)
            return
        }
        releaseCapture()
        self.deviceID = deviceID
        otherAppUsingCamera = inUseByAnotherApp
        failures = 0
        nextStart = now() + 0.4
        reconcile()
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { nextStart = max(nextStart, now() + 0.35) }
        reconcile()
    }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if !suspended { nextStart = max(nextStart, now() + 1) }
        reconcile()
    }

    func setOtherAppUsingCamera(_ inUse: Bool) {
        guard otherAppUsingCamera != inUse else { return }
        otherAppUsingCamera = inUse
        // Do not grab the device between one browser releasing it and the next acquiring it.
        if !inUse { nextStart = max(nextStart, now() + 2) }
        reconcile()
    }

    func receivedFrame() {
        guard isCapturing else { return }
        lastFrame = now()
        if state != .running {
            healthySince = now()
            state = .running
            streamStarted()
        }
    }

    func failed(_ reason: String) {
        guard isCapturing else { return }
        releaseCapture()
        failures += 1
        nextStart = now() + min(30, pow(2, Double(min(failures, 5))))
        log("Preview recovery (attempt \(failures)): \(reason)")
        reconcile()
    }

    func retry() {
        releaseCapture()
        failures = 0
        nextStart = now() + 0.35
        reconcile()
    }

    func tick() {
        if isCapturing {
            let timeout = state == .starting ? 8.0 : 4.0
            if now() - lastFrame > timeout {
                failed("No usable video frames arrived.")
            } else if let healthySince, now() - healthySince > 15 {
                failures = 0
            }
        }
        reconcile()
    }

    func shutdown() {
        visible = false
        releaseCapture()
    }

    private func releaseCapture() {
        let wasCapturing = isCapturing
        isCapturing = false
        healthySince = nil
        if wasCapturing { stop() }
    }

    private func reconcile() {
        guard let deviceID else {
            releaseCapture()
            state = .idle
            return
        }
        guard visible, !suspended else {
            releaseCapture()
            state = .paused
            return
        }
        guard !otherAppUsingCamera else {
            releaseCapture()
            state = .inUseByAnotherApp
            return
        }
        guard !isCapturing else { return }
        state = failures == 0 ? .starting : .recovering
        guard now() >= nextStart else { return }
        isCapturing = true
        lastFrame = now()
        state = .starting
        do { try start(deviceID) }
        catch { failed(error.localizedDescription) }
    }
}

enum CameraSelectionPolicy {
    /// Unrelated devices and list reordering must not rebuild an already selected camera.
    static func needsConnection(selectedID: String, connectedIDs: [String], activeID: String?) -> Bool {
        connectedIDs.contains(selectedID) && activeID != selectedID
    }
}
