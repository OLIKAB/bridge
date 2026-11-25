// swift-tools-version:5.9
import PackageDescription

/// SwiftPM links the app with the SDK version set to the deployment target (sdk 14.0), and macOS
/// runs an app built against an older SDK in compatibility mode: no Liquid Glass, the old small panel
/// corners and the old text fields. This records the SDK it's really built with (27), so it gets
/// the current look, while still running on macOS 14. Keep it at the installed Xcode's SDK: on macOS 27
/// an app linked against 26 keeps 26's controls, without e.g. the segmented control's glass lens.
let currentSDK: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "27.0"]),
]

let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bridge", targets: ["Bridge"]),
        /// The menu bar panel controls, tooltips, motion and system integration Bridge is built from,
        /// as a library so other menu bar apps can use them too.
        .library(name: "Shared", targets: ["Shared"]),
    ],
    targets: [
        .target(name: "Shared", path: "Sources/Shared"),
        .executableTarget(name: "Bridge", dependencies: ["Shared"], path: "Sources/Bridge", linkerSettings: currentSDK),
    ]
)
