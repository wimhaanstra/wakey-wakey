// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wakey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wakey",
            path: "Sources/Wakey"
        )
    ]
)
