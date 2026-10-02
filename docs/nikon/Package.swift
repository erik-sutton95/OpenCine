// swift-tools-version: 6.0
import PackageDescription

// Nikon integration for OpenCine apps: PTP/IP and PTP/USB wire, Nikon property codes, decoders,
// capability profiles and media naming, discovery/connect/session policy, saved camera records,
// and NikonCameraSession (OpenCineCore's CameraSession over a NikonControlDriver the app's
// control service implements). Foundation plus OpenCineCore; no UI, no app types. Builds with
// the Swift Android SDK (the OpenZCine JNI facade links it).
let package = Package(
    name: "OpenCineNikon",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineNikon", targets: ["OpenCineNikon"])
    ],
    dependencies: [
        // Sibling checkout pinned in opencine-pins.txt until OpenCineCore is published.
        .package(path: "../OpenCineCore")
    ],
    targets: [
        .target(
            name: "OpenCineNikon",
            dependencies: [
                // NikonCameraSession implements OpenCineCore.CameraSession.
                .product(name: "OpenCineCore", package: "OpenCineCore")
            ]
        ),
        .testTarget(
            name: "OpenCineNikonTests",
            dependencies: [
                "OpenCineNikon",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
            ]
        ),
    ]
)
