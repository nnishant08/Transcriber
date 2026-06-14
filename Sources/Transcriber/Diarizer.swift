import Foundation
import FluidAudio

/// On-device speaker diarization via FluidAudio 0.15.2 (Pyannote Community-1 segmentation +
/// WeSpeaker embeddings, CoreML on the ANE). The models download ONCE — anonymously, from
/// FluidAudio's own HuggingFace repo (`FluidInference/speaker-diarization-coreml`), no token, no
/// account (verified at the pinned tag: a Bearer header is only attached when an HF_TOKEN env var
/// exists) — then everything runs fully offline, preserving the "everything stays on this Mac" story.
///
/// NOTE: FluidAudio also ships a higher-accuracy `OfflineDiarizerManager` (full pyannote-parity
/// VBx pipeline); `DiarizerManager.performCompleteDiarization` is the simpler documented batch
/// path and is sufficient here — the offline manager is a future accuracy upgrade.
actor DiarizerService {
    static let shared = DiarizerService()

    private var manager: DiarizerManager?

    /// Download (first run only, with progress) + load the diarizer models. Idempotent — the
    /// manager is built once and cached. `progress` mirrors the `(message, fraction?)` shape the
    /// WhisperKit model downloader already uses.
    func prepare(progress: (@Sendable (String, Double?) -> Void)? = nil) async throws {
        if manager != nil { return }
        let models = try await DiarizerModels.downloadIfNeeded(progressHandler: { p in
            progress?("Downloading speaker model…", p.fractionCompleted)
        })
        // Default DiarizerConfig: clusteringThreshold 0.7 — FluidAudio's documented sweet spot
        // (~17.7% DER on AMI). Deliberately not surfaced as a primary UI control.
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
        progress?("Speaker model ready.", 1)
    }

    /// Diarize a 16 kHz mono Float32 buffer (exactly what `SampleSink` holds) into normalized
    /// speaker turns. `prepare()` must have succeeded first. Synchronous CoreML work — callers run
    /// this off the main thread (it executes on the actor, never on main).
    func diarize(samples: [Float]) throws -> [SpeakerTurn] {
        guard let manager else { throw CaptureError.engineNotReady }
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        return SpeakerAlignment.normalize(result.segments.map {
            (id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        })
    }

    // FUTURE (capability #2, deliberately out of scope for Stage 1): cross-session voiceprint
    // identity would attach HERE — FluidAudio's `SpeakerManager` / `extractSpeakerEmbedding` can
    // enroll a named speaker's embedding and match new sessions against a local voiceprint store,
    // so "Speaker 1" auto-resolves to "Alice" across sessions. No voiceprint store is built now.
}

/// The post-save diarization pass (Feature A). Runs OFF the save path — the session is already
/// safely on disk before this is called; on any failure it logs and leaves the session exactly as
/// saved (no labels). Mirrors how title backfill enriches `session.json` after the fact.
enum DiarizationPass {

    /// Label `dir`'s segments with speakers computed from `samples` (the same 16 kHz buffer the
    /// final pass transcribed, so both share the T0 timeline). Re-renders `transcript.md` with
    /// label prefixes — the verbatim text and every `[mm:ss]` anchor are unchanged — and stores
    /// `speaker` per segment + `speakerCount` in `session.json`.
    static func run(dir: URL, samples: [Float]) async {
        guard samples.count > 16_000 else { return }   // < 1 s of audio — nothing to label
        do {
            try await DiarizerService.shared.prepare(progress: { msg, frac in
                NSLog("[Diarize] \(msg) \(frac.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
            })
            let turns = try await DiarizerService.shared.diarize(samples: samples)
            guard !turns.isEmpty,
                  var doc = DocumentBuilder.readSession(dir),
                  !doc.segments.isEmpty else { return }
            doc.segments = SpeakerAlignment.assign(segments: doc.segments, turns: turns)
            doc.meta.speakerCount = Set(doc.segments.compactMap { $0.speaker }).count
            DocumentBuilder.writeSession(doc, to: dir)   // re-render md with labels + session.json
            SearchIndex.shared.index(sessionDir: dir)    // labels become searchable
            SessionStore.postSessionSaved(dir)
            NSLog("[Diarize] \(doc.meta.speakerCount ?? 0) speaker(s) labeled for \(dir.lastPathComponent)")
        } catch {
            // Offline first run / model failure / mid-pass throw: the verbatim session is already
            // saved; we degrade to "no labels" and retry naturally on the next session.
            NSLog("[Diarize] skipped (\(error)) — session kept without speaker labels")
        }
    }
}
