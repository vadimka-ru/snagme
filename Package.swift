// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "SnagMe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnagMe",
            path: "Sources/SnagMe",
            resources: [
                .process("Resources/MenuIcon.svg"),
                .process("Resources/Loader.svg"),
                .process("Resources/Check.svg"),
                .process("Resources/AddFolder.svg"),
                .process("Resources/Folder.svg"),
                .process("Resources/ApproveFolder.svg"),
            ]
        )
    ]
)
