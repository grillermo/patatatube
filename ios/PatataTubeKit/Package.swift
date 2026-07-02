// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PatataTubeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PatataTubeKit", targets: ["PatataTubeKit"]),
    ],
    targets: [
        .target(name: "PatataTubeKit"),
        .testTarget(name: "PatataTubeKitTests", dependencies: ["PatataTubeKit"]),
    ]
)
