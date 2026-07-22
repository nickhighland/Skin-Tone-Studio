import Foundation
import SkinToneCore
import AVFoundation

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
            print("UVC hardware: \(camera.localizedName)")
            print("  manual focus: \(c.focus != nil), autofocus: \(c.autoFocus)")
            print("  exposure: \(c.exposure != nil), gain: \(c.gain != nil)")
            print("  white balance: \(c.whiteBalance != nil), hue: \(c.hue != nil), saturation: \(c.saturation != nil)")
            print("  powerline frequency: \(c.powerLineFrequency), auto mode: \(c.powerLineAutoSupported)")
            if CommandLine.arguments.contains("--hardware-write") {
                let writes = try controller.verifyRealtimeWritePath()
                print("  state-neutral live writes verified: \(writes)")
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
