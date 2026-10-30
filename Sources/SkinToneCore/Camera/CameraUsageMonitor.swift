import CoreMediaIO
import Foundation

/// Some macOS UVC drivers always report isInUseByAnotherApplication == false. Once our
/// preview is released, CoreMediaIO's system-wide running flag can identify a remaining client.
final class CameraUsageMonitor {
    private let uid: String
    private var cachedID: CMIOObjectID?

    init(uid: String) { self.uid = uid }

    static func anotherAppIsUsingCamera(reportedByAVFoundation: Bool,
                                        ourCaptureIsActive: Bool,
                                        runningSomewhere: Bool?) -> Bool {
        reportedByAVFoundation || (!ourCaptureIsActive && runningSomewhere == true)
    }

    func isRunningSomewhere() -> Bool? {
        if cachedID == nil { cachedID = findDevice() }
        guard let id = cachedID else { return nil }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(id, &address, 0, nil,
                                              UInt32(MemoryLayout<UInt32>.size), &used, &running)
        guard status == noErr else { cachedID = nil; return nil }
        return running != 0
    }

    private func findDevice() -> CMIOObjectID? {
        var address = Self.address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                             0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                      0, nil, size, &used, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        for device in devices {
            var uidAddress = Self.address(kCMIODevicePropertyDeviceUID)
            var value: Unmanaged<CFString>?
            let result = CMIOObjectGetPropertyData(device, &uidAddress, 0, nil,
                                                   UInt32(MemoryLayout.size(ofValue: value)), &used, &value)
            if result == noErr, let value, value.takeRetainedValue() as String == uid { return device }
        }
        return nil
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                  mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
}
