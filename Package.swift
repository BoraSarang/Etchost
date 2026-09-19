// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Etchost",
    defaultLocalization: "ko",
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
                .process("Resources/ko.lproj"),
                .process("Resources/en.lproj"),
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
