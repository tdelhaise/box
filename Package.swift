// swift-tools-version: 6.2
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
        .package(url: "git@github.com:apple/swift-foundation-xml.git", from: "0.2.0")
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
            name: "BoxServer",
            dependencies: [
                "BoxCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "FoundationXML", package: "swift-foundation-xml")
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                "Puppy"
            ],
            path: "swift/Sources/BoxCore"
        ),
        .testTarget(
            name: "BoxAppTests",
            dependencies: ["BoxCore", "BoxServer", "BoxClient"],
            path: "swift/Tests/BoxAppTests"
        )
    ]
)