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
            dependencies: [.product(name: "FlyingFox", package: "FlyingFox")],
            // DevLog's instrumentation (DevLog.swift) is compiled out unless
            // DEVLOG is defined. Debug builds get it automatically so a plain
            // Xcode Run in the Simulator is always instrumented.
            //
            // An Xcode *project*-level SWIFT_ACTIVE_COMPILATION_CONDITIONS does
            // NOT reach SwiftPM package targets — verified — so the debug case
            // has to be declared here. Instrumented Release builds are a
            // different path: `./deploy --instrumented` passes the condition on
            // the xcodebuild command line, which does reach every target.
            swiftSettings: [.define("DEVLOG", .when(configuration: .debug))]
        ),
        // Must carry the same DEVLOG condition as the library, otherwise the
        // tests' `#if DEVLOG` disagrees with the `DevLog.enabled` compiled into
        // the library they link against.
        //
        //   swift test              -> debug,   DEVLOG on  (instrumented path)
        //   swift test -c release   -> release, DEVLOG off (silence guarantee)
        //
        // Both are meaningful; run both when touching DevLog.
        .testTarget(
            name: "PatataTubeKitTests",
            dependencies: ["PatataTubeKit"],
            swiftSettings: [.define("DEVLOG", .when(configuration: .debug))]
        ),
    ]
)
