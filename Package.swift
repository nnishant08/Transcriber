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
//   WhisperKit 1.1.0 ships from the consolidated package "argmax-oss-swift" (product name still "WhisperKit").
//     Declares macOS 14 / iOS 17 → satisfied by both floors below.
//     PHASE 3 BUMPED 1.0.0 → 1.1.0. Verified at both tags before bumping: `WhisperKit.download(
//     variant:progressCallback:)`, `WhisperKitConfig(model:modelFolder:load:download:)`,
//     `transcribe(audioArray:decodeOptions:)`, `transcribe(audioPath:decodeOptions:)`,
//     `detectLangauge(audioArray:)` [sic] and `WhisperKit.sampleRate` are all UNCHANGED. The one
//     breaking rename in 1.1.0 — `AudioInputConfig` → `AudioInputOptions`, with
//     `WhisperKitConfig.audioInputConfig` deprecated — touches a symbol Said never referenced.
//     What the bump buys: `AudioLoadingMode.incremental`, bounded-memory chunked file reading.
//     It is OPT-IN (`.fullFile` is still the default) and applies to the `audioPath:` overload
//     ONLY, so `TranscriptionEngine.transcribeFile` asks for it explicitly and the in-memory
//     `audioArray:` paths are unaffected.
//   KeyboardShortcuts 2.4.0 — macOS-only, so it is a dependency of the `Said` target ONLY.
//   FluidAudio 0.15.2 (git tag v0.15.2) — speaker diarization AND (Phase 3) Parakeet ASR.
//     VERIFIED at the tag: its manifest already declares `.macOS(.v14)` AND `.iOS(.v17)`, so the
//     existing pin satisfies the iOS floor as-is. NO bump was needed and none was made.
//     PHASE 3 RE-VERIFIED AND DELIBERATELY HELD AT 0.15.2. The README/podspec/CITATION.cff all
//     still claim 0.15.2 does not exist (they say 0.12.4); `git ls-remote --tags` says otherwise and
//     the tag list runs to v0.15.6. Everything Phase 3 needs is present at 0.15.2: `AsrManager`,
//     `AsrModels.downloadAndLoad(version:)`, `ASRResult.tokenTimings`, `SlidingWindowAsrManager`
//     (with its confirmed/volatile split) and `configureVocabularyBoosting`.
//     What is NOT present is `ModelHub` — it lands at v0.15.5, and by v0.15.6 `DownloadUtils` is
//     GONE, which breaks `AsrModels.download(progressHandler: DownloadUtils.ProgressHandler?)` and
//     the diarizer's download plumbing. Said therefore does not take `ModelHub.offlineMode`; it
//     enforces the offline promise itself in `ModelGate`, which is strictly broader anyway because
//     it also covers WhisperKit — which has no offline flag at any version.
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
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
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
