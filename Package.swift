// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioClipKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AudioClipKit", targets: ["AudioClipKit"]),
    ],
    targets: [
        .target(name: "AudioClipKit"),
        .testTarget(name: "AudioClipKitTests", dependencies: ["AudioClipKit"]),
    ]
)
