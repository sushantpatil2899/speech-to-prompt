// swift-tools-version:6.0
//
// SpeechToPrompt: local push-to-talk dictation for macOS.
//
// DictateCore is pure Swift (no Apple-only frameworks) so it also builds and
// tests on Linux. Everything else is macOS-only and is added below only when
// building on macOS.
//
// Before the first macOS build, run `scripts/setup.sh`. It builds
// Vendor/whisper.xcframework (whisper.cpp with Metal) from source.

import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SpeechToPrompt",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DictateCore", targets: ["DictateCore"]),
    ],
    targets: [
        .target(
            name: "DictateCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DictateCoreTests",
            dependencies: ["DictateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

#if os(macOS)
package.products += [
    .executable(name: "SpeechToPrompt", targets: ["SpeechToPrompt"]),
    .executable(name: "dictate-cli", targets: ["dictate-cli"]),
]
package.targets += [
    // Static whisper.cpp + ggml (Metal, embedded shader library), built by scripts/setup.sh.
    .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    .target(
        name: "DictateKit",
        dependencies: ["DictateCore", "whisper"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .linkedLibrary("c++"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("Foundation"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Speech"),
            .linkedFramework("ApplicationServices"),
        ]
    ),
    .executableTarget(
        name: "SpeechToPrompt",
        dependencies: ["DictateCore", "DictateKit"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "dictate-cli",
        dependencies: ["DictateCore", "DictateKit"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            // Embed an Info.plist so the CLI can use the microphone / Speech framework
            // (macOS checks the usage-description strings of the calling binary).
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "\(root)/Resources/dictate-cli-Info.plist",
            ]),
        ]
    ),
]
#endif
