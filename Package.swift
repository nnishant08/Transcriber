// swift-tools-version: 5.10
// Transcriber — on-device live speech-to-text menu-bar app.
// Pinned EXACT versions (APIs drift across releases — read the pinned tag's README/source before bumping):
//   WhisperKit 1.0.0 ships from the consolidated package "argmax-oss-swift" (product name still "WhisperKit").
//   KeyboardShortcuts 2.4.0.
//   FluidAudio 0.15.2 (git tag v0.15.2) — on-device speaker diarization (CoreML, zero transitive deps).
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [
        // Sonoma — FluidAudio's platform floor is macOS 14 (was .v13; the app is built & run on
        // macOS 26, so the bump is functionally harmless). ScreenCaptureKit/MenuBarExtra needs were 13+.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Transcriber",
            // Stage 2 (Feature B): vertical packs ship as bundled JSON. SPM emits a resource bundle
            // (Transcriber_Transcriber.bundle) resolved via Bundle.module — works for the raw
            // self-test binary AND the assembled .app (build_app.sh copies *.bundle into Resources/).
            resources: [.copy("Packs")]
        )
    ]
)
