import Foundation

public struct CameraSessionSettings: Codable, Equatable, Sendable {
    public var color: ColorSettings
    public var hardware: HardwareSettings

    public init(color: ColorSettings, hardware: HardwareSettings) {
        self.color = color
        self.hardware = hardware
    }
}

@MainActor
public final class CameraSessionStore {
    private struct StoredState: Codable {
        var selectedCameraID: String?
        var settingsByCameraID: [String: CameraSessionSettings]

        static let empty = StoredState(selectedCameraID: nil, settingsByCameraID: [:])
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: StoredState

    public init(defaults: UserDefaults = .standard,
                storageKey: String = "SkinToneStudio.CameraSessions.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            state = decoded
        } else {
            state = .empty
        }
    }

    public var selectedCameraID: String? {
        state.selectedCameraID
    }

    public func rememberSelectedCamera(id: String) {
        guard !id.isEmpty, state.selectedCameraID != id else { return }
        state.selectedCameraID = id
        persist()
    }

    public func settings(for cameraID: String) -> CameraSessionSettings? {
        state.settingsByCameraID[cameraID]
    }

    public func save(color: ColorSettings, hardware: HardwareSettings, for cameraID: String) {
        guard !cameraID.isEmpty else { return }
        state.settingsByCameraID[cameraID] = CameraSessionSettings(color: color, hardware: hardware)
        persist()
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: storageKey)
        } catch {
            NSLog("Could not save the last Skin Tone Studio camera settings: %@", error.localizedDescription)
        }
    }
}
