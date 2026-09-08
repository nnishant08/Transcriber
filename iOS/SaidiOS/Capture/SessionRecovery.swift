import Foundation
import SaidKit

/// Finishes recordings that were interrupted by the app being killed.
///
/// This is the other half of `StreamingAudioWriter`: the writer makes sure the audio is on disk,
/// and this makes sure it becomes a real session the next time the app opens. Without it, a killed
/// recording leaves an orphaned `recording.pcm` that nothing ever looks at — the audio survives but
/// the user never sees it again, which is indistinguishable from losing it.
///
/// Runs at launch, off the main thread, before the library lists.
enum SessionRecovery {

    struct Recovered: Sendable {
        let dir: URL
        let seconds: Double
        let startedAt: Date
    }

    /// Finalise every unfinished session found under the store root.
    ///
    /// Deliberately does NOT transcribe here: the raw audio becomes `audio.m4a` and a session with
    /// real metadata immediately, and transcription follows through the normal path. Getting the
    /// session into the library fast matters more than getting it complete slowly — a user who
    /// force-quit wants to see their recording is safe.
    static func recoverAll() async -> [Recovered] {
        var out: [Recovered] = []
        for dir in RecoveryScanner.unfinishedSessions() {
            if let r = await recover(dir: dir) { out.append(r) }
        }
        return out
    }

    static func recover(dir: URL) async -> Recovered? {
        guard let state = RecoveryState.read(from: dir) else { return nil }
        let raw = dir.appendingPathComponent(StreamingAudioWriter.rawFilename)

        // Salvage the audio first. A torn trailing sample is expected and handled.
        let samples = StreamingAudioWriter.readRaw(at: raw) ?? []
        guard samples.count > 1_600 else {
            // Nothing worth keeping — a recording killed within a fraction of a second. Clean up
            // rather than leaving a husk in the library.
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        let seconds = Double(samples.count) / 16_000
        let audioName = StreamingAudioWriter.convertRaw(at: raw)?.lastPathComponent

        // Transcribe what we salvaged, so the recovered session is a real one rather than an
        // audio file with no words. Best-effort: a failure still yields a playable session.
        var segments: [TranscriptSegment] = []
        let engine = TranscriptionEngine()
        if (try? await engine.prepare(model: state.modelName, progress: { _, _ in })) != nil {
            engine.sink.append(samples)
            segments = (try? await engine.finalPassSegments(language: state.language)) ?? []
        }

        var meta = SessionMeta(id: state.sessionID,
                               date: state.startedAt,
                               sourceLabel: state.sourceLabel,
                               modelName: state.modelName,
                               audioFile: audioName,
                               durationSeconds: seconds,
                               language: (state.language != nil && state.language != "en") ? state.language : nil)
        // Say plainly that this was recovered, rather than presenting it as an ordinary session.
        meta.title = "Recovered recording — \(Self.dayName(state.startedAt))"

        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)
        RecoveryState.clear(in: dir)

        SearchIndex.shared.index(sessionDir: dir)
        SessionStore.postSessionSaved(dir)
        NSLog("[Recovery] salvaged \(String(format: "%.1f", seconds))s from \(dir.lastPathComponent)")

        return Recovered(dir: dir, seconds: seconds, startedAt: state.startedAt)
    }

    /// "Tuesday" for something recent, else a date — the phrasing the user actually thinks in.
    static func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) { return "today" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = "d MMMM"
        }
        return f.string(from: date)
    }
}
