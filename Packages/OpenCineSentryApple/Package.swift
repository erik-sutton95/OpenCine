// swift-tools-version: 6.0
import PackageDescription

// OpenCine's optional reporting adapter for Apple apps: OpenCineAppKit's reporting sink on the
// Sentry SDK (Android twin: `Android/appkit-sentry`). It is its own package so its one third-party
// dependency stays out of the OpenCine package graph: a package or app that depends on OpenCine
// resolves and downloads no SDK unless it adds this package too. Only this package names
// sentry-cocoa; no OpenCine module imports it (`AppKitRules`).
let package = Package(
    name: "OpenCineSentryApple",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineSentryApple", targets: ["OpenCineSentryApple"])
    ],
    dependencies: [
        .package(path: "../.."),
        // The version the apps shipped.
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.24.0"),
    ],
    targets: [
        // iOS source; empty elsewhere.
        .target(
            name: "OpenCineSentryApple",
            dependencies: [
                .product(name: "OpenCineAppKit", package: "OpenCine"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]),
        // Starts the SDK, so it runs on an iOS simulator with xcodebuild.
        .testTarget(
            name: "OpenCineSentryAppleTests",
            dependencies: [
                "OpenCineSentryApple",
                .product(name: "OpenCineAppKit", package: "OpenCine"),
                .product(name: "OpenCineMedia", package: "OpenCine"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]),
    ]
)
