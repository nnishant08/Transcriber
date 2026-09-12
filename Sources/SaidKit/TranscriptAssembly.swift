import Foundation

/// Turns a flat stream of timed words into the timestamped segments Said's whole document model is
/// built on. Pure — no models, no vendor types, no I/O — so `--selftest-parakeet` can assert the
/// mapping without downloading anything.
///
/// **Why this exists.** Whisper hands back segments; Parakeet hands back one string plus a flat
/// array of token timings for the entire buffer. Every `[mm:ss]` in a transcript, every click-to-seek
/// target, every chapter boundary and every subtitle cue is a *segment*, so the flat form has to be
/// cut somewhere. Doing that badly is very visible: cut too finely and the transcript becomes a
/// column of three-word lines; too coarsely and clicking a line drops you a minute from the words
/// you clicked.
///
/// The rules below are ordered by how a person reads a transcript, not by what is easy to compute:
/// a sentence ending is the best place to break, a long silence is the second best, and running past
/// `maxSeconds` is a failure of both that gets broken anyway so no line grows unbounded.
public enum TranscriptAssembly {

    /// Tuning for the cut. Defaults chosen to land near Whisper's own segment lengths, so a Parakeet
    /// transcript and a Whisper transcript of the same recording read alike and a re-transcription
    /// does not reshape the whole document.
    public struct Options: Sendable {
        /// Never end a segment shorter than this on punctuation alone — otherwise "Yes. No. Maybe."
        /// becomes three lines.
        public var minSeconds: TimeInterval = 2.0
        /// Always break once a segment reaches this, punctuation or not.
        public var maxSeconds: TimeInterval = 18.0
        /// A gap of silence at least this long is a natural break even mid-sentence.
        public var gapSeconds: TimeInterval = 0.7
        /// Sentence-final punctuation that earns a break.
        public var terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

        public init() {}
    }

    /// Group `words` into segments. Returns `[]` for empty input.
    ///
    /// Word timings are carried through onto each segment, so a Parakeet session gets `words`
    /// populated for free and `validWords` has something to validate. The segment's own bounds are
    /// taken from its first and last word, which is what keeps `validWords`' bounds check satisfied
    /// by construction rather than by luck.
    public static func segments(words: [WordTiming], options: Options = Options()) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { current = []; return }
            out.append(TranscriptSegment(start: first.start,
                                         end: max(last.end, first.start),
                                         text: TranscriptText.clean(text),
                                         words: current))
            current = []
        }

        for (i, w) in words.enumerated() {
            // A silence gap belongs BEFORE this word, so it breaks the previous segment rather than
            // stranding the gap inside the new one.
            if let prev = current.last, w.start - prev.end >= options.gapSeconds {
                flush()
            }
            current.append(w)

            guard let start = current.first?.start else { continue }
            let span = w.end - start
            let endsSentence = w.text.trimmingCharacters(in: .whitespaces).last.map {
                options.terminators.contains($0)
            } ?? false
            let isLast = (i == words.count - 1)

            if isLast || span >= options.maxSeconds || (endsSentence && span >= options.minSeconds) {
                flush()
            }
        }
        flush()   // whatever a trailing gap-break left behind
        return out
    }

    /// The degraded path: an engine produced text but no usable timings.
    ///
    /// One segment spanning the whole buffer is deliberately blunt. The alternative — inventing
    /// boundaries by splitting the text on punctuation and distributing time evenly across them —
    /// produces `[mm:ss]` anchors that look precise and are wrong, and Said's anchors are clickable,
    /// so a wrong one sends the user to the wrong moment in the audio. An honestly coarse transcript
    /// beats a plausibly wrong one.
    public static func singleSegment(text: String, duration: TimeInterval) -> [TranscriptSegment] {
        let cleaned = TranscriptText.clean(text)
        guard !cleaned.isEmpty else { return [] }
        return [TranscriptSegment(start: 0, end: max(0, duration), text: cleaned)]
    }

    // MARK: - SentencePiece token → word

    /// SentencePiece word-boundary marker (▁, U+2581) — the same constant FluidAudio's own token
    /// filter uses. A token carrying it starts a new word; tokens without it continue the previous.
    public static let wordBoundaryMarker: Character = "\u{2581}"

    /// Fold sub-word tokens into whole words.
    ///
    /// Deliberately takes plain values rather than a vendor token type, so it is testable with
    /// hand-written input and unaffected if FluidAudio reshapes `TokenTiming`.
    ///
    /// A word's confidence is the **minimum** across its tokens, not the mean: the editor uses it to
    /// mark words worth a second look, and a word is exactly as trustworthy as its least certain
    /// piece. Averaging hides a bad token behind three good ones.
    public static func words(fromTokens tokens: [(text: String, start: TimeInterval,
                                                  end: TimeInterval, confidence: Float)]) -> [WordTiming] {
        var out: [WordTiming] = []
        var buf = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var conf: Float = 1

        func flush() {
            let t = buf.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { buf = ""; return }
            out.append(WordTiming(text: t, start: start, end: max(end, start), confidence: conf))
            buf = ""
        }

        for tok in tokens {
            let piece = tok.text
            let startsWord = piece.first == wordBoundaryMarker
            let cleaned = String(piece.filter { $0 != wordBoundaryMarker })
            if startsWord || buf.isEmpty {
                flush()
                start = tok.start
                conf = tok.confidence
            } else {
                conf = min(conf, tok.confidence)
            }
            buf += cleaned
            end = tok.end
        }
        flush()
        return out
    }
}
