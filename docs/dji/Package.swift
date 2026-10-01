// swift-tools-version: 6.0
import PackageDescription

// DJI integration for OpenCine apps: DUML framing and transport, datalink handshake and
// depacketizer, BLE adverts, camera model/control/status decode, command builders, setting
// mailbox, feed watchdog, SoftAP/station join/multicam discovery, media endpoints, AE/AWB,
// tracking, gimbal wire, DJI colour data, and DJICameraSessionAdapter (OpenCineCore's
// CameraSession over a DJIControlPort the app session implements). Foundation plus
// OpenCineCore and OpenCineMedia; no UI, no app types. Builds with the Swift Android SDK
// (the Pocket JNI facade links it).
let package = Package(
    name: "OpenCineDJI",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineDJI", targets: ["OpenCineDJI"])
    ],
    dependencies: [
        // Sibling checkout pinned in opencine-pins.txt until OpenCineCore is published.
        .package(path: "../OpenCineCore")
    ],
    targets: [
        .target(
            name: "OpenCineDJI",
            dependencies: [
                // DJICameraSessionAdapter implements OpenCineCore.CameraSession.
                .product(name: "OpenCineCore", package: "OpenCineCore"),
                .product(name: "OpenCineMedia", package: "OpenCineCore"),
            ]
        ),
        .testTarget(
            name: "OpenCineDJITests",
            dependencies: ["OpenCineDJI"],
            exclude: ["Fixtures"]
        ),
    ]
)
