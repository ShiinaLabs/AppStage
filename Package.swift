// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppStage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppStage", targets: ["AppStage"]),
        .library(name: "AppStageMac", targets: ["AppStageMac"]),
        .library(name: "AppStageCapture", targets: ["AppStageCapture"]),
        .library(name: "AppStageControl", targets: ["AppStageControl"]),
        .executable(name: "appstage", targets: ["AppStageCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.1.1"),
        .package(url: "https://github.com/lnquy/axe.git", exact: "0.1.0"),
    ],
    targets: [
        .target(
            name: "AppStage",
            dependencies: [.product(name: "Clocks", package: "swift-clocks")]
        ),
        .target(name: "AppStageMac", dependencies: ["AppStage"]),
        .target(name: "AppStageCapture"),
        .target(name: "AppStageControl", dependencies: ["AppStage"]),
        .executableTarget(
            name: "AppStageCLI",
            dependencies: [
                "AppStage",
                "AppStageMac",
                "AppStageCapture",
                "AppStageControl",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axe", package: "axe"),
            ]
        ),
        .testTarget(
            name: "AppStageTests",
            dependencies: [
                "AppStage",
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        .testTarget(
            name: "AppStageCaptureTests",
            dependencies: ["AppStageCapture"]
        ),
        .testTarget(name: "AppStageControlTests", dependencies: ["AppStageControl"]),
        .testTarget(
            name: "AppStageMacTests",
            dependencies: ["AppStageMac"]
        ),
        .testTarget(
            name: "AppStageCLITests",
            dependencies: ["AppStageCLI"]
        ),
    ]
)
