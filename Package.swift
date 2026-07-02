// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoundSplitter",
    platforms: [
        // Core Audio Process Taps require macOS 14.2+. We target 15 to keep
        // things modern and avoid per-call availability annotations.
        .macOS("15.0")
    ],
    products: [
        .executable(name: "SoundSplitter", targets: ["SoundSplitter"])
    ],
    targets: [
        .executableTarget(
            name: "SoundSplitter",
            path: "Sources/SoundSplitter"
        )
    ]
)
