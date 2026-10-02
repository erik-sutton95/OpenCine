// swift-tools-version: 6.0
import PackageDescription

// Developer-only harness proving cross-brand composition (plan work package MULTI-03). Not a
// product and not an app: nothing here ships, and every camera in it is SIMULATED.
//
// HarnessEngine: neutral code a future multi-brand app would need beside OpenCineMulticam (per
// source analysis settings, synchronization levels). Imports Core, Media and Multicam only.
// HarnessComposition: the composition root. The explicit list of integration factories (plan
// 1.3: no registry, no plugin loading) and the only module that names a manufacturer.
//
// Every package is a sibling path checkout pinned in opencine-pins.txt, so SwiftPM resolves one
// copy of OpenCineCore for all four consumers (one dependency closure).
let package = Package(
    name: "OpenCineHarness",
    // macOS 14: OpenCineNikon's floor.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarnessEngine", targets: ["HarnessEngine"]),
        .library(name: "HarnessComposition", targets: ["HarnessComposition"]),
    ],
    dependencies: [
        .package(path: "../OpenCineCore"),
        .package(path: "../OpenCineMulticam"),
        .package(path: "../OpenCineDJI"),
        .package(path: "../OpenCineNikon"),
        .package(path: "../OpenCineInsta360"),
    ],
    targets: [
        .target(
            name: "HarnessEngine",
            dependencies: [
                .product(name: "OpenCineCore", package: "OpenCineCore"),
                .product(name: "OpenCineMedia", package: "OpenCineCore"),
                .product(name: "OpenCineMulticam", package: "OpenCineMulticam"),
            ]
        ),
        .target(
            name: "HarnessComposition",
            dependencies: [
                "HarnessEngine",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
                .product(name: "OpenCineMulticam", package: "OpenCineMulticam"),
                .product(name: "OpenCineDJI", package: "OpenCineDJI"),
                .product(name: "OpenCineNikon", package: "OpenCineNikon"),
                .product(name: "Insta360Apple", package: "OpenCineInsta360"),
                .product(name: "Insta360Protocol", package: "OpenCineInsta360"),
            ]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: [
                "HarnessEngine", "HarnessComposition",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
                .product(name: "OpenCineCoreTestSupport", package: "OpenCineCore"),
                .product(name: "OpenCineMedia", package: "OpenCineCore"),
                .product(name: "OpenCineMulticam", package: "OpenCineMulticam"),
                .product(name: "OpenCineDJI", package: "OpenCineDJI"),
                .product(name: "OpenCineNikon", package: "OpenCineNikon"),
                .product(name: "Insta360Apple", package: "OpenCineInsta360"),
                .product(name: "Insta360Protocol", package: "OpenCineInsta360"),
                .product(name: "Insta360AppleTestSupport", package: "OpenCineInsta360"),
            ]
        ),
    ]
)
