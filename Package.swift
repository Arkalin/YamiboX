// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YamiboX",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "YamiboXCore", targets: ["YamiboXCore"]),
        .library(name: "YamiboXUI", targets: ["YamiboXUI"]),
        .library(name: "YamiboXTestSupport", targets: ["YamiboXTestSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", exact: "6.1.0"),
        .package(url: "https://github.com/kean/Nuke", exact: "13.0.6")
    ],
    targets: [
        .target(
            name: "YamiboXCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Kanna",
                .product(name: "Nuke", package: "Nuke"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "YamiboXUI",
            dependencies: [
                "YamiboXCore",
                .product(name: "NukeUI", package: "Nuke"),
            ]
        ),
        .target(
            name: "YamiboXTestSupport",
            dependencies: [
                "YamiboXCore",
            ]
        ),
        .testTarget(
            name: "YamiboXCoreTests",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "YamiboXCore",
                "YamiboXTestSupport",
            ]
        ),
        .testTarget(
            name: "YamiboXUITests",
            dependencies: [
                "YamiboXCore",
                "YamiboXUI",
                "YamiboXTestSupport",
            ]
        )
    ]
)
