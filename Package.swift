// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkinToneStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinToneCore", targets: ["SkinToneCore"]),
        .executable(name: "SkinToneStudio", targets: ["SkinToneStudio"])
    ],
    targets: [
        .target(
            name: "SkinToneCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "SkinToneStudio",
            dependencies: ["SkinToneCore"]
        ),
        .executableTarget(
            name: "SkinToneChecks",
            dependencies: ["SkinToneCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
