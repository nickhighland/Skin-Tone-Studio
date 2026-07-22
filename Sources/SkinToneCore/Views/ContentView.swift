import AppKit
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case tone = "Skin Tone"
    case camera = "Camera"
    case profiles = "Profiles"
    var id: String { rawValue }
}

public struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var tab: InspectorTab = .tone

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.055)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.65)
                HStack(spacing: 0) {
                    previewArea
                    Divider().opacity(0.65)
                    inspector
                }
            }
        }
        .frame(minWidth: 1040, idealWidth: 1180, minHeight: 700, idealHeight: 780)
        .onAppear {
            model.start()
            DispatchQueue.main.async {
                NSApp.windows.first?.title = "Skin Tone Studio"
                NSApp.windows.first?.sharingType = .readOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .skinToneStudioCameraReset)) { _ in
            model.resetCamera()
        }
        .alert("Skin Tone Studio", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Skin Tone Studio").font(.headline)
                Text("Natural color · locked focus · clean light").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Picker("Camera", selection: Binding(
                get: { model.selectedCameraID },
                set: { model.selectCamera(id: $0) }
            )) {
                ForEach(model.cameras) { camera in
                    Label(camera.name, systemImage: camera.isExternal ? "web.camera" : "laptopcomputer")
                        .tag(camera.id)
                }
            }
            .labelsHidden()
            .frame(width: 280)

            Button {
                model.resetCamera()
            } label: {
                Label("Camera Reset", systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.controlStatus != .ready)
            .help("Restore the webcam's factory-default UVC settings")

            statusBadge
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    @ViewBuilder private var statusBadge: some View {
        let ready = model.controlStatus == .ready
        HStack(spacing: 6) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.controlStatus.title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .help({
            if case .previewOnly(let reason) = model.controlStatus { return reason }
            return ready ? "This USB camera accepts hardware controls." : "Detecting camera capabilities."
        }())
    }

    private var previewArea: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.20), radius: 24, y: 12)
                CameraPreview(engine: model.captureEngine)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                if model.permissionDenied {
                    permissionView
                } else if model.cameras.isEmpty {
                    ContentUnavailableView(
                        "No Camera Found", systemImage: "video.slash",
                        description: Text("Connect a camera, then reopen the camera menu.")
                    ).foregroundStyle(.white)
                }

                VStack {
                    HStack {
                        Label("Live camera output", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }.padding(14)
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Every adjustment is live").font(.caption.weight(.medium))
                    Text("This is the same hardware output used by meeting and recording apps.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 38))
            Text("Camera access is off").font(.title3.weight(.semibold))
            Text("Enable Skin Tone Studio in System Settings → Privacy & Security → Camera.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(18)

            ScrollView {
                Group {
                    switch tab {
                    case .tone: ToneInspector(model: model)
                    case .camera: CameraInspector(model: model)
                    case .profiles: ProfilesInspector(model: model)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 22)
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
    }
}

private struct ToneInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorHeader(
                title: "Natural skin tone",
                subtitle: "Choose a starting point, then fine-tune. Every change is applied directly to the webcam."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("STARTING POINT").sectionLabel()
                HStack(spacing: 7) {
                    ForEach(SkinToneStartingPoint.allCases) { point in
                        Button(point.rawValue) { model.chooseStartingPoint(point) }
                            .buttonStyle(ToneChipStyle(selected: model.colorSettings.startingPoint == point))
                    }
                }
                Text(model.colorSettings.startingPoint.guidance)
                    .font(.caption).foregroundStyle(.secondary)
            }

            ControlCard(title: "Skin tone correction") {
                StudioSlider(title: "Strength", value: $model.colorSettings.correctionStrength,
                             range: 0...1, display: .percent)
                StudioSlider(title: "Warmth", value: $model.colorSettings.skinWarmth,
                             range: -0.5...0.5, display: .signed)
                StudioSlider(title: "Rosiness", value: $model.colorSettings.rosiness,
                             range: -0.5...0.5, display: .signed)
            }

            ControlCard(title: "Color cast") {
                StudioSlider(title: "Cool  ·  Warm", value: $model.colorSettings.temperature,
                             range: -1...1, display: .signed)
                StudioSlider(title: "Green  ·  Magenta", value: $model.colorSettings.tint,
                             range: -1...1, display: .signed)
            }

            ControlCard(title: "Picture") {
                StudioSlider(title: "Brightness", value: $model.colorSettings.exposure,
                             range: -1.5...1.5, display: .decimal)
                StudioSlider(title: "Contrast", value: $model.colorSettings.contrast,
                             range: 0.65...1.35, display: .decimal)
                StudioSlider(title: "Saturation", value: $model.colorSettings.saturation,
                             range: 0.5...1.5, display: .decimal)
                StudioSlider(title: "Vibrance", value: $model.colorSettings.vibrance,
                             range: -0.5...0.5, display: .signed)
            }

            Label("Live UVC controls—nothing needs to be sent or applied.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.controlStatus != .ready)
    }
}

private struct CameraInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorHeader(title: "Camera hardware",
                            subtitle: "Only controls reported by the selected webcam are enabled.")

            ControlCard(title: "Focus") {
                Toggle("Continuous autofocus", isOn: Binding(
                    get: { model.hardwareSettings.autoFocus },
                    set: { model.hardwareSettings.autoFocus = $0; model.applyAutoFocus() }
                ))
                .disabled(!model.capabilities.autoFocus)

                StudioSlider(
                    title: "Near  ·  Far",
                    value: Binding(
                        get: { model.hardwareSettings.focus },
                        set: { model.hardwareSettings.focus = $0; model.applyFocus() }
                    ),
                    range: 0...1,
                    display: .percent,
                    disabled: model.capabilities.focus == nil || model.hardwareSettings.autoFocus,
                    onCommit: {}
                )
                if model.capabilities.focus == nil {
                    UnsupportedHint(text: "Manual focus is not exposed by this camera.")
                }
            }

            ControlCard(title: "Powerline frequency") {
                Picker("Mode", selection: Binding(
                    get: { model.hardwareSettings.powerLineMode },
                    set: { model.hardwareSettings.powerLineMode = $0; model.applyPowerLineMode() }
                )) {
                    ForEach(PowerLineMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!model.capabilities.powerLineFrequency)

                Toggle("Precision LED anti-flicker", isOn: $model.hardwareSettings.precisionAntiFlicker)
                StudioSlider(title: "LED / mains frequency",
                             value: $model.hardwareSettings.flickerFrequency,
                             range: 45...65, display: .hertz,
                             disabled: !model.hardwareSettings.precisionAntiFlicker)
                Text("Suggested shutter: 1/\(Int((model.hardwareSettings.flickerFrequency * 2).rounded())) s")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { model.applyAntiFlicker() } label: {
                    Label("Apply anti-flicker tuning", systemImage: "lightbulb.min")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.hardwareSettings.precisionAntiFlicker
                          || (model.capabilities.exposure == nil && !model.capabilities.powerLineFrequency))
            }

            if case .previewOnly(let reason) = model.controlStatus {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Software preview available", systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                .padding(13).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct ProfilesInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profileStore: ProfileStore
    @State private var name = "My look"

    init(model: AppModel) {
        self.model = model
        _profileStore = ObservedObject(wrappedValue: model.profiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorHeader(title: "Saved looks",
                            subtitle: "A profile stores color, focus, and anti-flicker settings together.")
            ControlCard(title: "Save current look") {
                TextField("Profile name", text: $name)
                Button {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    profileStore.save(name: trimmed.isEmpty ? "Untitled look" : trimmed,
                                      color: model.colorSettings, hardware: model.hardwareSettings)
                    name = ""
                } label: {
                    Label("Save profile", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if profileStore.profiles.isEmpty {
                ContentUnavailableView("No Saved Looks", systemImage: "square.stack.3d.up.slash",
                                       description: Text("Your current settings can be saved above."))
                    .frame(maxWidth: .infinity).padding(.top, 26)
            } else {
                VStack(spacing: 9) {
                    ForEach(profileStore.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.subheadline.weight(.semibold))
                                Text(profile.color.startingPoint.rawValue + " starting point")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Load") { model.load(profile) }.buttonStyle(.bordered)
                            Button(role: .destructive) { profileStore.delete(profile) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.plain)
                        }
                        .padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

private struct InspectorHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ControlCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased()).sectionLabel()
            content
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
    }
}

private enum SliderDisplay { case percent, signed, decimal, hertz }

private struct StudioSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: SliderDisplay
    var disabled = false
    var onCommit: () -> Void = {}

    var formatted: String {
        switch display {
        case .percent: "\(Int(value * 100))%"
        case .signed: String(format: "%+.2f", value)
        case .decimal: String(format: "%.2f", value)
        case .hertz: String(format: "%.1f Hz", value)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(formatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: { if !$0 { onCommit() } })
        }
        .disabled(disabled).opacity(disabled ? 0.5 : 1)
    }
}

private struct UnsupportedHint: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct ToneChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private extension Text {
    func sectionLabel() -> some View {
        font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
    }
}
