// swift-tools-version: 6.0
import PackageDescription

// Portable common camera, monitoring and capability contracts. Foundation only.
// Core never imports UI, manufacturer integrations or Multicam (see README.md).
// OpenCineMedia holds portable media math (LUTs, transfer curves, scope and false-colour
// math, shutter angle, frame timing, framing). Foundation only; it also builds with the
// Swift Android SDK because Android JNI facades link it.
let package = Package(
    name: "OpenCineCore",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineCore", targets: ["OpenCineCore"]),
        .library(name: "OpenCineMedia", targets: ["OpenCineMedia"]),
        // Fakes for consumers' test targets only; never link it into an app.
        .library(name: "OpenCineCoreTestSupport", targets: ["OpenCineCoreTestSupport"]),
    ],
    targets: [
        .target(name: "OpenCineCore"),
        .target(name: "OpenCineCoreTestSupport", dependencies: ["OpenCineCore"]),
        .testTarget(
            name: "OpenCineCoreTests",
            dependencies: ["OpenCineCore", "OpenCineCoreTestSupport"]
        ),
        // ponytail: no OpenCineCore dependency until a media API needs a Core type.
        .target(name: "OpenCineMedia"),
        .testTarget(name: "OpenCineMediaTests", dependencies: ["OpenCineMedia"]),
    ]
)
