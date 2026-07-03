// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "EfbyRequestLabs",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "EfbyDomain", targets: ["EfbyDomain"]),
        .library(name: "EfbyApplication", targets: ["EfbyApplication"]),
        .library(name: "EfbyInfrastructure", targets: ["EfbyInfrastructure"]),
        .library(name: "EfbyPresentation", targets: ["EfbyPresentation"]),
        .executable(name: "EfbyRequestLabs", targets: ["EfbyRequestLabs"]),
        .executable(name: "FlowDebugRunner", targets: ["FlowDebugRunner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "EfbyDomain",
            path: "Sources/AppCore/Domain"
        ),
        .target(
            name: "EfbyApplication",
            dependencies: ["EfbyDomain"],
            path: "Sources/EfbyApplication"
        ),
        .target(
            name: "EfbyInfrastructure",
            dependencies: [
                "EfbyDomain",
                "EfbyApplication",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/AppCore/Application"
        ),
        .target(
            name: "EfbyPresentation",
            dependencies: [
                "EfbyDomain",
                "EfbyApplication",
                "EfbyInfrastructure",
            ],
            path: "Sources/EfbyPresentation"
        ),
        .executableTarget(
            name: "FlowDebugRunner",
            dependencies: ["EfbyInfrastructure"],
            path: "Sources/FlowDebugRunner"
        ),
        .executableTarget(
            name: "EfbyRequestLabs",
            dependencies: ["EfbyPresentation"],
            path: "Sources/EFBYPostman",
            resources: [
                .copy("Resources/BPMN"),
                .copy("Resources/CodeEditor"),
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["EfbyPresentation"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
