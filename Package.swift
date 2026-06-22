// swift-tools-version:6.0
// Tools-version 6.0 so the manifest links against the Command Line Tools'
// current PackageDescription initializer (CLT-only installs omit the older 5.x
// symbol). We use only universally-available Package parameters and keep the
// code clean under the Swift 6 language mode, so it builds on any 6.x toolchain.
import PackageDescription

let package = Package(
    name: "seiren-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seiren-mac", targets: ["seiren-mac"]),
        .executable(name: "seiren-probe", targets: ["seiren-probe"]),
        .library(name: "SeirenKit", targets: ["SeirenKit"]),
    ],
    targets: [
        // Vendored RNNoise (xiph/rnnoise, BSD-3) — RT neural noise suppression
        // for the "Studio Denoise" mode. No build step: prebuilt C sources +
        // committed model weights (Sources/RNNoise/src/rnnoise_data.c). See
        // Sources/RNNoise/COPYING + NOTICE; model pinned in MODEL_VERSION.
        .target(
            name: "RNNoise",
            path: "Sources/RNNoise",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),

        // Real-time-safe audio DSP in C (biquad EQ, noise gate, RNNoise glue +
        // lock-free coefficient handoff). C, not Swift, so the audio thread
        // never touches the Swift runtime. See Sources/SeirenDSP/include/SeirenDSP.h.
        .target(name: "SeirenDSP", dependencies: ["RNNoise"]),

        // Model-independent core: HID transport, device registry, controller,
        // monitor engine, EQ. No AppKit — keeps it testable and reusable.
        .target(name: "SeirenKit", dependencies: ["SeirenDSP"]),

        // The macOS menu-bar agent.
        .executableTarget(
            name: "seiren-mac",
            dependencies: ["SeirenKit"],
            // Exclude the plist from the source compile; it is embedded via the
            // linker flag below, not compiled.
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the Mach-O __TEXT,__info_plist section so
                // the *running binary* carries NSMicrophoneUsageDescription even
                // when launched unbundled via `swift run`. Without a reachable
                // usage string the AVCaptureDevice microphone prompt won't show.
                // The path is resolved relative to the package root at link time.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/seiren-mac/Info.plist",
                ])
            ]
        ),

        // Read-only CoreAudio diagnostic: dumps every control the Seiren
        // exposes on macOS, to locate the sidetone (mic-monitor) element.
        .executableTarget(name: "seiren-probe"),

        .testTarget(
            name: "SeirenKitTests",
            dependencies: ["SeirenKit", "SeirenDSP", "RNNoise"]
        ),
    ]
)
