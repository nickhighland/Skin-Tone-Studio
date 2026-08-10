// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkinToneStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinToneCore", targets: ["SkinToneCore"]),
        .executable(name: "SkinToneStudio", targets: ["SkinToneStudio"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .target(
            name: "SkinToneCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
