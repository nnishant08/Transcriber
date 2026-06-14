import Foundation
import CoreGraphics

/// Imports an audio or video file into a full session folder — the same `transcript.md` + `session.json`
/// (+ `images/` for video) layout a recorded session produces, via `DocumentBuilder`. Audio is decoded
/// to 16 kHz mono and transcribed with the full-quality pass (+ custom-vocab bias); video additionally
/// samples frames on an interval and OCRs them, interleaving on the T0 timeline like a visual session.
enum Importer {

    /// Parameters captured from AppModel so the importer is self-contained (no MainActor hops mid-work).
    struct Config: Sendable {
        var model: String
        var language: String?              // explicit ISO code, or nil when auto-detecting
        var autoDetectLanguage: Bool = false   // "Auto" setting: detect once on a lead-in, then pin
        var vocabulary: [String]
        var visualIntervalSeconds: Double
        var ocrEnabled: Bool
        var diarize: Bool = false          // Stage-1 post-passes (same as a recorded session)
        var cleanup: Bool = false
    }

    static func isSupported(_ url: URL) -> Bool { AudioFileIO.isSupported(url) }

    /// Run the import. `progress` reports a human-readable stage. Returns the new session folder URL.
    /// `root` defaults to the Transcripts directory; self-tests override it to a temp dir.
    static func run(url: URL, config: Config, root: URL = AppModel.transcriptsDirectory,
                    progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let isVideo = AudioFileIO.isVideo(url)

        progress("Decoding \(url.lastPathComponent)…")
        let samples = try await AudioFileIO.decodeTo16kMono(url: url)
        guard !samples.isEmpty else { throw AudioIOError.emptyBuffer }
        let duration = Double(samples.count) / 16_000.0

        progress("Loading model…")
        let engine = TranscriptionEngine()
        try await engine.prepare(model: config.model) { msg, _ in progress(msg) }

        // "Auto" language: detect ONCE on a lead-in sample of the decoded file, then transcribe the
        // whole file with that fixed language (same detect-once-then-pin rule as live recording).
        var language = config.language
        if config.autoDetectLanguage {
            progress("Detecting language…")
            language = (try? await engine.detectLanguage(samples: Array(samples.prefix(30 * 16_000))))?.language ?? "en"
        }

        progress("Transcribing…")
        let promptTokens = engine.promptTokens(for: config.vocabulary)
        let segments = try await engine.transcribeSamples(samples, language: language, promptTokens: promptTokens)

        // Session folder (unique even for same-second batch imports).
        let date = fileDate(url) ?? Date()
        let dir = uniqueSessionFolder(date: date, withImages: isVideo, root: root)

        // Video → sample + OCR frames on the T0 timeline.
        var frames: [FrameEvent] = []
        if isVideo {
            progress("Extracting frames…")
            let extracted = (try? await AudioFileIO.extractFrames(url: url, intervalSeconds: config.visualIntervalSeconds)) ?? []
            frames = writeFrames(extracted, to: dir)
            if config.ocrEnabled, !frames.isEmpty {
                progress("Reading slide text…")
                frames = SlideOCR.annotate(frames, sessionDir: dir)
            }
        }

        // Playback source: copy the original for audio imports (full fidelity, AVAudioPlayer-compatible);
        // write a compact audio.m4a from the decoded buffer for video imports (avoids a huge copy).
        progress("Saving audio…")
        let audioName = saveAudio(url: url, isVideo: isVideo, samples: samples, dir: dir)

        let label = isVideo ? "Imported video — \(url.lastPathComponent)" : "Imported — \(url.lastPathComponent)"
        let meta = SessionMeta(date: date, sourceLabel: label, modelName: config.model,
                               targetLabel: nil, modeLabel: isVideo ? "Imported video" : nil,
                               audioFile: audioName, durationSeconds: duration, imported: true,
                               language: (language != nil && language != "en") ? language : nil)
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments, frames: frames), to: dir)

        // Index + auto-title/tags + notify, exactly like a recorded session.
        SearchIndex.shared.index(sessionDir: dir)
        SessionStore.postSessionSaved(dir)
        await SessionStore.ensureTitle(dir: dir)

        // Stage-1 post-passes on the decoded buffer, same as a recorded session (session already
        // saved above — these only enrich it, and degrade to a no-op on failure).
        if config.diarize { await DiarizationPass.run(dir: dir, samples: samples) }
        if config.cleanup { await CleanupPass.run(dir: dir) }
        return dir
    }

    // MARK: - Helpers

    private static func writeFrames(_ extracted: [(time: Double, image: CGImage)], to dir: URL) -> [FrameEvent] {
        var events: [FrameEvent] = []
        for (i, f) in extracted.enumerated() {
            guard let png = f.image.pngData() else { continue }
            let total = Int(max(0, f.time).rounded())
            let name = String(format: "%04d-%02d%02d.png", i + 1, total / 60, total % 60)
            let rel = "images/\(name)"
            do {
                try png.write(to: dir.appendingPathComponent(rel))
                events.append(FrameEvent(sessionTime: f.time, imagePath: rel, ocrText: nil))
            } catch { NSLog("[Import] frame write failed: \(error)") }
        }
        return events
    }

    private static func saveAudio(url: URL, isVideo: Bool, samples: [Float], dir: URL) -> String? {
        if !isVideo {
            let ext = url.pathExtension.lowercased()
            let dest = dir.appendingPathComponent("source.\(ext.isEmpty ? "m4a" : ext)")
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { return dest.lastPathComponent }
        }
        return (try? AudioFileIO.writeCompactAudio(samples, to: dir.appendingPathComponent("audio.m4a")))?.lastPathComponent
    }

    private static func fileDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A session folder that doesn't collide (batch imports in the same second get a suffix).
    private static func uniqueSessionFolder(date: Date, withImages: Bool, root: URL) -> URL {
        let base = DocumentBuilder.folderStamp.string(from: date)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"; n += 1
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let target = withImages ? dir.appendingPathComponent("images", isDirectory: true) : dir
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return dir
    }
}
