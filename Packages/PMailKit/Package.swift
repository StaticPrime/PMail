// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMailKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PMailKit", targets: ["PMailKit"]),
    ],
    targets: [
        .target(name: "PMailKit"),
        .testTarget(name: "PMailKitTests", dependencies: ["PMailKit"]),
    ]
)
