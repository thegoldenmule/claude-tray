// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeTray",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeTray", path: "Sources/ClaudeTray")
    ]
)
