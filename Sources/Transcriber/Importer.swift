import Foundation

/// Imports an audio or video file into a full session folder — the same `transcript.md` +
/// `session.json` layout a recorded session produces, via `DocumentBuilder`. Audio is decoded to
/// 16 kHz mono and transcribed with the full-quality pass (+ custom-vocab bias). A VIDEO file
/// becomes the session's video (`meta.videoFile`), played in the Viewer against the transcript
/// exactly like a screen recording — same seek, same timeline.
enum Importer {

    /// Parameters captured from AppModel so the importer is self-contained (no MainActor hops mid-work).
    struct Config: Sendable {
        var model: String
        var language: String?              // explicit ISO code, or nil when auto-detecting
        var autoDetectLanguage: Bool = false   // "Auto" setting: detect once on a lead-in, then pin
        var vocabulary: [String]
        var diarize: Bool = false          // Stage-1 post-passes (same as a recorded session)
        var cleanup: Bool = false
    }

    /// A video this large is left where it is rather than copied into the session folder (the
    /// transcript + audio still import fine; only in-app playback of the video is skipped). Copying
    /// a 20 GB screen capture onto the Desktop without asking would be a nasty surprise.
    static let maxCopiedVideoBytes: Int64 = 8 * 1_073_741_824   // 8 GB

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
        let dir = uniqueSessionFolder(date: date, root: root)

        // Playback source: copy the original for audio imports (full fidelity, AVAudioPlayer-compatible);
        // write a compact audio.m4a from the decoded buffer for video imports (avoids a huge copy).
        progress("Saving audio…")
        let audioName = saveAudio(url: url, isVideo: isVideo, samples: samples, dir: dir)

        // A video import keeps its video: copied into the session folder so the folder stays
        // self-contained, and recorded as `videoFile` so the Viewer plays it against the transcript.
        var videoName: String?
        if isVideo {
            progress("Saving video…")
            videoName = saveVideo(url: url, dir: dir)
        }

        let label = isVideo ? "Imported video — \(url.lastPathComponent)" : "Imported — \(url.lastPathComponent)"
        let meta = SessionMeta(date: date, sourceLabel: label, modelName: config.model,
                               targetLabel: nil, modeLabel: isVideo ? "Imported video" : nil,
                               audioFile: audioName, durationSeconds: duration, imported: true,
                               language: (language != nil && language != "en") ? language : nil,
                               videoFile: videoName)
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)

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

    /// Copy an imported video into the session folder as `source.<ext>`. Returns nil (and logs) when
    /// the file is too large to copy or the copy fails — the session is still a complete transcript.
    private static func saveVideo(url: URL, dir: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard size <= maxCopiedVideoBytes else {
            NSLog("[Import] video is \(size / 1_048_576) MB — left in place, session is audio + transcript only")
            return nil
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("source.\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { return dest.lastPathComponent }
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.lastPathComponent
        } catch {
            NSLog("[Import] video copy failed: \(error)")
            return nil
        }
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
    private static func uniqueSessionFolder(date: Date, root: URL) -> URL {
        let base = DocumentBuilder.folderStamp.string(from: date)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"; n += 1
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
