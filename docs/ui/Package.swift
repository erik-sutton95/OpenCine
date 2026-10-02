// swift-tools-version: 6.0
import PackageDescription

// Shared OpenCine presentation policy and native SwiftUI monitor screens.
// Neither target depends on a camera protocol core, a vendor package or an app.
// MonitorUI is iOS-only source (`#if os(iOS)`); on macOS it compiles empty so
// `swift test` runs MonitorPresentationTests natively.
let package = Package(
    name: "OpenCineUI",
    platforms: [.iOS(.v17), .macOS(.v12), .watchOS(.v10)],
    products: [
        .library(name: "MonitorPresentation", targets: ["MonitorPresentation"]),
        .library(name: "MonitorUI", targets: ["MonitorUI"]),
    ],
    targets: [
        .target(name: "MonitorPresentation"),
        .target(
            name: "MonitorUI", dependencies: ["MonitorPresentation"],
            resources: [.process("Resources/Fonts"), .copy("Resources/Icons")]
        ),
        .testTarget(name: "MonitorPresentationTests", dependencies: ["MonitorPresentation"]),
    ]
)
