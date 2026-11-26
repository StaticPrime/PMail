// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMailKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PMailKit", targets: ["PMailKit"]),
        // Keeping the app up to date: shared by the app and its update installer service.
        .library(name: "PuggleUpdate", targets: ["PuggleUpdate"]),
    ],
    targets: [
        .target(name: "PMailKit"),
        .target(name: "PuggleUpdate"),
        .testTarget(name: "PMailKitTests", dependencies: ["PMailKit"]),
        .testTarget(name: "PuggleUpdateTests", dependencies: ["PuggleUpdate"]),
    ]
)
