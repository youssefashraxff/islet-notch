// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchMusic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchMusic",
            path: "Sources/NotchMusic"
        )
    ]
)
