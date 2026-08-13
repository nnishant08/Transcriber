// swift-tools-version: 5.10
// Said — on-device live speech-to-text.
//
// TWO targets, deliberately:
//   • SaidKit — the cross-platform core (macOS + iOS). Everything portable lives here: the session
//     store & document model, transcription, diarization, on-device intelligence, export, privacy.
//     It must NEVER acquire an AppKit / ScreenCaptureKit / KeyboardShortcuts dependency; the
//     `Scripts/verify_ios_build.sh` gate is what enforces that between now and the iOS app.
//   • Said — the macOS executable: windows, menu bar, hotkeys, screen + system-audio capture, and
//     the headless `--selftest-*` suite (which tests SaidKit through its public API on purpose).
//
// Pinned EXACT versions (APIs drift across releases — read the pinned tag's README/source before bumping):
//   WhisperKit 1.0.0 ships from the consolidated package "argmax-oss-swift" (product name still "WhisperKit").
//     Declares macOS 14 / iOS 17 → satisfied by both floors below.
//   KeyboardShortcuts 2.4.0 — macOS-only, so it is a dependency of the `Said` target ONLY.
//   FluidAudio 0.15.2 (git tag v0.15.2) — on-device speaker diarization (CoreML, zero transitive deps).
//     VERIFIED at the tag: its manifest already declares `.macOS(.v14)` AND `.iOS(.v17)`, so the
//     existing pin satisfies the iOS floor as-is. NO bump was needed and none was made.
import PackageDescription

let package = Package(
    name: "Said",
    platforms: [
        // macOS 14 (Sonoma) — FluidAudio's floor, unchanged from before the split.
        // iOS 18 — deliberate: every dependency is satisfied well below it, and nothing in the
        // product serves a device that can't reach it. On-device AI stays gated at 26 on both.
        .macOS(.v14),
        // The STRING form, not `.v18`: the `.v18` enum case is only available to
        // swift-tools-version 6.0+, and bumping the tools version would switch the package into
        // Swift 6 language mode (strict concurrency) — a behaviour change this refactor must not
        // make. `.iOS("18.0")` declares exactly the same floor under tools 5.10.
        .iOS("18.0"),
    ],
    products: [
        // Declared explicitly so SPM generates a `SaidKit` SCHEME — that is what
        // `Scripts/verify_ios_build.sh` builds against to prove the core stays iOS-clean.
        // Phase 2's iOS app depends on this same product.
        .library(name: "SaidKit", targets: ["SaidKit"]),
        .executable(name: "Said", targets: ["Said"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
    ],
    targets: [
        .target(
            name: "SaidKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SaidKit",
            // Stage 2 (Feature B): vertical packs ship as bundled JSON. SPM emits a resource bundle
            // (SaidKit_SaidKit.bundle) resolved via Bundle.module — works for the raw self-test
            // binary AND the assembled .app (build_app.sh copies *.bundle into Resources/).
            resources: [.copy("Packs")]
        ),
        .executableTarget(
            name: "Said",
            dependencies: [
                "SaidKit",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Said"
        ),
    ]
)
