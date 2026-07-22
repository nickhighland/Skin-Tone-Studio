import AVFoundation
import Foundation
import IOKit
import IOKit.usb

private typealias USBDeviceInterfacePointer = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>
private typealias USBInterfacePointer = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>
private typealias PluginInterfacePointer = UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>>

public enum UVCCameraError: LocalizedError {
    case notUSBVideoClass
    case deviceNotFound
    case interfaceUnavailable
    case descriptorUnavailable
    case malformedDescriptor
    case requestFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .notUSBVideoClass: "This camera does not identify itself as a controllable USB webcam."
        case .deviceNotFound: "The USB camera could not be matched to its macOS capture device."
        case .interfaceUnavailable: "The webcam's UVC control interface is currently unavailable."
        case .descriptorUnavailable: "The webcam did not provide a readable USB configuration descriptor."
        case .malformedDescriptor: "The webcam supplied an incomplete UVC descriptor."
        case .requestFailed(let code): "The webcam rejected a UVC control request (\(code))."
        }
    }
}

private enum UVCRequest: UInt8 {
    case setCurrent = 0x01
    case getCurrent = 0x81
    case getMinimum = 0x82
    case getMaximum = 0x83
    case getResolution = 0x84
    case getInfo = 0x86
    case getDefault = 0x87
}

private enum UVCUnit {
    case cameraTerminal
    case processingUnit
}

private struct UVCControlDefinition {
    let selector: UInt8
    let size: Int
    let unit: UVCUnit
    let signed: Bool

    static let exposureMode = Self(selector: 0x02, size: 1, unit: .cameraTerminal, signed: false)
    static let exposureTime = Self(selector: 0x04, size: 4, unit: .cameraTerminal, signed: false)
    static let focus = Self(selector: 0x06, size: 2, unit: .cameraTerminal, signed: false)
    static let autoFocus = Self(selector: 0x08, size: 1, unit: .cameraTerminal, signed: false)

    static let brightness = Self(selector: 0x02, size: 2, unit: .processingUnit, signed: true)
    static let contrast = Self(selector: 0x03, size: 2, unit: .processingUnit, signed: false)
    static let gain = Self(selector: 0x04, size: 2, unit: .processingUnit, signed: false)
    static let powerLine = Self(selector: 0x05, size: 1, unit: .processingUnit, signed: false)
    static let hue = Self(selector: 0x06, size: 2, unit: .processingUnit, signed: true)
    static let saturation = Self(selector: 0x07, size: 2, unit: .processingUnit, signed: false)
    static let whiteBalance = Self(selector: 0x0A, size: 2, unit: .processingUnit, signed: false)
    static let autoWhiteBalance = Self(selector: 0x0B, size: 1, unit: .processingUnit, signed: false)
}

private struct UVCDescriptorIDs {
    let interface: Int
    let cameraTerminal: Int
    let processingUnit: Int
}

/// Direct USB Video Class controls. Effects from this controller remain active when another app uses the camera.
public final class UVCController: @unchecked Sendable {
    public private(set) var capabilities = CameraCapabilities()

    private let interface: USBInterfacePointer
    private let descriptor: UVCDescriptorIDs
    private let lock = NSLock()
    private var baselineWhiteBalance: Int?
    private var baselineHue: Int?
    private var baselineSaturation: Int?
    private var baselineBrightness: Int?
    private var baselineContrast: Int?
    private var whiteBalanceWasAdjusted = false
    private var hueWasAdjusted = false
    private var saturationWasAdjusted = false
    private var brightnessWasAdjusted = false
    private var contrastWasAdjusted = false

    public init(device: AVCaptureDevice) throws {
        let usbIDs = try Self.usbIDs(from: device.modelID)
        let service = try Self.findService(for: device, vendorID: usbIDs.vendor, productID: usbIDs.product)
        defer { IOObjectRelease(service) }

        let result = try Self.openControlInterface(from: service)
        interface = result.interface
        descriptor = result.descriptor

        var detected = CameraCapabilities()
        detected.focus = try? range(for: .focus)
        detected.autoFocus = isSupported(.autoFocus)
        if detected.autoFocus {
            detected.autoFocusEnabled = (try? read(.getCurrent, from: .autoFocus)).map { $0 != 0 }
        }
        detected.exposure = try? range(for: .exposureTime)
        detected.exposureMode = isSupported(.exposureMode)
        detected.gain = try? range(for: .gain)
        detected.whiteBalance = try? range(for: .whiteBalance)
        detected.autoWhiteBalance = isSupported(.autoWhiteBalance)
        detected.hue = try? range(for: .hue)
        detected.saturation = try? range(for: .saturation)
        detected.brightness = try? range(for: .brightness)
        detected.contrast = try? range(for: .contrast)
        detected.powerLineFrequency = isSupported(.powerLine)
        if detected.powerLineFrequency {
            let currentPowerLine = try? read(.getCurrent, from: .powerLine)
            detected.powerLineMode = currentPowerLine.flatMap(PowerLineMode.init(rawValue:))
            let maximumPowerLine = try? read(.getMaximum, from: .powerLine)
            detected.powerLineAutoSupported = (maximumPowerLine ?? 0) >= PowerLineMode.automatic.rawValue
                || currentPowerLine == PowerLineMode.automatic.rawValue
        }
        capabilities = detected
        setColorBaselinesToDefaults()
    }

    deinit {
        _ = interface.pointee.pointee.Release(interface)
    }

    public func setAutoFocus(_ enabled: Bool) throws {
        try write(enabled ? 1 : 0, to: .autoFocus)
    }

    public func setFocus(normalized: Double) throws {
        guard let range = capabilities.focus else { return }
        try write(range.rawValue(for: normalized), to: .focus)
    }

    public func setPowerLineMode(_ mode: PowerLineMode) throws {
        try write(mode.rawValue, to: .powerLine)
    }

    public func applyPrecisionAntiFlicker(frequency: Double) throws {
        let clampedFrequency = min(65, max(45, frequency))
        if capabilities.powerLineFrequency {
            try setPowerLineMode(clampedFrequency < 55 ? .hz50 : .hz60)
        }
        if capabilities.exposureMode, capabilities.exposure != nil {
            try write(1, to: .exposureMode) // UVC manual exposure mode
            let exposureUnits = max(1, Int((10_000 / (clampedFrequency * 2)).rounded()))
            if let range = capabilities.exposure {
                try write(min(range.maximum, max(range.minimum, exposureUnits)), to: .exposureTime)
            }
        }
    }

    public func applyHardwareLook(_ color: ColorSettings) throws {
        var firstError: Error?
        var successfulWrites = 0
        func attempt(_ action: () throws -> Void) {
            do { try action(); successfulWrites += 1 } catch { if firstError == nil { firstError = error } }
        }

        let skinStrength = color.correctionStrength
        let whiteBalanceDelta = color.temperature * 0.22 + color.skinWarmth * 0.19 * skinStrength
        if abs(whiteBalanceDelta) > 0.0005 { whiteBalanceWasAdjusted = true }
        if whiteBalanceWasAdjusted, let range = capabilities.whiteBalance {
            if capabilities.autoWhiteBalance { attempt { try write(0, to: .autoWhiteBalance) } }
            let baseline = range.normalizedValue(for: baselineWhiteBalance ?? range.current)
            attempt { try write(range.rawValue(for: baseline + whiteBalanceDelta), to: .whiteBalance) }
        }
        if let range = capabilities.hue {
            let baseline = range.normalizedValue(for: baselineHue ?? range.current)
            let delta = color.normalizedCameraHueOffset
            if abs(delta) > 0.0005 { hueWasAdjusted = true }
            if hueWasAdjusted { attempt { try write(range.rawValue(for: baseline + delta), to: .hue) } }
        }
        if let range = capabilities.saturation {
            let baseline = range.normalizedValue(for: baselineSaturation ?? range.current)
            let delta = (color.saturation - 1) * 0.36 + color.vibrance * 0.16
            if abs(delta) > 0.0005 { saturationWasAdjusted = true }
            if saturationWasAdjusted { attempt { try write(range.rawValue(for: baseline + delta), to: .saturation) } }
        }
        if let range = capabilities.brightness {
            let baseline = range.normalizedValue(for: baselineBrightness ?? range.current)
            let delta = color.exposure * 0.09
            if abs(delta) > 0.0005 { brightnessWasAdjusted = true }
            if brightnessWasAdjusted { attempt { try write(range.rawValue(for: baseline + delta), to: .brightness) } }
        }
        if let range = capabilities.contrast {
            let baseline = range.normalizedValue(for: baselineContrast ?? range.current)
            let delta = (color.contrast - 1) * 0.42
            if abs(delta) > 0.0005 { contrastWasAdjusted = true }
            if contrastWasAdjusted { attempt { try write(range.rawValue(for: baseline + delta), to: .contrast) } }
        }
        if successfulWrites == 0, let firstError { throw firstError }
    }

    /// Restores only the controls represented by the color sliders, leaving focus and flicker settings intact.
    public func resetColorToDefaults() throws {
        var firstError: Error?
        var successfulWrites = 0
        func attempt(_ action: () throws -> Void) {
            do { try action(); successfulWrites += 1 }
            catch { if firstError == nil { firstError = error } }
        }
        func reset(_ definition: UVCControlDefinition) {
            guard isSupported(definition), let value = try? read(.getDefault, from: definition) else { return }
            attempt { try write(value, to: definition) }
        }

        let previousAutoWhiteBalance = try? read(.getCurrent, from: .autoWhiteBalance)
        if capabilities.autoWhiteBalance { attempt { try write(0, to: .autoWhiteBalance) } }
        [UVCControlDefinition.whiteBalance, .hue, .saturation, .brightness, .contrast].forEach(reset)

        if capabilities.autoWhiteBalance {
            let automaticDefault = try? read(.getDefault, from: .autoWhiteBalance)
            if let value = automaticDefault ?? previousAutoWhiteBalance {
                attempt { try write(value, to: .autoWhiteBalance) }
            }
        }

        setColorBaselinesToDefaults()
        if successfulWrites == 0, let firstError { throw firstError }
    }

    public func resetToDefaults() throws {
        var firstError: Error?
        var successfulWrites = 0
        @discardableResult func attempt(_ action: () throws -> Void) -> Bool {
            do { try action(); successfulWrites += 1; return true }
            catch { if firstError == nil { firstError = error }; return false }
        }
        func reset(_ definition: UVCControlDefinition) {
            guard isSupported(definition), let value = try? read(.getDefault, from: definition) else { return }
            attempt { try write(value, to: definition) }
        }

        let previousAutoWhiteBalance = try? read(.getCurrent, from: .autoWhiteBalance)
        let previousAutoFocus = try? read(.getCurrent, from: .autoFocus)
        let previousExposureMode = try? read(.getCurrent, from: .exposureMode)

        // Temporarily disable automatic modes so their paired manual defaults can be restored.
        if capabilities.autoWhiteBalance { attempt { try write(0, to: .autoWhiteBalance) } }
        if capabilities.autoFocus { attempt { try write(0, to: .autoFocus) } }
        if capabilities.exposureMode { attempt { try write(1, to: .exposureMode) } }

        [.whiteBalance, .hue, .saturation, .brightness, .contrast, .gain,
         .exposureTime, .focus, .powerLine].forEach(reset)

        // Restore the camera's factory automatic/manual choices last.
        func restoreAutomatic(_ definition: UVCControlDefinition, fallback: Int?) {
            guard isSupported(definition) else { return }
            if let value = try? read(.getDefault, from: definition) {
                attempt { try write(value, to: definition) }
            } else if let fallback {
                attempt { try write(fallback, to: definition) }
            }
        }
        restoreAutomatic(.autoWhiteBalance, fallback: previousAutoWhiteBalance)
        restoreAutomatic(.autoFocus, fallback: previousAutoFocus)
        restoreAutomatic(.exposureMode, fallback: previousExposureMode)

        setColorBaselinesToDefaults()

        if successfulWrites == 0, let firstError { throw firstError }
    }

    private func setColorBaselinesToDefaults() {
        baselineWhiteBalance = capabilities.whiteBalance?.defaultValue
        baselineHue = capabilities.hue?.defaultValue
        baselineSaturation = capabilities.saturation?.defaultValue
        baselineBrightness = capabilities.brightness?.defaultValue
        baselineContrast = capabilities.contrast?.defaultValue
        whiteBalanceWasAdjusted = false
        hueWasAdjusted = false
        saturationWasAdjusted = false
        brightnessWasAdjusted = false
        contrastWasAdjusted = false
    }

    public func currentHardwareSettings() -> HardwareSettings {
        var settings = HardwareSettings()
        if capabilities.autoFocus,
           let raw = try? read(.getCurrent, from: .autoFocus) {
            settings.autoFocus = raw != 0
        }
        if let range = capabilities.focus,
           let raw = try? read(.getCurrent, from: .focus) {
            settings.focus = range.normalizedValue(for: raw)
        }
        if capabilities.powerLineFrequency,
           let raw = try? read(.getCurrent, from: .powerLine),
           let mode = PowerLineMode(rawValue: raw) {
            settings.powerLineMode = mode
        }
        return settings
    }

    /// Exercises the same UVC OUT request used for live sliders while writing each control's current value back unchanged.
    @discardableResult public func verifyRealtimeWritePath() throws -> Int {
        var writes = 0
        var firstError: Error?
        for definition in [UVCControlDefinition.hue, .saturation, .brightness, .contrast, .powerLine] {
            guard isSupported(definition), let current = try? read(.getCurrent, from: definition) else { continue }
            do { try write(current, to: definition); writes += 1 }
            catch { if firstError == nil { firstError = error } }
        }
        if writes == 0, let firstError { throw firstError }
        return writes
    }

    private func isSupported(_ definition: UVCControlDefinition) -> Bool {
        guard let info = try? read(.getInfo, from: definition) else { return false }
        return info & 0b11 != 0
    }

    private func range(for definition: UVCControlDefinition) throws -> ControlRange {
        let minimum = try read(.getMinimum, from: definition)
        let maximum = try read(.getMaximum, from: definition)
        let resolution = max(1, try read(.getResolution, from: definition))
        let current = try read(.getCurrent, from: definition)
        let defaultValue = try read(.getDefault, from: definition)
        guard maximum > minimum else { throw UVCCameraError.malformedDescriptor }
        return ControlRange(minimum: minimum, maximum: maximum, step: resolution,
                            current: current, defaultValue: defaultValue)
    }

    private func read(_ requestCode: UVCRequest, from definition: UVCControlDefinition) throws -> Int {
        try perform(requestCode, definition: definition, value: nil)
    }

    private func write(_ value: Int, to definition: UVCControlDefinition) throws {
        _ = try perform(.setCurrent, definition: definition, value: value)
    }

    private func perform(_ requestCode: UVCRequest, definition: UVCControlDefinition,
                         value: Int?) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let direction = value == nil ? kUSBIn : kUSBOut
        let requestType = UInt8((direction & kUSBRqDirnMask) << kUSBRqDirnShift)
            | UInt8((kUSBClass & kUSBRqTypeMask) << kUSBRqTypeShift)
            | UInt8(kUSBInterface & kUSBRqRecipientMask)
        let unitID = definition.unit == .cameraTerminal
            ? descriptor.cameraTerminal : descriptor.processingUnit

        var storage = UInt64(bitPattern: Int64(value ?? 0)).littleEndian
        let status: IOReturn = withUnsafeMutablePointer(to: &storage) { pointer in
            var request = IOUSBDevRequest(
                bmRequestType: requestType,
                bRequest: requestCode.rawValue,
                wValue: UInt16(definition.selector) << 8,
                wIndex: UInt16(unitID << 8 | descriptor.interface),
                wLength: UInt16(definition.size),
                pData: UnsafeMutableRawPointer(pointer),
                wLenDone: 0
            )
            return interface.pointee.pointee.ControlRequest(interface, 0, &request)
        }
        guard status == kIOReturnSuccess else { throw UVCCameraError.requestFailed(status) }

        let unsigned = UInt64(littleEndian: storage)
        let bitCount = definition.size * 8
        let mask = bitCount == 64 ? UInt64.max : (UInt64(1) << UInt64(bitCount)) - 1
        let raw = unsigned & mask
        if definition.signed, bitCount < 64, raw & (UInt64(1) << UInt64(bitCount - 1)) != 0 {
            return Int(Int64(raw) - Int64(UInt64(1) << UInt64(bitCount)))
        }
        return Int(raw)
    }

    private static func usbIDs(from modelID: String) throws -> (vendor: Int, product: Int) {
        let pattern = #"^UVC\s+Camera\s+VendorID_([0-9]+)\s+ProductID_([0-9]+)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(modelID.startIndex..., in: modelID)
        guard let match = regex.firstMatch(in: modelID, range: fullRange),
              let vendorRange = Range(match.range(at: 1), in: modelID),
              let productRange = Range(match.range(at: 2), in: modelID),
              let vendor = Int(modelID[vendorRange]), let product = Int(modelID[productRange]) else {
            throw UVCCameraError.notUSBVideoClass
        }
        return (vendor, product)
    }

    private static func findService(for device: AVCaptureDevice, vendorID: Int,
                                    productID: Int) throws -> io_service_t {
        guard let matching = IOServiceMatching("IOUSBDevice") else { throw UVCCameraError.deviceNotFound }
        let dictionary = matching as NSMutableDictionary
        dictionary["idVendor"] = vendorID
        dictionary["idProduct"] = productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == kIOReturnSuccess else {
            throw UVCCameraError.deviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        var fallback: io_service_t = 0
        while true {
            let candidate = IOIteratorNext(iterator)
            guard candidate != 0 else { break }
            if fallback == 0 { fallback = candidate }

            var properties: Unmanaged<CFMutableDictionary>?
            let matched: Bool
            if IORegistryEntryCreateCFProperties(candidate, &properties, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
               let values = properties?.takeRetainedValue() as NSDictionary?,
               let locationID = values["locationID"] as? Int {
                matched = device.uniqueID.hasPrefix("0x" + String(locationID, radix: 16))
            } else {
                matched = false
            }
            if matched {
                if fallback != candidate { IOObjectRelease(fallback) }
                return candidate
            }
            if fallback != candidate { IOObjectRelease(candidate) }
        }
        guard fallback != 0 else { throw UVCCameraError.deviceNotFound }
        return fallback
    }

    private static func openControlInterface(from service: io_service_t) throws
        -> (interface: USBInterfacePointer, descriptor: UVCDescriptorIDs) {
        let devicePlugin = try createPlugin(for: service, typeID: kIOUSBDeviceUserClientTypeID)
        defer { _ = devicePlugin.pointee.pointee.Release(devicePlugin) }
        let deviceInterface: USBDeviceInterfacePointer = try query(devicePlugin, uuid: kIOUSBDeviceInterfaceID)
        defer { _ = deviceInterface.pointee.pointee.Release(deviceInterface) }

        var descriptor: IOUSBConfigurationDescriptorPtr?
        guard deviceInterface.pointee.pointee.GetConfigurationDescriptorPtr(deviceInterface, 0, &descriptor)
                == kIOReturnSuccess,
              let descriptor else { throw UVCCameraError.descriptorUnavailable }
        let parsedDescriptor = try parseDescriptor(descriptor)

        var request = IOUSBFindInterfaceRequest(
            bInterfaceClass: 0x0E,
            bInterfaceSubClass: 0x01,
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare)
        )
        var iterator: io_iterator_t = 0
        guard deviceInterface.pointee.pointee.CreateInterfaceIterator(deviceInterface, &request, &iterator)
                == kIOReturnSuccess else { throw UVCCameraError.interfaceUnavailable }
        defer { IOObjectRelease(iterator) }

        while true {
            let interfaceService = IOIteratorNext(iterator)
            guard interfaceService != 0 else { break }
            defer { IOObjectRelease(interfaceService) }
            if let plugin = try? createPlugin(for: interfaceService, typeID: kIOUSBInterfaceUserClientTypeID) {
                defer { _ = plugin.pointee.pointee.Release(plugin) }
                if let interface: USBInterfacePointer = try? query(plugin, uuid: kIOUSBInterfaceInterfaceID) {
                    return (interface, parsedDescriptor)
                }
            }
        }
        throw UVCCameraError.interfaceUnavailable
    }

    private static func createPlugin(for service: io_service_t, typeID: CFUUID) throws
        -> PluginInterfacePointer {
        var optionalPlugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let status = IOCreatePlugInInterfaceForService(
            service, typeID, kIOCFPlugInInterfaceID, &optionalPlugin, &score
        )
        guard status == kIOReturnSuccess, let optionalPlugin else {
            throw UVCCameraError.interfaceUnavailable
        }
        return optionalPlugin.withMemoryRebound(
            to: UnsafeMutablePointer<IOCFPlugInInterface>.self, capacity: 1
        ) { $0 }
    }

    private static func query<T>(_ plugin: PluginInterfacePointer, uuid: CFUUID) throws
        -> UnsafeMutablePointer<T> {
        var raw: LPVOID?
        let status = plugin.pointee.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(uuid), &raw)
        guard status == kIOReturnSuccess, let result = raw?.assumingMemoryBound(to: T.self) else {
            throw UVCCameraError.interfaceUnavailable
        }
        return result
    }

    private static func parseDescriptor(_ descriptor: IOUSBConfigurationDescriptorPtr) throws
        -> UVCDescriptorIDs {
        let totalLength = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
        var offset = Int(descriptor.pointee.bLength)
        let bytes = UnsafeRawPointer(descriptor).assumingMemoryBound(to: UInt8.self)
        var currentInterface = -1
        var cameraTerminal = -1
        var processingUnit = -1

        while offset + 3 <= totalLength {
            let length = Int(bytes[offset])
            guard length >= 3, offset + length <= totalLength else { break }
            let type = bytes[offset + 1]
            if type == UInt8(kUSBInterfaceDesc), length >= 9 {
                let interfaceClass = bytes[offset + 5]
                let interfaceSubclass = bytes[offset + 6]
                currentInterface = interfaceClass == 0x0E && interfaceSubclass == 0x01
                    ? Int(bytes[offset + 2]) : -1
            } else if type == 0x24, currentInterface >= 0 {
                let subtype = bytes[offset + 2]
                if subtype == 0x02, length >= 4 { cameraTerminal = Int(bytes[offset + 3]) }
                if subtype == 0x05, length >= 4 { processingUnit = Int(bytes[offset + 3]) }
            }
            offset += length
        }
        guard currentInterface >= 0 || (cameraTerminal >= 0 && processingUnit >= 0),
              cameraTerminal >= 0, processingUnit >= 0 else {
            throw UVCCameraError.malformedDescriptor
        }
        // Most cameras expose one VideoControl interface. Locate its number once more if parsing moved onward.
        offset = Int(descriptor.pointee.bLength)
        var videoControlInterface = 0
        while offset + 9 <= totalLength {
            let length = Int(bytes[offset])
            guard length > 0 else { break }
            if bytes[offset + 1] == UInt8(kUSBInterfaceDesc), bytes[offset + 5] == 0x0E,
               bytes[offset + 6] == 0x01 {
                videoControlInterface = Int(bytes[offset + 2])
                break
            }
            offset += length
        }
        return UVCDescriptorIDs(interface: videoControlInterface,
                                cameraTerminal: cameraTerminal,
                                processingUnit: processingUnit)
    }
}

// UUIDs from Apple's deprecated IOUSBLib API, still used by the system UVC user client.
private let kIOUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
    0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!
private let kIOUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4,
    0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!
private let kIOUSBInterfaceInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault, 0x73, 0xc9, 0x7a, 0xe8, 0x9e, 0xf3, 0x11, 0xD4,
    0xb1, 0xd0, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!
private let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)!
private let kIOUSBInterfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
    kCFAllocatorDefault, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4,
    0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!
