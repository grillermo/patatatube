// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PatataTubeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PatataTubeKit", targets: ["PatataTubeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.20.0")),
    ],
    targets: [
        .target(
            name: "PatataTubeKit",
            dependencies: [.product(name: "FlyingFox", package: "FlyingFox")]
        ),
        .testTarget(name: "PatataTubeKitTests", dependencies: ["PatataTubeKit"]),
    ]
)
