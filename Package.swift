// swift-tools-version: 6.2
// BOX_VERSION: 0.3.0

import PackageDescription

let package = Package(
    name: "Box",
    platforms: [
        .macOS(.v14),
        .tvOS(.v17),
        .iOS(.v17)
    ],
    products: [
        .executable(
            name: "box",
            targets: ["BoxCommandParser"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/sushichop/Puppy.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.2.0")
    ],
    targets: [
        .executableTarget(
            name: "BoxCommandParser",
            dependencies: [
                "BoxServer",
                "BoxClient",
                "BoxCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "swift/Sources/BoxCommandParser"
        ),
        .target(
            name: "BoxBuildInfoSupport",
            dependencies: [],
            path: "swift/Sources/BoxBuildInfoSupport",
            plugins: ["BoxBuildInfoPlugin"]
        ),
        .target(
            name: "BoxServer",
            dependencies: [
                "BoxCore",
                "BoxClient",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio")
            ],
            path: "swift/Sources/BoxServer"
        ),
        .target(
            name: "BoxClient",
            dependencies: [
                "BoxCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio")
            ],
            path: "swift/Sources/BoxClient"
        ),
        .target(
            name: "BoxCore",
            dependencies: [
                "BoxBuildInfoSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                "Puppy",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "swift/Sources/BoxCore"
        ),
        .testTarget(
            name: "BoxAppTests",
            dependencies: ["BoxCore", "BoxServer", "BoxClient"],
            path: "swift/Tests/BoxAppTests"
        ),
        .executableTarget(
            name: "BoxBuildInfoGenerator",
            path: "Plugins/BoxBuildInfoGenerator"
        ),
        .plugin(
            name: "BoxBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["BoxBuildInfoGenerator"]
        )
    ]
)
