// swift-tools-version: 6.0
import PackageDescription

// Insta360 Luna integration: wire protocol (Insta360Protocol, Foundation only), the Apple I/O
// adapter (Insta360Apple: CoreBluetooth, camera Wi-Fi, TCP 6666, screen KCP) and its KCP C code.
// Never imports UI or an app; the app supplies its names through LunaIntegrationConfiguration.
// Temporary: OpenCineCore is a sibling path until it is published (url + exact version then).
let package = Package(
    name: "OpenCineInsta360",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "Insta360Protocol", targets: ["Insta360Protocol"]),
        .library(name: "Insta360Apple", targets: ["Insta360Apple"]),
        // A scripted Luna for consumers' test targets only; never link it into an app.
        .library(name: "Insta360AppleTestSupport", targets: ["Insta360AppleTestSupport"]),
    ],
    dependencies: [
        .package(path: "../OpenCineCore"),
    ],
    targets: [
        .target(name: "Insta360Protocol"),
        .testTarget(name: "Insta360ProtocolTests", dependencies: ["Insta360Protocol"]),
        // ikcp (MIT, LICENSE) plus two thin C shims. Public API: include/.
        .target(name: "CKcp", exclude: ["LICENSE"]),
        .target(
            name: "Insta360Apple",
            dependencies: [
                "Insta360Protocol", "CKcp",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
            ]
        ),
        .target(name: "Insta360AppleTestSupport", dependencies: ["Insta360Apple", "Insta360Protocol"]),
        .testTarget(
            name: "Insta360AppleTests",
            dependencies: [
                "Insta360Apple", "Insta360AppleTestSupport", "Insta360Protocol",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
            ]
        ),
    ]
)
