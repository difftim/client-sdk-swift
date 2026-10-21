// swift-tools-version:5.9
// Builds LiveKit.xcframework for the TempTalk fork. Run with `xcrun swift`, not swiftly's toolchain.

import PackageDescription

let package = Package(
    name: "tt-xcframework",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/tuist/XcodeProj.git", .upToNextMinor(from: "8.8.0")),
        .package(url: "https://github.com/kylef/PathKit.git", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "XCFrameworkKit",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
                .product(name: "PathKit", package: "PathKit"),
            ]
        ),
        .executableTarget(
            name: "tt-xcframework",
            dependencies: [
                "XCFrameworkKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "tt-xcframeworkTests",
            dependencies: ["XCFrameworkKit"]
        ),
    ]
)
