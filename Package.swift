// swift-tools-version: 6.1
import PackageDescription

// VoiceFlow's Mac app. One executable target whose sources are the existing
// `swift/` folder, so no file moves and no module boundary appears inside the
// app (06 §3.1). The fixtures the contract copy script brings in live in
// `contract-fixtures/`, outside this target, so no number of contract sets can
// turn a data file into an unhandled resource of the build.
//
// Swift 5 language mode: the 89 files of `swift/` were written against it, and
// Swift 6's strict concurrency checking is a separate piece of work with its
// own risk. The tools version is 6.1 because GRDB 7 requires it.
//
// macOS 14 because hummingbird-websocket 2.7.0 declares that floor; the app's
// `Info.plist` says the same.
let package = Package(
    name: "voice-flow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "voice-flow", targets: ["VoiceFlowApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceFlowApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "swift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
