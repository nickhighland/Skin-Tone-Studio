import Foundation
import SkinToneCore
import AVFoundation
import Combine
import AppKit

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

var color = ColorSettings()
color.exposure = 0.35
color.apply(.deep)
check(color.startingPoint == .deep, "Skin-tone preset selection")
check(color.exposure == 0.35, "Preset must not alter exposure or lighten skin")
check(color.skinWarmth == SkinToneStartingPoint.deep.defaults.warmth, "Preset warmth")
check(color.rosiness == SkinToneStartingPoint.deep.defaults.rosiness, "Preset rosiness")

color.tint = 1
color.rosiness = 0
check(color.normalizedCameraHueOffset < 0, "Magenta/right tint maps to the camera's magenta direction")
color.tint = 0
color.rosiness = 0.25
check(color.normalizedCameraHueOffset < 0, "Positive rosiness maps to the camera's rosy direction")

color.correctionStrength = 1
color.skinWarmth = 0.5
color.temperature = 0
check(color.normalizedCameraWhiteBalanceOffset >= 0.3,
      "Skin warmth uses a clearly visible portion of the white-balance range")
color.skinWarmth = 0
color.rosiness = 1
check(abs(color.normalizedCameraHueOffset) >= 0.85,
      "Rosiness uses a clearly visible portion of the hue range")
color.correctionStrength = 0.1
check(abs(color.normalizedCameraHueOffset) >= 0.08,
      "Rosiness remains perceptible at a low correction strength")
color.correctionStrength = 0
check(color.normalizedCameraWhiteBalanceOffset == 0,
      "Zero correction strength removes the skin-warmth contribution")
check(color.normalizedCameraHueOffset == 0,
      "Zero correction strength removes the rosiness contribution")

var hardware = HardwareSettings()
hardware.flickerFrequency = 50
check(hardware.antiFlickerExposureUnits == 100, "50 Hz anti-flicker exposure")
hardware.flickerFrequency = 60
check(hardware.antiFlickerExposureUnits == 83, "60 Hz anti-flicker exposure")

let range = ControlRange(minimum: 100, maximum: 300, step: 20,
                         current: 200, defaultValue: 180)
check(range.normalizedValue(for: 200) == 0.5, "UVC normalization")
check(range.rawValue(for: 0.53) == 200, "UVC step quantization")
check(range.rawValue(for: 1.4) == 300, "UVC upper clamping")
check(range.rawValue(for: -1) == 100, "UVC lower clamping")

do {
    let profile = StudioProfile(name: "Office", color: color, hardware: hardware)
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(StudioProfile.self, from: data)
    check(decoded == profile, "Profile JSON round trip")
} catch {
    failures.append("Profile JSON round trip threw: \(error.localizedDescription)")
}

MainActor.assumeIsolated {
    let defaultsName = "SkinToneStudioChecks.\(UUID().uuidString)"
    let sessionDefaults = UserDefaults(suiteName: defaultsName)!
    let sessionKey = "CameraSessions"
    let sessionStore = CameraSessionStore(defaults: sessionDefaults, storageKey: sessionKey)
    var rememberedColor = ColorSettings()
    rememberedColor.contrast = 1.31
    rememberedColor.temperature = -0.24
    var rememberedHardware = HardwareSettings()
    rememberedHardware.focus = 0.73
    sessionStore.rememberSelectedCamera(id: "camera-a")
    sessionStore.save(color: rememberedColor, hardware: rememberedHardware, for: "camera-a")

    let reloadedSessionStore = CameraSessionStore(defaults: sessionDefaults, storageKey: sessionKey)
    check(reloadedSessionStore.selectedCameraID == "camera-a", "Last selected camera survives relaunch")
    check(reloadedSessionStore.settings(for: "camera-a")?.color == rememberedColor,
          "Last color settings survive relaunch")
    check(reloadedSessionStore.settings(for: "camera-a")?.hardware == rememberedHardware,
          "Last hardware settings survive relaunch")
    sessionDefaults.removePersistentDomain(forName: defaultsName)

    let profileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("skin-tone-studio-profile-check-\(UUID().uuidString).json")
    let store = ProfileStore(fileURL: profileURL)
    var profilePublications = 0
    let publication = store.objectWillChange.sink { profilePublications += 1 }
    store.save(name: "Visible immediately", color: ColorSettings(), hardware: HardwareSettings())
    check(store.profiles.count == 1, "Saved profile is published immediately")
    if let profile = store.profiles.first { store.delete(profile) }
    check(store.profiles.isEmpty, "Deleted profile is published immediately")
    check(profilePublications >= 2, "Profile list publishes save and delete changes")
    withExtendedLifetime(publication) {}

    var savedColor = ColorSettings()
    savedColor.contrast = 1.35
    savedColor.saturation = 1.25
    var savedHardware = HardwareSettings()
    savedHardware.focus = 0.82
    let savedProfile = StudioProfile(name: "Slider restore", color: savedColor, hardware: savedHardware)
    let model = AppModel()
    model.load(savedProfile)
    check(model.colorSettings == savedColor, "Loading a profile restores every color slider value")
    check(model.hardwareSettings == savedHardware, "Loading a profile restores every hardware slider value")
}

if failures.isEmpty {
    print("All Skin Tone Studio checks passed.")
} else {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(1)
}

if CommandLine.arguments.contains("--hardware") {
    let usbCameras = CameraCaptureEngine.availableDevices().filter { $0.modelID.hasPrefix("UVC Camera") }
    if usbCameras.isEmpty {
        print("No UVC camera connected; hardware diagnostic skipped.")
    }
    for camera in usbCameras {
        do {
            let controller = try UVCController(device: camera)
            let c = controller.capabilities
            let current = controller.currentHardwareSettings()
            print("UVC hardware: \(camera.localizedName)")
            print("  manual focus: \(c.focus != nil), autofocus: \(c.autoFocus)")
            print("  current focus mode: \(current.autoFocus ? "automatic" : "manual"), position: \(String(format: "%.3f", current.focus))")
            print("  exposure: \(c.exposure != nil), gain: \(c.gain != nil)")
            print("  white balance: \(c.whiteBalance != nil), hue: \(c.hue != nil), saturation: \(c.saturation != nil)")
            print("  powerline frequency: \(c.powerLineFrequency), auto mode: \(c.powerLineAutoSupported)")
            if CommandLine.arguments.contains("--hardware-write") {
                let writes = try controller.verifyRealtimeWritePath()
                print("  state-neutral live writes verified: \(writes)")
                let focusLocked = try controller.verifyManualFocusPath()
                print("  manual-focus launch stabilization verified: \(focusLocked)")
                let focusWatchdog = try controller.verifyManualFocusMaintenancePath()
                print("  manual-focus watchdog recovery verified: \(focusWatchdog)")
                let skinToneControls = try controller.verifySkinToneCorrectionPath()
                print("  visibly distinct skin-tone controls verified: \(skinToneControls)")
                check(!c.autoFocus || c.focus == nil || focusLocked,
                      "Manual focus mode did not remain locked after the autofocus transition")
                check(!c.autoFocus || c.focus == nil || focusWatchdog,
                      "Manual focus watchdog did not recover after autofocus was re-enabled")
                check(c.whiteBalance == nil && c.hue == nil || skinToneControls > 0,
                      "Skin-tone correction did not produce distinct UVC control values")
            }
        } catch {
            failures.append("UVC diagnostic for \(camera.localizedName): \(error.localizedDescription)")
        }
    }
    if !failures.isEmpty {
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}

// Opt-in integration check. It captures no photos, stores no frames, and never writes UVC
// settings. A packaged/signed check executable is needed if Terminal lacks camera permission.
if CommandLine.arguments.contains("--preview-lifecycle") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        let requestedID = arguments.firstIndex(of: "--camera-id").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        let cameras = CameraCaptureEngine.availableDevices()
        guard let camera = requestedID.flatMap({ id in cameras.first { $0.uniqueID == id } })
                ?? (requestedID == nil ? cameras.first : nil) else {
            fputs("FAIL: Requested preview camera is unavailable.\n", stderr)
            exit(1)
        }
        guard !camera.isSuspended else {
            fputs("Preview check skipped: this camera is suspended (for example, the MacBook lid is closed).\n", stderr)
            exit(2)
        }
        let engine = CameraCaptureEngine()
        var phase = 0
        let subscription = engine.$state.sink { state in
            print("Preview check: \(state.title)")
            if state == .running, phase == 0 {
                phase = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.setPreviewVisible(false) }
            } else if state == .paused, phase == 1 {
                phase = 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.setPreviewVisible(true) }
            } else if state == .running, phase == 2 {
                phase = 3
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.retry() }
            } else if state == .running, phase == 3 {
                phase = 4
                DispatchQueue.main.async { engine.select(device: nil) }
            } else if state == .idle, phase == 4 {
                print("Live preview start, release, resume, retry, and teardown passed.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            } else if state == .inUseByAnotherApp {
                fputs("Preview check skipped: another app is using this camera.\n", stderr)
                exit(2)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: Live preview lifecycle timed out.\n", stderr)
            exit(1)
        }
        engine.select(device: camera)
        engine.setPreviewVisible(true)
        withExtendedLifetime((engine, subscription)) { app.run() }
    }
}
