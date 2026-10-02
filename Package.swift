// swift-tools-version: 6.0
import PackageDescription

// OpenCine: the shared Swift packages of OpenPocketCine, OpenInstaCine and OpenZCine in one
// package. Product and module names are the ones the apps already import. There are no
// package dependencies, so an app that links one product resolves nothing else.
//
// Dependency rules (plan 3.4; the target edges below encode them, the per-area import tests and
// `atlas check` enforce them):
// - OpenCineCore imports Foundation only: never UI, an integration, Multicam or an app.
// - Integrations (OpenCineDJI, OpenCineNikon, Insta360*) never import UI or an app.
// - OpenCineMulticam imports OpenCineCore only: never an integration or UI.
// - UI (MonitorPresentation, MonitorUI) never imports an integration, Multicam or an app
//   (today it depends on nothing).
//
// Platforms: one list for the whole package. macOS is the host for `swift test` only; no macOS
// app ships (former packages: Core/Multicam/DJI/Insta360 macOS 13, UI 12, Nikon and the harness
// 14; everything builds at 13). iOS 17 and watchOS 10 are unchanged.
let package = Package(
    name: "OpenCine",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        // Core area (docs/core/README.md).
        .library(name: "OpenCineCore", targets: ["OpenCineCore"]),
        .library(name: "OpenCineMedia", targets: ["OpenCineMedia"]),
        .library(name: "OpenCineFrameIO", targets: ["OpenCineFrameIO"]),
        .library(name: "OpenCineMotion", targets: ["OpenCineMotion"]),
        .library(name: "OpenCineRelay", targets: ["OpenCineRelay"]),
        .library(name: "OpenCineApple", targets: ["OpenCineApple"]),
        // Fakes for consumers' test targets only; never link it into an app.
        .library(name: "OpenCineCoreTestSupport", targets: ["OpenCineCoreTestSupport"]),
        // UI area (docs/ui/README.md).
        .library(name: "MonitorPresentation", targets: ["MonitorPresentation"]),
        .library(name: "MonitorUI", targets: ["MonitorUI"]),
        // Multicam engine (docs/multicam/README.md).
        .library(name: "OpenCineMulticam", targets: ["OpenCineMulticam"]),
        // Integrations (docs/dji, docs/nikon, docs/insta360).
        .library(name: "OpenCineDJI", targets: ["OpenCineDJI"]),
        .library(name: "OpenCineNikon", targets: ["OpenCineNikon"]),
        // Nikon Android facade: the PTP/IP and USB session layer and the NikonNative JNI exports
        // an app's Swift Android library links.
        .library(name: "OpenCineNikonAndroid", targets: ["OpenCineNikonAndroid"]),
        // JNI plumbing (NDK <jni.h> plus copy helpers) for Swift Android libraries.
        .library(name: "OpenCineJNI", targets: ["OpenCineJNI"]),
        .library(name: "Insta360Protocol", targets: ["Insta360Protocol"]),
        .library(name: "Insta360Apple", targets: ["Insta360Apple"]),
        // A scripted Luna for consumers' test targets only; never link it into an app.
        .library(name: "Insta360AppleTestSupport", targets: ["Insta360AppleTestSupport"]),
    ],
    targets: [
        // MARK: Core
        // Portable common camera, monitoring and capability contracts. Foundation only.
        .target(name: "OpenCineCore"),
        .target(name: "OpenCineCoreTestSupport", dependencies: ["OpenCineCore"]),
        .testTarget(
            name: "OpenCineCoreTests",
            dependencies: ["OpenCineCore", "OpenCineCoreTestSupport"]
        ),
        // Portable media math and the encoded-unit seam; builds with the Swift Android SDK.
        // EncodedVideoUnit names its stream with Core's StreamID and StreamGeneration.
        .target(name: "OpenCineMedia", dependencies: ["OpenCineCore"]),
        .testTarget(name: "OpenCineMediaTests", dependencies: ["OpenCineMedia"]),
        // Optional Frame.io delivery. No Core values genuinely help it, so it depends on nothing.
        .target(name: "OpenCineFrameIO"),
        .testTarget(name: "OpenCineFrameIOTests", dependencies: ["OpenCineFrameIO"]),
        // Optional typed motion seam and trajectory math shared by gimbal integrations.
        .target(name: "OpenCineMotion", dependencies: ["OpenCineCore"]),
        .testTarget(name: "OpenCineMotionTests", dependencies: ["OpenCineMotion"]),
        // Optional second-screen relay wire, control lease and pacing policy. Foundation only.
        .target(name: "OpenCineRelay"),
        .testTarget(name: "OpenCineRelayTests", dependencies: ["OpenCineRelay"]),
        // Apple runtime: decoded-frame leases, VideoToolbox decoder, UVC capture source. Every
        // file sits behind `#if canImport(...)`; Core and Media never depend on it.
        .target(name: "OpenCineApple", dependencies: ["OpenCineCore", "OpenCineMedia"]),
        .testTarget(name: "OpenCineAppleTests", dependencies: ["OpenCineApple"]),

        // MARK: UI
        // Presentation policy and native SwiftUI monitor screens. MonitorUI is iOS-only source
        // (`#if os(iOS)`); on macOS it compiles empty so `swift test` runs the presentation tests.
        .target(name: "MonitorPresentation"),
        .target(
            name: "MonitorUI", dependencies: ["MonitorPresentation"],
            resources: [.process("Resources/Fonts"), .copy("Resources/Icons")]
        ),
        .testTarget(name: "MonitorPresentationTests", dependencies: ["MonitorPresentation"]),

        // MARK: Multicam
        // Manufacturer-independent multicam engine. Foundation and OpenCineCore only.
        .target(name: "OpenCineMulticam", dependencies: ["OpenCineCore"]),
        .testTarget(
            name: "OpenCineMulticamTests",
            dependencies: ["OpenCineMulticam", "OpenCineCore", "OpenCineCoreTestSupport"]
        ),

        // MARK: DJI
        // DUML, datalink, adverts, camera control/status, commands, feed watchdog, SoftAP,
        // media endpoints and DJICameraSessionAdapter (OpenCineCore.CameraSession over a
        // DJIControlPort the app implements). Builds with the Swift Android SDK.
        .target(name: "OpenCineDJI", dependencies: ["OpenCineCore", "OpenCineMedia"]),
        .testTarget(name: "OpenCineDJITests", dependencies: ["OpenCineDJI"], exclude: ["Fixtures"]),

        // MARK: Nikon
        // PTP/IP and PTP/USB wire, property codes, discovery/session policy and
        // NikonCameraSession (OpenCineCore.CameraSession over the app's NikonControlDriver).
        .target(name: "OpenCineNikon", dependencies: ["OpenCineCore"]),
        // OpenCineMulticam is a test-only dependency: the multi-body tests run real
        // `NikonCameraSession`s through the shared engine. The library itself stays Core-only.
        .testTarget(
            name: "OpenCineNikonTests",
            dependencies: ["OpenCineNikon", "OpenCineCore", "OpenCineMulticam"]),
        // Android session layer over OpenCineNikon (moved from OpenZCine's Android facade):
        // PTPIPClientSession, the USB PTP transaction transport, the owner-keyed session registry,
        // media browse and the JNI exports of the Kotlin class
        // com.opencapture.opencine.nikon.NikonNative (Android `:nikon`). Everything but the JNI
        // exports also builds and tests on Darwin against scripted fake cameras.
        .target(name: "OpenCineNikonAndroid", dependencies: ["OpenCineNikon", "OpenCineJNI"]),
        .testTarget(
            name: "OpenCineNikonAndroidTests",
            dependencies: ["OpenCineNikonAndroid", "OpenCineNikon"]),

        // MARK: JNI
        // NDK <jni.h> for Swift (empty on Darwin) and the shared copy helpers, re-exported.
        .target(name: "COpenCineJNI"),
        .target(name: "OpenCineJNI", dependencies: ["COpenCineJNI"]),

        // MARK: Insta360
        // Luna wire protocol (Foundation only) and the Apple I/O adapter with its KCP C code.
        .target(name: "Insta360Protocol"),
        .testTarget(name: "Insta360ProtocolTests", dependencies: ["Insta360Protocol"]),
        // ikcp (MIT, LICENSE) plus two thin C shims. Public API: include/.
        .target(name: "CKcp", exclude: ["LICENSE"]),
        .target(name: "Insta360Apple", dependencies: ["Insta360Protocol", "CKcp", "OpenCineCore"]),
        .target(name: "Insta360AppleTestSupport", dependencies: ["Insta360Apple", "Insta360Protocol"]),
        .testTarget(
            name: "Insta360AppleTests",
            dependencies: [
                "Insta360Apple", "Insta360AppleTestSupport", "Insta360Protocol", "OpenCineCore",
            ]
        ),

        // MARK: Harness (developer-only, SIMULATED; docs/harness/README.md)
        // Not products: nothing here ships. HarnessEngine is neutral code beside the multicam
        // engine (Core, Media and Multicam only); HarnessComposition is the composition root and
        // the only module that names a manufacturer.
        .target(
            name: "HarnessEngine",
            dependencies: ["OpenCineCore", "OpenCineMedia", "OpenCineMulticam"]
        ),
        .target(
            name: "HarnessComposition",
            dependencies: [
                "HarnessEngine", "OpenCineCore", "OpenCineMulticam", "OpenCineDJI", "OpenCineNikon",
                "Insta360Apple", "Insta360Protocol",
            ]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: [
                "HarnessEngine", "HarnessComposition", "OpenCineCore", "OpenCineCoreTestSupport",
                "OpenCineMedia", "OpenCineMulticam", "OpenCineDJI", "OpenCineNikon",
                "Insta360Apple", "Insta360Protocol", "Insta360AppleTestSupport",
            ]
        ),
    ]
)
