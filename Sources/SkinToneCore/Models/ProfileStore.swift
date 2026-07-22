import Foundation

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [StudioProfile] = []

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("SkinToneStudio", isDirectory: true)
                .appendingPathComponent("profiles.json")
        }
        load()
    }

    public func save(name: String, color: ColorSettings, hardware: HardwareSettings) {
        profiles.append(StudioProfile(name: name, color: color, hardware: hardware))
        persist()
    }

    public func delete(_ profile: StudioProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    public func replace(_ profile: StudioProfile, color: ColorSettings, hardware: HardwareSettings) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].color = color
        profiles[index].hardware = hardware
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StudioProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Could not save Skin Tone Studio profiles: %@", error.localizedDescription)
        }
    }
}
