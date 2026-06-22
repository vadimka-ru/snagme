// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "SnagMe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnagMe",
            path: "Sources/SnagMe"
        )
    ]
)
