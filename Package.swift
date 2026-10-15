// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GrahamTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GrahamTracker",
            path: "Sources/GrahamTracker"
        )
    ]
)
