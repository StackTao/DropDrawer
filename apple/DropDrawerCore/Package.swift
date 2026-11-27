// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropDrawerCore",
    // Strings are written in Chinese; Resources/Localizable.xcstrings adds English.
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "DropDrawerCore",
            targets: ["DropDrawerCore"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "DropDrawerP2P",
            path: "../Frameworks/DropDrawerP2P.xcframework"
        ),
        .target(
            name: "DropDrawerCore",
            dependencies: ["DropDrawerP2P"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(
            name: "DropDrawerCoreTests",
            dependencies: ["DropDrawerCore"]
        ),
    ]
)
