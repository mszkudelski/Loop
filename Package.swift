// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Loop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Loop", targets: ["Loop"])
    ],
    targets: [
        .executableTarget(
            name: "Loop",
            path: "Sources/Loop"
        ),
        .testTarget(
            name: "LoopTests",
            dependencies: ["Loop"],
            path: "Tests/LoopTests"
        )
    ]
)
