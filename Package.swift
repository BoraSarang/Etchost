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
            exclude: [
                "Resources/Info.plist",
            ],
            resources: [
                .process("Resources/ko.lproj"),
                .process("Resources/en.lproj"),
            ]
        ),
        .testTarget(
            name: "EtchostKitTests",
            dependencies: ["EtchostKit"],
            path: "Tests/EtchostKitTests",
            exclude: [
                "Resources/Info.plist",
            ]
        ),
    ]
)
