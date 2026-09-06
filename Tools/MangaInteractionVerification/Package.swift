// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MangaInteractionVerification",
    platforms: [.macOS(.v14)],
    products: [],
    targets: [
        .target(name: "YamiboXUI", path: "Sources"),
        .testTarget(name: "MangaInteractionTests", dependencies: ["YamiboXUI"], path: "Tests")
    ]
)
