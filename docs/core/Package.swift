// swift-tools-version: 6.0
import PackageDescription

// Portable common camera, monitoring and capability contracts. Foundation only.
// Core never imports UI, manufacturer integrations or Multicam (see README.md).
// OpenCineMedia holds portable media math (LUTs, transfer curves, scope and false-colour
// math, shutter angle, frame timing, framing) and the encoded-unit seam (H.26x NAL math,
// present policy, EncodedVideoUnit). Foundation plus OpenCineCore; it also builds with the
// Swift Android SDK because Android JNI facades link it. LiveFrameTap is Apple-only
// (`#if canImport(CoreVideo)`).
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
        // EncodedVideoUnit names its stream with Core's StreamID and StreamGeneration.
        .target(name: "OpenCineMedia", dependencies: ["OpenCineCore"]),
        .testTarget(name: "OpenCineMediaTests", dependencies: ["OpenCineMedia"]),
    ]
)
