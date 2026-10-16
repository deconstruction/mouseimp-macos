// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseImpMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MouseImpMac",
            path: "Sources/MouseImpMac"
        )
    ]
)
