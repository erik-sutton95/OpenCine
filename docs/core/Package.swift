// swift-tools-version: 6.0
import PackageDescription

// Portable common camera, monitoring and capability contracts. Foundation only.
// Core never imports UI, manufacturer integrations or Multicam (see README.md).
// OpenCineMedia holds portable media math (LUTs, transfer curves, scope and false-colour
// math, shutter angle, frame timing, framing) and the encoded-unit seam (H.26x NAL math,
// present policy, EncodedVideoUnit). Foundation plus OpenCineCore; it also builds with the
// Swift Android SDK because Android JNI facades link it. LiveFrameTap is Apple-only
// (`#if canImport(CoreVideo)`).
// OpenCineFrameIO is an optional delivery product: Frame.io request planning, OAuth PKCE
// primitives and the upload workflow. Foundation only (CryptoKit on Apple platforms, a system
// framework); no package dependency, so no Core consumer resolves anything for it.
// OpenCineRelay is optional: the second-screen relay wire (framing, messages, version check,
// frame blob), the control lease and relay pacing policy. Foundation only; sockets, Bonjour,
// encoders and keychain stay in the apps.
let package = Package(
    name: "OpenCineCore",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineCore", targets: ["OpenCineCore"]),
        .library(name: "OpenCineMedia", targets: ["OpenCineMedia"]),
        .library(name: "OpenCineFrameIO", targets: ["OpenCineFrameIO"]),
        .library(name: "OpenCineRelay", targets: ["OpenCineRelay"]),
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
        // No Core values genuinely help Frame.io delivery, so it depends on nothing.
        .target(name: "OpenCineFrameIO"),
        .testTarget(name: "OpenCineFrameIOTests", dependencies: ["OpenCineFrameIO"]),
        .target(name: "OpenCineRelay"),
        .testTarget(name: "OpenCineRelayTests", dependencies: ["OpenCineRelay"]),
    ]
)
