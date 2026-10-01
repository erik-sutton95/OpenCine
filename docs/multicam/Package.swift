// swift-tools-version: 6.0
import PackageDescription

// Manufacturer-independent multicam engine. Imports Foundation and OpenCineCore only: never UI,
// a manufacturer integration or an app (see README.md).
// Temporary: OpenCineCore is a sibling path until it is published (url + exact version then).
let package = Package(
    name: "OpenCineMulticam",
    platforms: [.iOS(.v17), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "OpenCineMulticam", targets: ["OpenCineMulticam"]),
    ],
    dependencies: [
        .package(path: "../OpenCineCore"),
    ],
    targets: [
        .target(
            name: "OpenCineMulticam",
            dependencies: [.product(name: "OpenCineCore", package: "OpenCineCore")]
        ),
        .testTarget(
            name: "OpenCineMulticamTests",
            dependencies: [
                "OpenCineMulticam",
                .product(name: "OpenCineCore", package: "OpenCineCore"),
                .product(name: "OpenCineCoreTestSupport", package: "OpenCineCore"),
            ]
        ),
    ]
)
