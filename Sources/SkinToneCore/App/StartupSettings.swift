import AppKit
import Combine
import ServiceManagement

public final class StartupSettings: ObservableObject {
    public static let shared = StartupSettings()

    @Published public private(set) var startsWithComputer = false
    @Published public private(set) var requiresApproval = false
    @Published public private(set) var message: String?

    private init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        startsWithComputer = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    public func setStartsWithComputer(_ enabled: Bool) {
        message = nil

        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    message = "Allow Skin Tone Studio under Login Items in System Settings to finish enabling startup."
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                @unknown default:
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Skin Tone Studio could not update its login item: \(error.localizedDescription)"
        }

        refresh()
        if requiresApproval && message == nil {
            message = "Allow Skin Tone Studio under Login Items in System Settings to finish enabling startup."
        }
    }

    public func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
