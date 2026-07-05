// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Parla",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Pinned by revision to the 1.7.2 tag commit. 1.7.2 is the newest tag whose SPM
        // manifest builds whisper.cpp from source (with Metal). 1.7.3/1.7.4 switched to a
        // `systemLibrary` needing a brew-installed whisper; 1.7.5+ removed Package.swift
        // entirely (xcframework). A revision pin (not a version) is required because the
        // source target uses `.unsafeFlags`, which SPM forbids in versioned dependencies.
        .package(url: "https://github.com/ggml-org/whisper.cpp.git",
                 revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d"), // tag v1.7.2
    ],
    targets: [
        .target(name: "ParlaCore",
                dependencies: [.product(name: "whisper", package: "whisper.cpp")]),
        .executableTarget(name: "Parla", dependencies: ["ParlaCore"]),
        .executableTarget(name: "parla-eval", dependencies: ["ParlaCore"]),
        .testTarget(name: "ParlaCoreTests", dependencies: ["ParlaCore"]),
    ]
)
