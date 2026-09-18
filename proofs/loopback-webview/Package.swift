// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "LoopbackProof",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "loopback-proof",
            dependencies: ["LoopbackProofCore"]
        ),
        .target(
            name: "LoopbackProofCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
    ]
)
