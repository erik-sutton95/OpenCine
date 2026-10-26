// swift-tools-version: 6.0
import PackageDescription

// OpenCine: the shared Swift packages of OpenPocketCine, OpenInstaCine and OpenZCine in one
// package. Product and module names are the ones the apps already import. There are no
// package dependencies, so an app that links one product resolves nothing else. The optional
// Sentry reporting adapter is its own package, Packages/OpenCineSentryApple, for that reason.
//
// Dependency rules (plan 3.4; the target edges below encode them, the per-area import tests and
// `atlas check` enforce them):
// - OpenCineCore imports Foundation only: never UI, an integration, Multicam or an app.
// - OpenCineCameraVocabulary imports Core, Media and Motion only: no UI, integration, app or wire
//   code.
// - Integrations (OpenCineDJI, OpenCineNikon, Insta360*) never import UI or an app.
// - OpenCineMulticam imports OpenCineCore only: never an integration or UI.
// - OpenCineGyro (phone gyro capture for Gyroflow) imports Foundation only and depends on
//   nothing; it names no app or manufacturer. OpenCineGyroApple (its iOS shell: CoreMotion
//   driver, UserDefaults store and capture coordinator) depends on OpenCineGyro and Apple
//   frameworks only. OpenCineGyroAndroid (its JNI facade) depends on OpenCineGyro and
//   OpenCineJNISupport only.
// - UI (MonitorPresentation, MonitorUI) never imports an integration, Multicam or an app.
//   Native views consume portable Media values; presentation policy stays Foundation-only.
// - OpenCineAppKit (the app shell) builds on Core, Multicam and UI; never an integration or an
//   app.
// - OpenCineAppKitApple (the Apple composition layer of the app shell) builds on OpenCineAppKit,
//   MonitorUI, MonitorPresentation, OpenCineApple, OpenCineMedia, OpenCineMotion, OpenCineRelay and
//   OpenCineRelayApple only: never an integration, an app or a third-party package.
// - OpenCineFrameIOApple (Frame.io's Apple host: keychain token, Info.plist configuration, web
//   sign-in, saved destination, upload history and the delivery services every app composes)
//   builds on OpenCineFrameIO, OpenCineAppKit and OpenCineAppKitApple only. Keychain service,
//   defaults keys and bundle arrive from the app.
// - OpenCineCameraControls (the camera apps' controls over the camera vocabulary: face AF,
//   capture sheets, live chrome, gimbal views) builds on OpenCineCameraVocabulary, MonitorUI,
//   MonitorPresentation, OpenCineAppKit, OpenCineAppKitApple, Core, Media and Motion only: never
//   OpenCineDJI or another integration, an app or a third-party package.
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
        .library(name: "OpenCineGyro", targets: ["OpenCineGyro"]),
        .library(name: "OpenCineGyroApple", targets: ["OpenCineGyroApple"]),
        .library(name: "OpenCineMotion", targets: ["OpenCineMotion"]),
        .library(name: "OpenCineRelay", targets: ["OpenCineRelay"]),
        .library(name: "OpenCineRelayApple", targets: ["OpenCineRelayApple"]),
        .library(name: "OpenCineWatch", targets: ["OpenCineWatch"]),
        .library(name: "OpenCineApple", targets: ["OpenCineApple"]),
        // Fakes for consumers' test targets only; never link it into an app.
        .library(name: "OpenCineCoreTestSupport", targets: ["OpenCineCoreTestSupport"]),
        // UI area (docs/ui/README.md).
        .library(name: "MonitorPresentation", targets: ["MonitorPresentation"]),
        .library(name: "MonitorUI", targets: ["MonitorUI"]),
        // Multicam engine (docs/multicam/README.md).
        .library(name: "OpenCineMulticam", targets: ["OpenCineMulticam"]),
        // Shared app shell: saved cameras, the connection model and screens (docs/appkit/README.md).
        .library(name: "OpenCineAppKit", targets: ["OpenCineAppKit"]),
        .library(name: "OpenCineAppKitApple", targets: ["OpenCineAppKitApple"]),
        .library(name: "OpenCineFrameIOApple", targets: ["OpenCineFrameIOApple"]),
        .library(name: "OpenCineCameraControls", targets: ["OpenCineCameraControls"]),
        // The app UI tests every app shares (XCTest), for apps' UI test bundles only; never link
        // it into an app.
        .library(name: "OpenCineAppUITesting", targets: ["OpenCineAppUITesting"]),
        // The one hosted accessibility walk, for in-process test bundles; depends on nothing.
        .library(name: "OpenCineHostedAccessibility", targets: ["OpenCineHostedAccessibility"]),
        .library(name: "OpenCineHostedTestSupport", targets: ["OpenCineHostedTestSupport"]),
        // Integrations (docs/dji, docs/nikon, docs/insta360).
        .library(name: "OpenCineCameraVocabulary", targets: ["OpenCineCameraVocabulary"]),
        .library(name: "OpenCineDJI", targets: ["OpenCineDJI"]),
        .library(name: "OpenCineDJIApple", targets: ["OpenCineDJIApple"]),
        // The Swift side of the Android `DjiNative` JNI facade: an app links it into its Swift
        // Android library (the exports ship in that .so). Its wire helpers also build on Darwin.
        .library(name: "OpenCineDJIAndroid", targets: ["OpenCineDJIAndroid"]),
        .library(name: "OpenCineNikon", targets: ["OpenCineNikon"]),
        // Nikon Android facade: the PTP/IP and USB session layer and the NikonNative JNI exports
        // an app's Swift Android library links.
        .library(name: "OpenCineNikonAndroid", targets: ["OpenCineNikonAndroid"]),
        // JNI copy helpers (and the NDK <jni.h> shim OpenCineJNI, re-exported) for an app's own
        // Swift Android exports.
        .library(name: "OpenCineJNISupport", targets: ["OpenCineJNISupport"]),
        // The Swift side of the Android `FrameioNative` JNI facade (`:frameio`): an app links it
        // into its Swift Android library. Its wire helpers also build and test on Darwin.
        .library(name: "OpenCineFrameIOAndroid", targets: ["OpenCineFrameIOAndroid"]),
        // The Swift side of the Android `GyroNative` JNI facade (`:gyro`): an app links it into
        // its Swift Android library. Its wire helpers also build and test on Darwin.
        .library(name: "OpenCineGyroAndroid", targets: ["OpenCineGyroAndroid"]),
        .library(name: "Insta360Protocol", targets: ["Insta360Protocol"]),
        .library(name: "Insta360Apple", targets: ["Insta360Apple"]),
        // A scripted Luna for consumers' test targets only; never link it into an app.
        .library(name: "Insta360AppleTestSupport", targets: ["Insta360AppleTestSupport"]),
    ],
    targets: [
        // MARK: Core
        // Portable common camera, monitoring and capability contracts. Foundation only.
        .target(name: "OpenCineCore"),
        .target(name: "OpenCineCoreTestSupport", dependencies: ["OpenCineCore", "OpenCineGyro"]),
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
        // Phone gyro capture for Gyroflow: take segmentation, GCSV, mount calibration, drift,
        // stabilization save/restore and log storage. Foundation only; names no app or manufacturer.
        .target(name: "OpenCineGyro"),
        .testTarget(name: "OpenCineGyroTests", dependencies: ["OpenCineGyro"]),
        // Gyro capture's Apple shell: CoreMotion driver, UserDefaults store and the capture coordinator.
        // OpenCineGyro plus Apple frameworks only; every file sits behind `#if os(iOS)`.
        .target(name: "OpenCineGyroApple", dependencies: ["OpenCineGyro"]),
        .testTarget(name: "OpenCineGyroAppleTests", dependencies: ["OpenCineGyroApple", "OpenCineGyro", "OpenCineCoreTestSupport"]),
        // Optional typed motion seam and trajectory math shared by gimbal integrations.
        .target(name: "OpenCineMotion", dependencies: ["OpenCineCore"]),
        .testTarget(name: "OpenCineMotionTests", dependencies: ["OpenCineMotion"]),
        // Optional second-screen relay wire, control lease and pacing policy. Foundation and Core values.
        .target(name: "OpenCineRelay", dependencies: ["OpenCineCore"]),
        .testTarget(name: "OpenCineRelayTests", dependencies: ["OpenCineRelay"]),
        // The relay's Apple shell: Bonjour listener and browser, HEVC re-encode, socket reader.
        // Relay plus Apple frameworks only; every file sits behind `#if canImport(Network)`.
        // ponytail: Swift 5 mode, the mode both apps shipped this queue-confined code in (Swift 6
        // adds runtime isolation checks on its transport callbacks); move to 6 with a Sendable pass.
        .target(
            name: "OpenCineRelayApple", dependencies: ["OpenCineRelay"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // Swift 5 mode as in the apps' former relay harness: the load tests drive real sockets
        // and encoder callbacks that mutate captured test state.
        .testTarget(
            name: "OpenCineRelayAppleTests", dependencies: ["OpenCineRelayApple", "OpenCineRelay"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // The watch companion over the relay's watch protocol: the phone's WatchConnectivity relay
        // (iOS; its CoreImage contexts use OpenCineApple's monitor working space) and the wrist
        // monitor (watchOS). Every file sits behind `#if os(iOS)` or `#if os(watchOS)`.
        // ponytail: Swift 5 mode, the mode the iOS apps shipped the phone relay in; move to 6 with
        // a Sendable pass over its CoreImage contexts.
        .target(
            name: "OpenCineWatch",
            dependencies: [
                "OpenCineCore", "OpenCineRelay", .target(name: "OpenCineApple", condition: .when(platforms: [.iOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // iOS only (xcodebuild on a simulator); empty under macOS `swift test`.
        .testTarget(
            name: "OpenCineWatchTests", dependencies: ["OpenCineWatch"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // Apple runtime: decoded-frame leases, VideoToolbox decoder, UVC capture source. Every
        // file sits behind `#if canImport(...)`; Core and Media never depend on it.
        .target(name: "OpenCineApple", dependencies: ["OpenCineCore", "OpenCineMedia", "OpenCineAppleObjC"]),
        // The Objective-C calls Swift cannot make safely (a framework method that raises an
        // NSException is called inside @try). Foundation, Metal and VideoToolbox only; empty
        // where they do not exist. Internal to OpenCineApple: no product, nothing else imports it.
        .target(name: "OpenCineAppleObjC"),
        .testTarget(name: "OpenCineAppleTests", dependencies: ["OpenCineApple", "OpenCineAppleObjC", "OpenCineMedia"]),

        // MARK: UI
        // Presentation policy and native SwiftUI monitor screens. MonitorUI is iOS-only source
        // (`#if os(iOS)`); on macOS it compiles empty so `swift test` runs the presentation tests.
        .target(name: "MonitorPresentation", dependencies: ["OpenCineMedia"]),
        .target(
            name: "MonitorUI", dependencies: ["MonitorPresentation", "OpenCineMedia"],
            resources: [.process("Resources/Fonts"), .copy("Resources/Icons"), .copy("Resources/Legal")]
        ),
        .testTarget(name: "MonitorPresentationTests", dependencies: ["MonitorPresentation"]),
        // Native view tests: iOS only (xcodebuild on a simulator); empty under macOS `swift test`.
        .testTarget(
            name: "MonitorUITests",
            dependencies: ["MonitorUI", "MonitorPresentation", "OpenCineAppKitApple", "OpenCineCameraControls", "OpenCineCoreTestSupport", "OpenCineGyro", "OpenCineGyroApple", "OpenCineHostedAccessibility", "OpenCineHostedTestSupport"]),

        // MARK: Multicam
        // Manufacturer-independent multicam engine. Foundation and OpenCineCore only.
        .target(name: "OpenCineMulticam", dependencies: ["OpenCineCore"]),
        .testTarget(
            name: "OpenCineMulticamTests",
            dependencies: ["OpenCineMulticam", "OpenCineCore", "OpenCineCoreTestSupport"]
        ),

        // MARK: App shell
        // The shared app flow over the integration contract: the saved-camera store with its
        // legacy mirrors, the connection model, the cameras and pair screens, the root and monitor
        // lifetime (ShellModel, AppShell) and the common controls (MonitorControlModel). Never
        // imports an integration or an app; apps list their integrations.
        .target(name: "OpenCineAppKit", dependencies: ["OpenCineCore", "OpenCineMulticam", "MonitorPresentation", "MonitorUI", "OpenCineMedia"]),
        .testTarget(
            name: "OpenCineAppKitTests",
            dependencies: [
                "OpenCineAppKit", "OpenCineCore", "OpenCineCoreTestSupport", "OpenCineMulticam",
                "MonitorPresentation", "MonitorUI", "OpenCineMedia", "OpenCineHostedAccessibility",
                "OpenCineHostedTestSupport",
            ]),
        // The Apple side of the app shell both camera apps share (head tracking, the watcher's
        // Wi-Fi join code, the HDR display state). App differences arrive as host values and
        // protocols; iOS only, empty elsewhere.
        .target(name: "OpenCineAppKitApple", dependencies: ["OpenCineAppKit", "MonitorUI", "OpenCineApple", "OpenCineMedia", "OpenCineMotion", "OpenCineRelay", "OpenCineRelayApple"]),
        .testTarget(name: "OpenCineAppKitAppleTests", dependencies: ["OpenCineAppKitApple", "OpenCineAppKit", "OpenCineMotion", "OpenCineApple", "OpenCineMedia", "MonitorUI"]),
        .target(name: "OpenCineFrameIOApple", dependencies: ["OpenCineFrameIO", "OpenCineAppKit", "OpenCineAppKitApple"]),
        .testTarget(
            name: "OpenCineFrameIOAppleTests",
            dependencies: ["OpenCineFrameIOApple", "OpenCineFrameIO", "OpenCineAppKit", "OpenCineAppKitApple"]),
        // The camera apps' controls over the camera vocabulary (app composition next to the app
        // shell). App differences arrive as host values, never as brand branches.
        .target(
            name: "OpenCineCameraControls",
            dependencies: [
                "OpenCineCameraVocabulary", "MonitorUI", "MonitorPresentation", "OpenCineAppKit", "OpenCineAppKitApple",
                "OpenCineApple", "OpenCineMedia", "OpenCineMotion", "OpenCineGyro", "OpenCineGyroApple",
            ]),
        .testTarget(name: "OpenCineCameraControlsTests", dependencies: ["OpenCineCameraControls", "OpenCineHostedAccessibility"]),
        // XCUITest cases that drive an app only by accessibility identifiers and the typed review
        // launch (MonitorPresentation `ReviewLaunch`); iOS only, empty elsewhere
        // (docs/conformance/SCENARIOS.md).
        // ponytail: Swift 5 mode, the mode the apps' UI test bundles compile them in; move to 6
        // with a MainActor pass over XCTest's expectation waits.
        .target(
            name: "OpenCineAppUITesting", dependencies: ["MonitorPresentation", "OpenCineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OpenCineAppUITestingTests", dependencies: ["OpenCineAppUITesting"]),
        // Hosted test bundles link this beside their host app, so it depends on nothing here: no
        // second copy of a module the host already holds. iOS only, empty elsewhere.
        .target(name: "OpenCineHostedAccessibility"),
        .testTarget(name: "OpenCineHostedAccessibilityTests", dependencies: ["OpenCineHostedAccessibility"]),
        // The one wait hosted tests share for state UIKit, SwiftUI or AVFoundation produce; same
        // dependency-free shape as OpenCineHostedAccessibility. Test bundles only, never an app.
        .target(name: "OpenCineHostedTestSupport"),
        .testTarget(name: "OpenCineHostedTestSupportTests", dependencies: ["OpenCineHostedTestSupport"]),

        // MARK: Camera vocabulary
        // The camera control vocabulary the monitor shells speak (exposure, colour, focus, video
        // format, gimbal stick, zoom, camera status and model, tracking boxes and face policies,
        // feed watchdog, session recovery, media files and LUT selection), shared by the DJI
        // integration and the Insta360 shell. Wire-free: no protocol frames or byte parsers.
        .target(name: "OpenCineCameraVocabulary", dependencies: ["OpenCineCore", "OpenCineMedia", "OpenCineMotion"]),
        .testTarget(
            name: "OpenCineCameraVocabularyTests",
            dependencies: ["OpenCineCameraVocabulary", "OpenCineCore", "OpenCineMedia", "OpenCineMotion"]),

        // MARK: DJI
        // DUML, datalink, adverts, camera control/status, commands, feed watchdog, SoftAP,
        // media endpoints and DJICameraSessionAdapter (OpenCineCore.CameraSession over a
        // DJIControlPort the app implements), plus what each body declares to OpenCineMotion.
        // Builds with the Swift Android SDK.
        .target(name: "OpenCineDJI", dependencies: ["OpenCineCore", "OpenCineMedia", "OpenCineMotion", "OpenCineCameraVocabulary"]),
        .testTarget(
            name: "OpenCineDJITests", dependencies: ["OpenCineDJI", "OpenCineMotion", "OpenCineCoreTestSupport", "OpenCineMedia"],
            exclude: ["Fixtures"]),
        // iOS Bluetooth/network adapters over portable DJI policy; no UI or app dependency.
        .target(name: "OpenCineDJIApple", dependencies: ["OpenCineCore", "OpenCineDJI", "OpenCineMedia", "OpenCineMotion"]),
        .testTarget(name: "OpenCineDJIAppleTests", dependencies: ["OpenCineDJIApple", "OpenCineDJI", "OpenCineMedia", "OpenCineMotion"]),
        // Header-only shim for the NDK's <jni.h>; empty on Darwin.
        .target(name: "OpenCineJNI"),
        .target(name: "OpenCineDJIAndroid", dependencies: ["OpenCineCore", "OpenCineDJI", "OpenCineJNISupport"]),
        .testTarget(name: "OpenCineDJIAndroidTests", dependencies: ["OpenCineCore", "OpenCineDJIAndroid", "OpenCineDJI"]),

        // MARK: Nikon
        // PTP/IP and PTP/USB wire, property codes, discovery/session policy and
        // NikonCameraSession (OpenCineCore.CameraSession over the app's NikonControlDriver).
        .target(name: "OpenCineNikon", dependencies: ["OpenCineCore", "OpenCineMedia", "OpenCineCameraVocabulary", "OpenCineGyro"]),
        // OpenCineMulticam is a test-only dependency: the multi-body tests run real
        // `NikonCameraSession`s through the shared engine. The library itself stays Core-only.
        .testTarget(
            name: "OpenCineNikonTests",
            dependencies: [
                "OpenCineNikon", "OpenCineCore", "OpenCineMedia", "OpenCineMulticam", "OpenCineCoreTestSupport",
                "OpenCineCameraVocabulary", "OpenCineGyro",
            ]),
        // Android session layer over OpenCineNikon (moved from OpenZCine's Android facade):
        // PTPIPClientSession, the USB PTP transaction transport, the owner-keyed session registry,
        // media browse and the JNI exports of the Kotlin class
        // com.opencapture.opencine.nikon.NikonNative (Android `:nikon`). Everything but the JNI
        // exports also builds and tests on Darwin against scripted fake cameras.
        .target(name: "OpenCineNikonAndroid", dependencies: ["OpenCineNikon", "OpenCineMedia", "OpenCineCameraVocabulary", "OpenCineJNISupport"]),
        .testTarget(
            name: "OpenCineNikonAndroidTests",
            dependencies: ["OpenCineNikonAndroid", "OpenCineNikon"]),

        // MARK: JNI
        // JNI copy helpers over the header-only OpenCineJNI shim (re-exported). Empty on Darwin.
        .target(name: "OpenCineJNISupport", dependencies: ["OpenCineJNI"]),
        // Frame.io OAuth and V4 request wire for every app's Android shell (moved from
        // OpenZCine's Android facade) and the JNI exports of the Kotlin class
        // com.opencapture.opencine.frameio.FrameioNative. PKCE SHA-256 is the Android platform
        // digest, injected through the JNI object; no cryptography package dependency.
        .target(name: "OpenCineFrameIOAndroid", dependencies: ["OpenCineFrameIO", "OpenCineJNISupport"]),
        .testTarget(name: "OpenCineFrameIOAndroidTests", dependencies: ["OpenCineFrameIOAndroid", "OpenCineFrameIO"]),
        // Gyro logging, ring calibration, drift and arming wire for every app's Android shell and
        // the JNI exports of the Kotlin class com.opencapture.opencine.gyro.GyroNative. Everything
        // but the JNI exports also builds and tests on Darwin.
        .target(name: "OpenCineGyroAndroid", dependencies: ["OpenCineGyro", "OpenCineJNISupport"]),
        .testTarget(name: "OpenCineGyroAndroidTests", dependencies: ["OpenCineGyroAndroid", "OpenCineGyro"]),

        // MARK: Insta360
        // Luna wire protocol (Foundation and portable Media) and the Apple I/O adapter with its KCP C code.
        // OpenCineMedia: the Luna preview clip calibration over the portable scope ceiling.
        .target(name: "Insta360Protocol", dependencies: ["OpenCineMedia"]),
        .testTarget(name: "Insta360ProtocolTests", dependencies: ["Insta360Protocol", "OpenCineMedia"]),
        // ikcp (MIT, LICENSE) plus two thin C shims. Public API: include/.
        .target(name: "CKcp", exclude: ["LICENSE"]),
        .target(
            name: "Insta360Apple",
            dependencies: [
                "Insta360Protocol", "CKcp", "OpenCineCore", "OpenCineMotion", "OpenCineMedia",
                "OpenCineCameraVocabulary",
            ]
        ),
        .target(name: "Insta360AppleTestSupport", dependencies: ["Insta360Apple", "Insta360Protocol", "OpenCineCore", "OpenCineMedia"]),
        .testTarget(
            name: "Insta360AppleTests",
            dependencies: [
                "Insta360Apple", "Insta360AppleTestSupport", "Insta360Protocol", "OpenCineCore",
                "OpenCineMotion", "OpenCineMedia", "OpenCineCameraVocabulary",
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
