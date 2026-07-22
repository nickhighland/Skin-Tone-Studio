import Foundation

public enum SkinToneStartingPoint: String, CaseIterable, Codable, Identifiable, Sendable {
    case light = "Light"
    case medium = "Medium"
    case tan = "Tan"
    case deep = "Deep"

    public var id: String { rawValue }

    public var guidance: String {
        switch self {
        case .light: "Balanced pink and peach undertones"
        case .medium: "Neutral warmth with gentle rosiness"
        case .tan: "Golden warmth without yellow cast"
        case .deep: "Rich color with protected highlights"
        }
    }

    public var defaults: (warmth: Double, rosiness: Double, vibrance: Double) {
        switch self {
        case .light: (0.05, 0.12, 0.04)
        case .medium: (0.09, 0.08, 0.06)
        case .tan: (0.13, 0.04, 0.07)
        case .deep: (0.08, 0.09, 0.10)
        }
    }
}

public enum PowerLineMode: Int, CaseIterable, Codable, Identifiable, Sendable {
    case disabled = 0
    case hz50 = 1
    case hz60 = 2
    case automatic = 3

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .disabled: "Off"
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        case .automatic: "Auto"
        }
    }
}

public struct ColorSettings: Codable, Equatable, Sendable {
    public var startingPoint: SkinToneStartingPoint = .medium
    public var correctionStrength = 0.62
    public var skinWarmth = 0.0
    public var rosiness = 0.0
    public var temperature = 0.0
    public var tint = 0.0
    public var exposure = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    public var vibrance = 0.0
    public var bypass = true

    public init() {}

    public mutating func apply(_ startingPoint: SkinToneStartingPoint) {
        self.startingPoint = startingPoint
        let values = startingPoint.defaults
        skinWarmth = values.warmth
        rosiness = values.rosiness
        vibrance = values.vibrance
    }

    public static var cameraNeutral: ColorSettings { ColorSettings() }

    /// The connected UVC camera's hue axis runs opposite the UI's green-to-magenta direction.
    public var normalizedCameraHueOffset: Double {
        -(tint * 0.14 + rosiness * 0.10 * correctionStrength)
    }
}

public struct HardwareSettings: Codable, Equatable, Sendable {
    public var autoFocus = false
    public var focus = 0.5
    public var powerLineMode: PowerLineMode = .hz60
    public var precisionAntiFlicker = false
    public var flickerFrequency = 60.0

    public init() {}

    /// UVC exposure-time-absolute is expressed in 100 microsecond units.
    public var antiFlickerExposureUnits: Int {
        let lightPulseFrequency = max(1, flickerFrequency * 2)
        return max(1, Int((10_000.0 / lightPulseFrequency).rounded()))
    }
}

public struct StudioProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ColorSettings
    public var hardware: HardwareSettings
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, color: ColorSettings,
                hardware: HardwareSettings, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.color = color
        self.hardware = hardware
        self.createdAt = createdAt
    }
}

public struct ControlRange: Equatable, Sendable {
    public var minimum: Int
    public var maximum: Int
    public var step: Int
    public var current: Int
    public var defaultValue: Int

    public init(minimum: Int, maximum: Int, step: Int, current: Int, defaultValue: Int) {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.current = current
        self.defaultValue = defaultValue
    }

    public var isUsable: Bool { maximum > minimum }

    public func normalizedValue(for rawValue: Int) -> Double {
        guard maximum > minimum else { return 0 }
        return Double(rawValue - minimum) / Double(maximum - minimum)
    }

    public func rawValue(for normalizedValue: Double) -> Int {
        let clamped = min(1, max(0, normalizedValue))
        let unquantized = Double(minimum) + clamped * Double(maximum - minimum)
        let increment = max(1, step)
        let steps = Int(((unquantized - Double(minimum)) / Double(increment)).rounded())
        return min(maximum, minimum + steps * increment)
    }
}

public struct CameraCapabilities: Equatable, Sendable {
    public var focus: ControlRange?
    public var autoFocus = false
    public var autoFocusEnabled: Bool?
    public var exposure: ControlRange?
    public var exposureMode = false
    public var gain: ControlRange?
    public var whiteBalance: ControlRange?
    public var autoWhiteBalance = false
    public var hue: ControlRange?
    public var saturation: ControlRange?
    public var brightness: ControlRange?
    public var contrast: ControlRange?
    public var powerLineFrequency = false
    public var powerLineMode: PowerLineMode?
    public var powerLineAutoSupported = false

    public init() {}
}
