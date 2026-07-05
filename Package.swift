// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Parla",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ParlaCore"),
        .executableTarget(name: "Parla", dependencies: ["ParlaCore"]),
        .testTarget(name: "ParlaCoreTests", dependencies: ["ParlaCore"]),
    ]
)
