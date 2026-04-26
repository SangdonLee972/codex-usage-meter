// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "codex-usage-meter", targets: ["CodexUsageMeter"])
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageMeter",
            path: "Sources/CodexUsageMeter",
            resources: [.process("Resources")]
        )
    ]
)
