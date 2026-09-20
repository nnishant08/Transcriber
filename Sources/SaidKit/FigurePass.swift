import Foundation

// MARK: - The extraction pass
//
// Off the save path (prime directive #7): runs after a session is durable, like diarization, and
// saving never waits on it. It reads the session, detects over the EDITED view (a corrected word
// is what the user meant, and a re-extraction after an edit has to find the corrected figure),
// reuses every label the model already gave an identical candidate, labels the rest, and writes
// the sidecar. `transcript.md` is never opened for writing.

public enum FigurePass {

    public enum Mode: Sendable {
        /// Detect and label.
        case full
        /// Detect only — the iPhone at thermal `.serious` (§9), or a build with no model.
        case detectOnly
    }

    public struct Result: Sendable {
        public let figures: [Figure]
        public let labelCalls: Int
        public let labelled: Bool
    }

    /// Run only when the feature is on. The one entry point the post-save chains call.
    @discardableResult
    public static func runIfEnabled(dir: URL, mode: Mode = .full,
                                    backend: FigureLabelBackend = OnDeviceFigureLabelBackend()) async -> Result? {
        guard FigureStore.isEnabled else { return nil }
        return await run(dir: dir, mode: mode, backend: backend)
    }

    /// Extract (or re-extract) `dir`'s figures and write `figures.json`. Returns nil when the
    /// session cannot be read. Never throws; a failed write is logged and the previous sidecar (if
    /// any) is left in place.
    @discardableResult
    public static func run(dir: URL, mode: Mode = .full,
                           backend: FigureLabelBackend = OnDeviceFigureLabelBackend()) async -> Result? {
        guard let doc = DocumentBuilder.readSession(dir) else { return nil }
        let displayed = EditStore.editedSegments(dir: dir, segments: doc.segments)
        var candidates = FigureDetector.detect(segments: displayed)

        // Reuse labels from the previous sidecar for candidates that are the same figure in the same
        // turn. A re-extraction after an edit is therefore cheap: only what changed is labelled.
        let previous = FigureStore.read(dir: dir, doc: doc).sidecar
        if let previous {
            var cache: [String: (String?, Double?)] = [:]
            for f in previous.figures where f.label != nil { cache[f.candidateKey] = (f.label, f.confidence) }
            for i in candidates.indices {
                if let hit = cache[candidates[i].candidateKey] {
                    candidates[i].label = hit.0
                    candidates[i].confidence = hit.1
                }
            }
        }

        var labelled = false
        var calls = 0
        if mode == .full, candidates.contains(where: { $0.label == nil }) {
            let outcome = await FigureLabeller.run(candidates, segments: displayed, backend: backend)
            candidates = outcome.figures
            calls = outcome.calls
            labelled = outcome.complete
        } else if mode == .full {
            labelled = previous?.labelled ?? candidates.isEmpty
        }

        let sidecar = FigureSidecar(transcriptFingerprint: FigureStore.fingerprint(segments: doc.segments, meta: doc.meta),
                                    engine: doc.meta.engine, engineModel: doc.meta.engineModel,
                                    extractedAt: Date(), labelled: labelled, labelCalls: calls,
                                    figures: candidates)
        do { try FigureStore.write(sidecar, dir: dir) }
        catch { NSLog("[Figures] could not write \(FigureStore.fileName) for \(dir.lastPathComponent): \(error)") }
        // Labels and raw strings are search terms now.
        SearchIndex.shared.index(sessionDir: dir)
        return Result(figures: candidates, labelCalls: calls, labelled: labelled)
    }

    /// Whether `dir` needs (re-)extraction: no sidecar, a stale one, or one whose figures no longer
    /// all anchor on the displayed text (an edit landed inside a figure — §P3 "mark the session for
    /// re-extraction").
    public static func needsExtraction(dir: URL, doc: SessionDoc? = nil) -> Bool {
        guard FigureStore.isEnabled, let doc = doc ?? DocumentBuilder.readSession(dir) else { return false }
        switch FigureStore.read(dir: dir, doc: doc) {
        case .absent, .stale: return true
        case .ready(let s):
            let displayed = EditStore.editedSegments(dir: dir, segments: doc.segments)
            return FigureOverlay.resolve(s.figures, in: displayed).dropped > 0
        }
    }
}
