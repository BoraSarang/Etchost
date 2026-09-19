// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Etchost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EtchostKit", targets: ["EtchostKit"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "EtchostKit",
            dependencies: [],
            path: "Sources/EtchostKit",
            resources: [
                .copy("Resources/error_message_ko.json"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("InferSendableFromCaptures"),
            ]
        ),
        .testTarget(
            name: "EtchostKitTests",
            dependencies: ["EtchostKit"],
            path: "Tests/EtchostKitTests"
        ),
    ]
)
