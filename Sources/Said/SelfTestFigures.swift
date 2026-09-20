import Foundation
import CryptoKit
import SaidKit

// The figures wave's headless self-tests (§10). No models, no audio hardware, no permissions,
// temp dirs only — the detector, the anchoring rules, the sidecar contract and the off switch are
// all pure, so they can be asserted exactly. The labeller is driven through a stub backend; a test
// that needs Apple Intelligence hardware is a test that does not run in CI.

extension SelfTest {

    // MARK: - Helpers (fileprivate twins of SelfTestPhase3's, which are file-scoped there)

    fileprivate final class FigChecker {
        var ok = true
        func check(_ label: String, _ cond: Bool) {
            print("  \(cond ? "✓" : "✗") \(label)")
            ok = ok && cond
        }
        func finish(restore: () -> Void) -> Never {
            restore()
            print(ok ? "OK" : "FAIL")
            exit(ok ? 0 : 2)
        }
    }

    fileprivate static func figTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("said-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `figuresEnabled` is the user's real setting; every mode restores it, and does so explicitly
    /// before `exit()` because `defer` does not run through `exit`.
    fileprivate struct FigFlags {
        let figures = FigureStore.isEnabled
        let encryption = SessionIO.isEncryptionEnabled
        let key = SessionIO.overrideKey
        func restore() {
            FigureStore.isEnabled = figures
            SessionIO.isEncryptionEnabled = encryption
            SessionIO.overrideKey = key
        }
    }

    /// Word timings laid out evenly across a segment, one per whitespace token, so a fixture
    /// segment gets a realistic word table without hand-timing every word.
    fileprivate static func timed(_ start: TimeInterval, _ text: String, speaker: Int? = nil,
                                  words: Bool = true) -> TranscriptSegment {
        let toks = text.split(separator: " ").map(String.init)
        let dur = Double(toks.count) * 0.42
        guard words else { return TranscriptSegment(start: start, end: start + dur, text: text, speaker: speaker) }
        let ws = toks.enumerated().map { i, w in
            WordTiming(text: w, start: start + Double(i) * 0.42, end: start + Double(i) * 0.42 + 0.35, confidence: 0.9)
        }
        return TranscriptSegment(start: start, end: start + dur, text: text, speaker: speaker, words: ws)
    }

    /// The committed fixture (§P1): every positive form, every "not figures" negative.
    fileprivate static func fixtureSegments() -> [TranscriptSegment] {
        var t = 0.0
        func seg(_ text: String, speaker: Int? = nil, words: Bool = true) -> TranscriptSegment {
            let s = timed(t, text, speaker: speaker, words: words); t = s.end + 0.6; return s
        }
        return [
            // Money, three forms of the same figure.
            seg("Revenue came in at $2.4 million for the quarter.", speaker: 1),
            seg("That is 2,400,000 dollars, if you want it written out.", speaker: 2),
            seg("So two point four million dollars, roughly what we forecast.", speaker: 1),
            seg("Our customer acquisition cost is about 240 dollars, or 240 quid for the UK team.", speaker: 2),
            seg("The Berlin office ran at €18,000 a month.", speaker: 1),
            // Percentages, digits and words.
            seg("Gross margin was up 18% year over year.", speaker: 2),
            seg("Churn dropped to eighteen percent in the second half.", speaker: 1),
            seg("The rate moved 18 basis points on the announcement.", speaker: 2),
            // Multipliers.
            seg("Pipeline is 3x what it was, ten times on the enterprise side.", speaker: 1),
            seg("Bookings doubled to 4 million in the same period.", speaker: 2),
            seg("The team basically doubled, which was the plan.", speaker: 1),   // NEGATIVE: no base
            // Counts with a unit.
            seg("Support spent 40 hours on the migration with 15 people on call.", speaker: 2),
            seg("Each install pulls 5 gigabytes on first launch.", speaker: 1),
            // Durations and deadlines.
            seg("Give it three weeks, and we ship by year end regardless.", speaker: 2),
            seg("The pricing change lands next sprint, the audit in Q3.", speaker: 1),
            seg("We need the signed contract by March 3rd.", speaker: 2),
            // The "not figures" list, one line each.
            seg("Speaker 2 said most of that, not me.", speaker: 1),
            seg("Call the vendor at 415-555-2671 if the number is wrong.", speaker: 2),
            seg("On March 3rd we met the auditors for the first time.", speaker: 1),
            seg("Go back to slide 5, the one after page 12.", speaker: 2),
            seg("The fifth option is the 5th one we tried.", speaker: 1),
            seg("We are on version 2.3.1, and version 3 is next.", speaker: 2),
            seg("The call is at 3:30 pm, the follow-up at 2pm tomorrow.", speaker: 1),
            seg("The mp3 files and the b2b deck are in the shared folder.", speaker: 2),
            seg("See Section 5 of the contract for the 2024 terms.", speaker: 1),
            seg("We have 3 options and I like the second one.", speaker: 2),
            // A legacy line with no word timings, so the character anchor path is exercised.
            seg("Legacy line: the deposit was 500 dollars and took two weeks.", words: false),
        ]
    }

    // MARK: - --selftest-figures-detect (§P1)

    static func runFiguresDetect() {
        setbuf(stdout, nil)
        print("== figures: detector self-test ==")
        let c = FigChecker()
        let flags = FigFlags()

        let segments = fixtureSegments()
        let figures = FigureDetector.detect(segments: segments)
        func raws(_ kind: FigureClass) -> [String] { figures.filter { $0.kind == kind }.map(\.raw) }
        func has(_ raw: String, _ kind: FigureClass? = nil) -> Bool {
            figures.contains { $0.raw == raw && (kind == nil || $0.kind == kind) }
        }
        func value(_ raw: String) -> Double? { figures.first { $0.raw == raw }?.value }
        print("  detected \(figures.count) figure(s):")
        for f in figures { print("     [\(f.timestamp)] \(f.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(f.raw)  value=\(f.value.map { String($0) } ?? "–") unit=\(f.unit ?? "–") words=\(f.wordStart.map { "\($0)..<\(f.wordEnd!)" } ?? "–")") }

        // ---- The three forms of one money figure detect identically.
        c.check("$2.4 million detects as money", has("$2.4 million", .money))
        c.check("2,400,000 dollars detects as money", has("2,400,000 dollars", .money))
        c.check("two point four million dollars detects as money", has("two point four million dollars", .money))
        c.check("all three forms parse to the same value",
                value("$2.4 million") == 2_400_000 && value("2,400,000 dollars") == 2_400_000
                && value("two point four million dollars") == 2_400_000)
        c.check("all three forms carry the same unit", figures.filter { $0.value == 2_400_000 }.allSatisfy { $0.unit == "USD" })
        c.check("240 dollars and 240 quid are both money", has("240 dollars", .money) && has("240 quid", .money))
        c.check("quid is GBP", figures.first { $0.raw == "240 quid" }?.unit == "GBP")
        c.check("€18,000 is money in EUR", has("€18,000", .money) && figures.first { $0.raw == "€18,000" }?.unit == "EUR" && value("€18,000") == 18_000)

        // ---- Percentages in digits and words.
        c.check("18% detects as a percentage", has("18%", .percentage) && value("18%") == 18)
        c.check("eighteen percent detects as a percentage", has("eighteen percent", .percentage) && value("eighteen percent") == 18)
        c.check("18 basis points detects with unit bps", has("18 basis points", .percentage) && figures.first { $0.raw == "18 basis points" }?.unit == "bps")

        // ---- Multipliers.
        c.check("3x detects as a multiplier", has("3x", .multiplier) && value("3x") == 3)
        c.check("ten times detects as a multiplier", has("ten times", .multiplier) && value("ten times") == 10)
        c.check("doubled with a base adjacent detects", figures.contains { $0.raw == "doubled" && $0.segmentIndex == 9 })
        c.check("doubled with NO base does not", !figures.contains { $0.raw == "doubled" && $0.segmentIndex == 10 })
        c.check("4 million on its own is NOT a figure (no unit)", !has("4 million"))

        // ---- Counts with a unit.
        c.check("40 hours detects as a count", has("40 hours", .count))
        c.check("15 people detects as a count", has("15 people", .count))
        c.check("5 gigabytes detects with unit gigabyte", has("5 gigabytes", .count) && figures.first { $0.raw == "5 gigabytes" }?.unit == "gigabyte")

        // ---- Durations and deadlines.
        c.check("three weeks detects as a duration", has("three weeks", .duration) && value("three weeks") == 3)
        c.check("by year end detects as a deadline", has("by year end", .duration))
        c.check("next sprint detects as a deadline", has("next sprint", .duration))
        c.check("in Q3 detects as a deadline", has("in Q3", .duration))
        c.check("by March 3rd detects as a deadline (date behind a preposition)", has("by March 3rd", .duration))
        c.check("deadlines carry no value", figures.filter { $0.unit == "deadline" }.allSatisfy { $0.value == nil })

        // ---- Every "not figures" entry, as a negative.
        let neg = { (si: Int) in figures.filter { $0.segmentIndex == si } }
        c.check("speaker name: 'Speaker 2' is not a figure", neg(16).isEmpty)
        c.check("phone number is not a figure", neg(17).isEmpty)
        c.check("calendar date with no quantity sense ('on March 3rd') is not a figure", neg(18).isEmpty)
        c.check("slide and page numbers are not figures", neg(19).isEmpty)
        c.check("bare ordinals ('fifth', '5th') are not figures", neg(20).isEmpty)
        c.check("version numbers are not figures", neg(21).isEmpty)
        c.check("times of day are not figures", neg(22).isEmpty)
        c.check("digits inside a word (mp3, b2b) are not figures", neg(23).isEmpty)
        c.check("'Section 5' and a bare year are not figures", neg(24).isEmpty)
        c.check("a bare count with no unit ('3 options') is not a figure", neg(25).isEmpty)

        // ---- Anchors.
        let m = figures.first { $0.raw == "$2.4 million" }
        c.check("a figure has an exact character range", m.map { Array(segments[0].text)[$0.charStart..<$0.charEnd].map(String.init).joined() == "$2.4 million" } ?? false)
        c.check("a figure has an exact word-index range", m?.wordStart == 4 && m?.wordEnd == 6)
        c.check("a figure's time range comes from its words",
                m.map { $0.start == segments[0].validWords![4].start && $0.end == segments[0].validWords![5].end } ?? false)
        c.check("a figure belongs to exactly one speaker", figures.allSatisfy { $0.speaker == segments[$0.segmentIndex].speaker })
        let legacy = figures.filter { $0.segmentIndex == 26 }
        c.check("a legacy line detects on the character anchor alone",
                legacy.count == 2 && legacy.allSatisfy { !$0.hasWordAnchor } && legacy.map(\.raw) == ["500 dollars", "two weeks"])
        c.check("a legacy figure's time is the segment's", legacy.first?.start == segments[26].start)
        c.check("no figure spans a segment boundary", figures.allSatisfy { $0.charEnd <= segments[$0.segmentIndex].text.count })

        // ---- Determinism.
        c.check("same input, same output", FigureDetector.detect(segments: segments) == figures)

        // ---- Overlap resolution: longest, then class priority.
        let a = FigureDetector.RawCandidate(range: 0..<5, kind: .count, value: 1, unit: "x")
        let b = FigureDetector.RawCandidate(range: 0..<12, kind: .duration, value: 1, unit: "y")
        let d = FigureDetector.RawCandidate(range: 3..<8, kind: .money, value: 1, unit: "z")
        let e = FigureDetector.RawCandidate(range: 3..<8, kind: .percentage, value: 1, unit: "w")
        let r1 = FigureDetector.resolveOverlaps([a, b])
        c.check("overlap: the longest candidate wins", r1 == [b])
        let r2 = FigureDetector.resolveOverlaps([e, d])
        c.check("overlap: on an exact tie, money outranks percentage", r2 == [d])
        let r3 = FigureDetector.resolveOverlaps([a, FigureDetector.RawCandidate(range: 20..<25, kind: .money, value: 1, unit: "q")])
        c.check("non-overlapping candidates both survive", r3.count == 2)

        // ---- .spellOut traps, closed.
        c.check("'twenty four' composes to 24, not 2004", FigureDetector.composeSpelled(["twenty", "four"]) == 24)
        c.check("'a hundred' composes to 100", FigureDetector.composeSpelled(["one", "hundred"]) == 100)
        c.check("'two point four five million' composes", FigureDetector.composeSpelled(["two", "point", "four", "five", "million"]) == 2_450_000)

        // ---- Performance over a 90-minute fixture (§10).
        var long: [TranscriptSegment] = []
        var t = 0.0
        let base = fixtureSegments().map(\.text)
        var i = 0
        while t < 90 * 60 {
            let s = timed(t, base[i % base.count], speaker: 1 + i % 2)
            long.append(s); t = s.end + 0.5; i += 1
        }
        let words = long.reduce(0) { $0 + ($1.validWords?.count ?? 0) }
        let t0 = Date()
        let longFigures = FigureDetector.detect(segments: long)
        let elapsed = Date().timeIntervalSince(t0)
        let budget = 2.0
        print(String(format: "  90-minute fixture: %d segments, %d words → %d figures in %.3f s (budget %.1f s)",
                     long.count, words, longFigures.count, elapsed, budget))
        c.check("detection over the 90-minute fixture is under budget", elapsed < budget)

        c.finish(restore: flags.restore)
    }

    // MARK: - --selftest-figures-label (§P2, model stubbed)

    /// A backend that returns a fixed shape and records what it was asked.
    fileprivate final class StubLabelBackend: FigureLabelBackend, @unchecked Sendable {
        var available = true
        var calls: [[FigureLabelRequest]] = []
        var contexts: [String] = []
        var throwOn: Set<Int> = []
        var script: (FigureLabelRequest) -> FigureLabelResult = { r in
            FigureLabelResult(index: r.index, label: "label for \(r.raw)", keep: true, confidence: 0.9)
        }
        var isAvailable: Bool { available }
        func label(_ requests: [FigureLabelRequest], context: String) async throws -> [FigureLabelResult] {
            calls.append(requests); contexts.append(context)
            if throwOn.contains(calls.count) { throw SummaryError.emptyTranscript }
            return requests.map(script)
        }
    }

    static func runFiguresLabel() {
        setbuf(stdout, nil)
        print("== figures: labeller self-test (model stubbed) ==")
        let c = FigChecker()
        let flags = FigFlags()
        let segments = fixtureSegments()
        let candidates = FigureDetector.detect(segments: segments)
        let turns = Set(candidates.map(\.segmentIndex)).count

        let sem = DispatchSemaphore(value: 0)
        Task {
            // ---- Batching by turn.
            let stub = StubLabelBackend()
            let out = await FigureLabeller.run(candidates, segments: segments, backend: stub)
            c.check("one call per figure-bearing turn", stub.calls.count == turns && out.calls == turns)
            c.check("every candidate got a label", out.figures.allSatisfy { $0.label != nil })
            c.check("labels joined back by INDEX, not by position guessing",
                    out.figures.allSatisfy { $0.label == "label for \($0.raw)" })
            c.check("the batch carries the containing turn and its neighbours, capped",
                    stub.contexts.allSatisfy { $0.contains("»") && $0.count <= FigureLabeller.contextCap })
            c.check("no request or response carries a character offset",
                    stub.calls.flatMap { $0 }.allSatisfy { Mirror(reflecting: $0).children.map { $0.label ?? "" }.sorted() == ["index", "kind", "raw"] })
            c.check("labelling changes no anchor",
                    zip(out.figures, candidates).allSatisfy { $0.charStart == $1.charStart && $0.wordStart == $1.wordStart && $0.start == $1.start })
            c.check("the outcome is complete", out.complete)

            // ---- The confidence floor: keep the figure, null the label.
            let low = StubLabelBackend()
            low.script = { r in FigureLabelResult(index: r.index, label: "shaky", keep: true, confidence: 0.2) }
            let lowOut = await FigureLabeller.run(candidates, segments: segments, backend: low)
            c.check("below the floor, the figure is KEPT", lowOut.figures.count == candidates.count)
            c.check("below the floor, the label is null", lowOut.figures.allSatisfy { $0.label == nil })

            // ---- keep=false drops a false positive — but only when the model is confident.
            let veto = StubLabelBackend()
            veto.script = { r in FigureLabelResult(index: r.index, label: "", keep: r.raw != "3x", confidence: 0.95) }
            let vetoOut = await FigureLabeller.run(candidates, segments: segments, backend: veto)
            c.check("a confident keep=false drops the candidate", !vetoOut.figures.contains { $0.raw == "3x" } && vetoOut.figures.count == candidates.count - 1)
            let weakVeto = StubLabelBackend()
            weakVeto.script = { r in FigureLabelResult(index: r.index, label: "", keep: false, confidence: 0.1) }
            let weakOut = await FigureLabeller.run(candidates, segments: segments, backend: weakVeto)
            c.check("an unconfident keep=false drops nothing", weakOut.figures.count == candidates.count)
            c.check("an empty label is stored as nil, never \"\"", vetoOut.figures.allSatisfy { $0.label == nil })

            // ---- The call cap.
            let capped = StubLabelBackend()
            let capOut = await FigureLabeller.run(candidates, segments: segments, backend: capped, maxCalls: 3)
            c.check("the cap stops calls", capped.calls.count == 3)
            c.check("past the cap, figures survive with null labels",
                    capOut.figures.count == candidates.count && capOut.figures.contains { $0.label == nil } && capOut.figures.contains { $0.label != nil })
            c.check("a capped run reports incomplete", !capOut.complete)

            // ---- The throw path: the turn that threw keeps null labels, the rest proceed.
            let thrower = StubLabelBackend()
            thrower.throwOn = [2]
            let throwOut = await FigureLabeller.run(candidates, segments: segments, backend: thrower)
            c.check("a throw loses one turn's labels and nothing else",
                    throwOut.figures.count == candidates.count && throwOut.figures.filter { $0.label == nil }.count == candidates.filter { $0.segmentIndex == 1 }.count)
            c.check("a throw reports incomplete", !throwOut.complete)

            // ---- Unavailable: every candidate survives, unlabelled, with zero calls.
            let off = StubLabelBackend(); off.available = false
            let offOut = await FigureLabeller.run(candidates, segments: segments, backend: off)
            c.check("unavailable model ⇒ no calls, every figure kept, no labels",
                    off.calls.isEmpty && offOut.figures == candidates && offOut.calls == 0)

            // ---- An invented index is ignored rather than mislabelling a neighbour.
            let liar = StubLabelBackend()
            liar.script = { r in FigureLabelResult(index: r.index + 100, label: "wrong", keep: true, confidence: 0.99) }
            let liarOut = await FigureLabeller.run(candidates, segments: segments, backend: liar)
            c.check("an index the model invented labels nothing", liarOut.figures.allSatisfy { $0.label == nil })

            // ---- Already-labelled candidates are not re-sent (label reuse on re-extraction).
            let reuse = StubLabelBackend()
            let reuseOut = await FigureLabeller.run(out.figures, segments: segments, backend: reuse)
            c.check("labelled candidates are not sent again", reuse.calls.isEmpty && reuseOut.figures == out.figures)
            sem.signal()
        }
        sem.wait()
        c.finish(restore: flags.restore)
    }

    // MARK: - --selftest-figures-anchor (§P3, every row of the table)

    static func runFiguresAnchor() {
        setbuf(stdout, nil)
        print("== figures: anchoring self-test ==")
        let c = FigChecker()
        let flags = FigFlags()
        let dir = figTempDir("figanchor")
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments = fixtureSegments()
        let figures = FigureDetector.detect(segments: segments)
        let money = figures.first { $0.raw == "$2.4 million" }!
        let cac = figures.first { $0.raw == "240 dollars" }!
        let legacy = figures.first { $0.raw == "500 dollars" }!

        // Row 1: untouched → render.
        let plain = FigureOverlay.resolve(figures, in: segments)
        c.check("untouched overlay: every figure renders", plain.dropped == 0 && plain.resolved.count == figures.count)
        c.check("untouched overlay: display range equals the character anchor",
                plain.resolved.allSatisfy { $0.displayRange == $0.figure.charStart..<$0.figure.charEnd })

        // Row 2: an edit ELSEWHERE in the turn → render, range re-derived from the WORD anchor.
        let elsewhere = TranscriptEdit(segmentIndex: 0, wordIndex: 0, original: "Revenue", corrected: "Total revenue", at: Date())
        let edited = EditOverlay.apply(segments: segments, edits: [elsewhere])
        let r2 = FigureOverlay.resolve([money], in: edited)
        c.check("edit elsewhere in the turn: the figure still renders", r2.dropped == 0 && r2.resolved.count == 1)
        c.check("edit elsewhere: display range moved with the text",
                r2.resolved.first.map { $0.displayRange != money.charStart..<money.charEnd && Array(edited[0].text)[$0.displayRange].map(String.init).joined() == "$2.4 million" } ?? false)
        c.check("edit elsewhere: the stored character offset is NOT what rendered (word anchor won)",
                r2.resolved.first.map { $0.displayRange.lowerBound == money.charStart + "Total ".count } ?? false)

        // Row 3: an edit INSIDE the figure → drop, never partial.
        let inside = TranscriptEdit(segmentIndex: 0, wordIndex: 5, original: "million", corrected: "billion", at: Date())
        let editedInside = EditOverlay.apply(segments: segments, edits: [inside])
        let r3 = FigureOverlay.resolve([money], in: editedInside)
        c.check("edit inside the figure: dropped", r3.dropped == 1 && r3.resolved.isEmpty)
        let others = figures.filter { $0.segmentIndex != 0 }
        c.check("edit inside one figure leaves every other figure rendering", FigureOverlay.resolve(others, in: editedInside).dropped == 0)

        // Row 4: whole-turn rewrite (the legacy edit path sets words to nil) → drop.
        let rewrite = TranscriptEdit(segmentIndex: 0, wordIndex: nil, original: segments[0].text, corrected: "Revenue was fine.", at: Date())
        let r4 = FigureOverlay.resolve([money], in: EditOverlay.apply(segments: segments, edits: [rewrite]))
        c.check("whole-turn rewrite: dropped", r4.dropped == 1)

        // Row 5: the turn is gone → drop.
        let r5 = FigureOverlay.resolve([money, cac], in: Array(segments.prefix(2)))
        c.check("missing turn: dropped; a present one still renders", r5.dropped == 1 && r5.resolved.count == 1 && r5.resolved[0].figure.raw == "$2.4 million")

        // Legacy (character-only) anchor: exact text renders, any change drops.
        let rl = FigureOverlay.resolve([legacy], in: segments)
        c.check("legacy character anchor renders on unchanged text", rl.dropped == 0)
        var shifted = segments
        shifted[26].text = "The " + shifted[26].text
        c.check("legacy character anchor drops when the text shifts", FigureOverlay.resolve([legacy], in: shifted).dropped == 1)

        // Word anchor never falls back to offsets: a segment whose words vanish but whose text is
        // unchanged still drops the word-anchored figure.
        var wordsGone = segments
        wordsGone[0].words = nil
        c.check("word anchor with words gone: dropped, even though the text is unchanged",
                FigureOverlay.resolve([money], in: wordsGone).dropped == 1)

        // Row 6: re-transcription with a different engine → the whole sidecar is invalidated.
        let meta = SessionMeta(id: UUID(), date: Date(), sourceLabel: "Test", modelName: "m", engine: "whisper", engineModel: "base.en")
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)
        let side = FigureSidecar(transcriptFingerprint: FigureStore.fingerprint(segments: segments, meta: meta),
                                 engine: meta.engine, engineModel: meta.engineModel, extractedAt: Date(),
                                 labelled: false, labelCalls: 0, figures: figures)
        try? FigureStore.write(side, dir: dir)
        if case .ready = FigureStore.read(dir: dir) { c.check("a matching sidecar reads as ready", true) } else { c.check("a matching sidecar reads as ready", false) }
        var re = DocumentBuilder.readSession(dir)!
        re.meta.engine = "parakeet"; re.meta.engineModel = "v3"
        re.segments = segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker, words: $0.words) }
        DocumentBuilder.writeSession(re, to: dir)
        if case .stale(let why) = FigureStore.read(dir: dir) {
            c.check("re-transcription invalidates the sidecar entirely (\(why))", why == "transcript changed")
        } else { c.check("re-transcription invalidates the sidecar entirely", false) }
        FigureStore.isEnabled = true
        c.check("a stale sidecar reports the session as needing extraction", FigurePass.needsExtraction(dir: dir))
        c.check("with the flag on, a stale sidecar yields NO figures to display", FigureStore.figures(dir: dir).isEmpty)
        FigureStore.isEnabled = false

        // An edit inside a figure flags the session for re-extraction (§P3 "mark the session").
        let dir2 = figTempDir("figanchor2")
        defer { try? FileManager.default.removeItem(at: dir2) }
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir2)
        try? FigureStore.write(side, dir: dir2)
        FigureStore.isEnabled = true
        c.check("an intact session does not need re-extraction", !FigurePass.needsExtraction(dir: dir2))
        try? EditStore.write([inside], dir: dir2)
        c.check("an edit under a figure marks the session for re-extraction", FigurePass.needsExtraction(dir: dir2))
        FigureStore.isEnabled = false

        c.finish(restore: flags.restore)
    }

    // MARK: - --selftest-figures-bundle (§P4)

    static func runFiguresBundle(fixtureOut: String?) {
        setbuf(stdout, nil)
        print("== figures: sidecar + bundle self-test ==")
        let c = FigChecker()
        let flags = FigFlags()
        let root = figTempDir("figbundle")
        defer { try? FileManager.default.removeItem(at: root) }
        SessionLocation.rootProvider = { root }
        defer { SessionLocation.resetRootToPlatformDefault() }

        let segments = fixtureSegments()
        let id = UUID(uuidString: "6F1C2A1E-0000-4000-8000-00000000F16E")!
        let meta = SessionMeta(id: id, date: Date(timeIntervalSince1970: 1_780_000_000), sourceLabel: "Test",
                               modelName: "openai_whisper-base.en", title: "Figures fixture", engine: "whisper", engineModel: "base.en")
        let dir = root.appendingPathComponent("2026-06-01 10-00-00", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)
        let transcriptBefore = (try? Data(contentsOf: SessionPaths.transcriptURL(in: dir))) ?? Data()
        let jsonBefore = (try? Data(contentsOf: dir.appendingPathComponent("session.json"))) ?? Data()

        // ---- Extract with a stub labeller, so the fixture has labels to round-trip.
        FigureStore.isEnabled = true
        let stub = StubLabelBackend()
        stub.script = { r in FigureLabelResult(index: r.index, label: r.raw.contains("240") ? "customer acquisition cost" : "figure", keep: true, confidence: 0.8) }
        let sem = DispatchSemaphore(value: 0)
        Task { _ = await FigurePass.run(dir: dir, backend: stub); sem.signal() }
        sem.wait()
        c.check("figures.json written beside the transcript", FileManager.default.fileExists(atPath: FigureStore.url(dir: dir).path))
        c.check("extraction never touches transcript.md", (try? Data(contentsOf: SessionPaths.transcriptURL(in: dir))) == transcriptBefore)
        c.check("extraction never touches session.json", (try? Data(contentsOf: dir.appendingPathComponent("session.json"))) == jsonBefore)
        guard case .ready(let sidecar) = FigureStore.read(dir: dir) else { c.check("sidecar reads back", false); c.finish(restore: flags.restore) }
        c.check("sidecar carries the schema version", sidecar.schemaVersion == FigureSidecar.currentSchemaVersion)
        c.check("sidecar carries labels", sidecar.figures.contains { $0.label == "customer acquisition cost" })

        // ---- The committed cross-platform fixture (§9): written when asked, else compared.
        let fixtureDir = URL(fileURLWithPath: fixtureOut ?? "Fixtures/figures/session")
        if fixtureOut != nil {
            try? FileManager.default.removeItem(at: fixtureDir)
            try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            for name in ["session.json", FigureStore.fileName] {
                try? FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: fixtureDir.appendingPathComponent(name))
            }
            try? FileManager.default.copyItem(at: SessionPaths.transcriptURL(in: dir), to: fixtureDir.appendingPathComponent("transcript.md"))
            // Determinism across runs: the fixture must not carry a wall-clock timestamp.
            if var s = FigureStore.read(dir: fixtureDir).sidecar {
                s.extractedAt = Date(timeIntervalSince1970: 1_780_000_000)
                try? FigureStore.write(s, dir: fixtureDir)
            }
            print("  wrote fixture to \(fixtureDir.path)")
        }
        if FileManager.default.fileExists(atPath: FigureStore.url(dir: fixtureDir).path) {
            let fx = FigureStore.read(dir: fixtureDir)
            c.check("the committed fixture reads as ready on this platform", fx.sidecar != nil)
            if let fxDoc = DocumentBuilder.readSession(fixtureDir), let fxSide = fx.sidecar {
                let redetected = FigureDetector.detect(segments: EditStore.editedSegments(dir: fixtureDir, segments: fxDoc.segments))
                let stripped = fxSide.figures.map { var f = $0; f.label = nil; f.confidence = nil; return f }
                c.check("re-detecting the fixture on this platform yields the committed figures exactly", redetected == stripped)
                c.check("the fixture needs NO re-extraction here", !FigurePass.needsExtraction(dir: fixtureDir, doc: fxDoc))
            }
        } else {
            print("  (no committed fixture at \(fixtureDir.path) — run with --write-fixture <dir> to create it)")
        }

        // ---- Direction A: this build opens a bundle with NO figures.json.
        let plainDir = root.appendingPathComponent("2026-06-01 11-00-00", isDirectory: true)
        try? FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        var plainMeta = meta; plainMeta.id = UUID()
        DocumentBuilder.writeSession(SessionDoc(meta: plainMeta, segments: segments), to: plainDir)
        let plainBundle = root.appendingPathComponent("plain.said")
        do {
            try SessionBundle.write(sessionDir: plainDir, to: plainBundle)
            let importRoot = figTempDir("figimportA")
            defer { try? FileManager.default.removeItem(at: importRoot) }
            let outcome = try SessionBundle.read(bundle: plainBundle, into: importRoot)
            if case .imported(let dst) = outcome {
                c.check("a bundle with no figures.json opens", DocumentBuilder.readSession(dst) != nil)
                c.check("…and reads as 'absent', not an error", FigureStore.read(dir: dst) == .absent)
            } else { c.check("plain bundle imported", false) }
        } catch { c.check("plain bundle round-trip threw: \(error)", false) }

        // ---- Direction B: a bundle WITH figures.json opens, and the sidecar rides along whole.
        let figBundle = root.appendingPathComponent("figures.said")
        do {
            try SessionBundle.write(sessionDir: dir, to: figBundle)
            let importRoot = figTempDir("figimportB")
            defer { try? FileManager.default.removeItem(at: importRoot) }
            let outcome = try SessionBundle.read(bundle: figBundle, into: importRoot)
            if case .imported(let dst) = outcome {
                c.check("transcript byte-identical through the bundle", (try? Data(contentsOf: SessionPaths.transcriptURL(in: dst))) == transcriptBefore)
                c.check("figures.json byte-identical through the bundle",
                        (try? Data(contentsOf: FigureStore.url(dir: dst))) == (try? Data(contentsOf: FigureStore.url(dir: dir))))
                c.check("imported sidecar reads as ready (fingerprint matches the imported session)", FigureStore.read(dir: dst).sidecar?.figures == sidecar.figures)
                c.check("manifest.json did not leak", !FileManager.default.fileExists(atPath: dst.appendingPathComponent("manifest.json").path))
            } else { c.check("figure bundle imported", false) }
        } catch { c.check("figure bundle round-trip threw: \(error)", false) }
        c.check("the bundle format version did NOT move", SessionBundleManifest.currentFormatVersion == 1)

        // ---- A Phase 3 reader ignores unknown files: the bundle reader copies everything it does not
        //      know about and reads only what it does, so a sidecar is inert to a build without this
        //      wave. Asserted structurally: the session opens with the sidecar present and no reader
        //      of session.json / transcript.md depends on it.
        c.check("session.json is unchanged by the sidecar's presence", DocumentBuilder.readSession(dir)?.segments == segments)

        // ---- Schema versioning: unknown version ⇒ ignore + re-extract, never crash.
        var future = sidecar; future.schemaVersion = 99
        try? FigureStore.write(future, dir: dir)
        if case .stale(let why) = FigureStore.read(dir: dir) { c.check("an unknown schema version is ignored (\(why))", why.hasPrefix("schema")) }
        else { c.check("an unknown schema version is ignored", false) }
        c.check("…and flags the session for re-extraction", FigurePass.needsExtraction(dir: dir))
        try? Data("{ not json".utf8).write(to: FigureStore.url(dir: dir))
        if case .stale = FigureStore.read(dir: dir) { c.check("a corrupt sidecar is ignored, not fatal", true) } else { c.check("a corrupt sidecar is ignored, not fatal", false) }
        c.check("the session is still readable with a corrupt sidecar beside it", DocumentBuilder.readSession(dir) != nil)
        try? FigureStore.write(sidecar, dir: dir)

        // ---- Encryption: the sidecar routes through SessionIO like every other text artifact.
        SessionIO.overrideKey = SymmetricKey(size: .bits256)
        SessionIO.isEncryptionEnabled = true
        try? FigureStore.write(sidecar, dir: dir)
        let onDisk = (try? Data(contentsOf: FigureStore.url(dir: dir))) ?? Data()
        c.check("with encryption ON the sidecar is not plaintext on disk", !String(decoding: onDisk, as: UTF8.self).contains("schemaVersion"))
        c.check("…and reads back through the seam", FigureStore.read(dir: dir).sidecar?.figures == sidecar.figures)
        SessionIO.isEncryptionEnabled = false
        SessionIO.overrideKey = nil
        try? FigureStore.write(sidecar, dir: dir)

        // ---- Not in the byte-identity set: the existing bundle proof compares transcript.md and
        //      session.json fields, never the archive bytes — so a derived sidecar cannot break it.
        c.check("figures.json is derived: removing it leaves the session whole", {
            FigureStore.remove(dir: dir)
            return DocumentBuilder.readSession(dir) != nil && FigureStore.read(dir: dir) == .absent
        }())

        FigureStore.isEnabled = false
        c.finish(restore: flags.restore)
    }

    // MARK: - --selftest-figures-search (§Q3)

    static func runFiguresSearch() {
        setbuf(stdout, nil)
        print("== figures: search self-test ==")
        let c = FigChecker()
        let flags = FigFlags()
        let root = figTempDir("figsearch")
        defer { try? FileManager.default.removeItem(at: root) }
        SessionLocation.rootProvider = { root }
        defer { SessionLocation.resetRootToPlatformDefault() }

        // Two sessions: one with the CAC figure, one distractor that never says "acquisition".
        let segments = fixtureSegments()
        let a = root.appendingPathComponent("2026-06-01 10-00-00", isDirectory: true)
        let b = root.appendingPathComponent("2026-06-02 10-00-00", isDirectory: true)
        for d in [a, b] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let metaA = SessionMeta(id: UUID(), date: Date(timeIntervalSince1970: 1_780_000_000), sourceLabel: "Test", modelName: "m", title: "Finance review")
        let metaB = SessionMeta(id: UUID(), date: Date(timeIntervalSince1970: 1_780_086_400), sourceLabel: "Test", modelName: "m", title: "Lecture")
        DocumentBuilder.writeSession(SessionDoc(meta: metaA, segments: segments), to: a)
        DocumentBuilder.writeSession(SessionDoc(meta: metaB, segments: [timed(0, "Today we cover thermodynamics and entropy.")]), to: b)

        func freshIndex(_ tag: String) -> SearchIndex {
            SearchIndex(cacheURL: root.appendingPathComponent("index-\(tag).json"))
        }

        // ---- Baseline with the flag OFF (Phase 3 behaviour).
        FigureStore.isEnabled = false
        let offIndex = freshIndex("off")
        offIndex.rebuildFromDisk(root: root)
        let offCAC = offIndex.search("CAC")
        let offAcq = offIndex.search("acquisition cost")
        let off240 = offIndex.search("240")
        c.check("flag off: 'CAC' finds nothing (it was never spoken)", offCAC.isEmpty)
        c.check("flag off: 'acquisition cost' finds the spoken phrase", offAcq.first?.dir.lastPathComponent == a.lastPathComponent)
        c.check("flag off: '240' finds the session by the transcript alone", off240.first?.dir.lastPathComponent == a.lastPathComponent)

        // ---- Extract with a stub labeller: the label "CAC" is a term that exists nowhere in the text.
        FigureStore.isEnabled = true
        let stub = StubLabelBackend()
        stub.script = { r in FigureLabelResult(index: r.index, label: r.raw == "240 dollars" ? "customer acquisition cost (CAC)" : "", keep: true, confidence: 0.9) }
        let sem = DispatchSemaphore(value: 0)
        Task { _ = await FigurePass.run(dir: a, backend: stub); sem.signal() }
        sem.wait()

        let onIndex = freshIndex("on")
        onIndex.rebuildFromDisk(root: root)
        let onCAC = onIndex.search("CAC")
        let onAcq = onIndex.search("acquisition cost")
        let on240 = onIndex.search("240")
        c.check("flag on: 'CAC' (the label) finds the session", onCAC.first?.dir.lastPathComponent == a.lastPathComponent)
        c.check("flag on: 'acquisition cost' finds the session", onAcq.first?.dir.lastPathComponent == a.lastPathComponent)
        c.check("flag on: '240' finds the session", on240.first?.dir.lastPathComponent == a.lastPathComponent)
        let fig = FigureStore.figures(dir: a).first { $0.raw == "240 dollars" }
        for (name, r) in [("CAC", onCAC), ("acquisition cost", onAcq), ("240", on240)] {
            print("     \(name): " + (r.first?.snippets.map { "[\($0.timestamp ?? "--")] \($0.text)" }.joined(separator: " | ") ?? "-"))
        }
        c.check("all three queries reach the SAME moment (the figure's [mm:ss])",
                [onCAC, onAcq, on240].allSatisfy { $0.first?.snippets.first?.timestamp == fig?.timestamp })
        c.check("the figure snippet names the figure and its label", onCAC.first?.snippets.first?.text == "240 dollars — customer acquisition cost (CAC)")
        c.check("the distractor session is untouched", !onCAC.contains { $0.dir.lastPathComponent == b.lastPathComponent })

        // ---- Parity: the SAME index with the flag off again — the sidecar is on disk but inert.
        FigureStore.isEnabled = false
        let offAgain = freshIndex("off2")
        offAgain.rebuildFromDisk(root: root)
        c.check("flag off with a sidecar on disk: 'CAC' finds nothing", offAgain.search("CAC").isEmpty)
        c.check("flag off with a sidecar on disk: results identical to the pre-extraction index",
                offAgain.search("acquisition cost").map(\.dir.path) == offAcq.map(\.dir.path)
                && offAgain.search("240").first?.snippets.map(\.text) == off240.first?.snippets.map(\.text)
                && offAgain.search("240").first?.matchCount == off240.first?.matchCount)

        // ---- Ask/chat context gets the figures line, and only with the flag on.
        FigureStore.isEnabled = true
        let ctxOn = Intelligence.figuresContext(dir: a)
        FigureStore.isEnabled = false
        let ctxOff = Intelligence.figuresContext(dir: a)
        c.check("chat context carries the figures with their [mm:ss] when on", ctxOn.contains("[\(fig!.timestamp)] 240 dollars — customer acquisition cost (CAC)"))
        c.check("chat context is untouched when off", ctxOff.isEmpty)

        c.finish(restore: flags.restore)
    }

    // MARK: - --selftest-figures-offswitch (the most important test in the wave)

    static func runFiguresOffswitch() {
        setbuf(stdout, nil)
        print("== figures: off-switch self-test ==")
        let c = FigChecker()
        let flags = FigFlags()
        let root = figTempDir("figoff")
        defer { try? FileManager.default.removeItem(at: root) }
        SessionLocation.rootProvider = { root }
        defer { SessionLocation.resetRootToPlatformDefault() }

        FigureStore.isEnabled = false
        c.check("figuresEnabled defaults to false", !UserDefaults.standard.bool(forKey: "figuresEnabled"))

        // A full session round-trip: write, post-save passes that this wave hooks (the figure pass
        // + the index), export a bundle, import it, and compare EVERY byte against the same
        // round-trip done with no figure code in the way.
        let segments = fixtureSegments()
        let meta = SessionMeta(id: UUID(), date: Date(timeIntervalSince1970: 1_780_000_000), sourceLabel: "Test",
                               modelName: "m", title: "Off switch", engine: "parakeet", engineModel: "v3")
        let dir = root.appendingPathComponent("2026-06-01 10-00-00", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)

        func snapshot(_ d: URL) -> [String: String] {
            var out: [String: String] = [:]
            if let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil) {
                for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    let rel = u.path.replacingOccurrences(of: d.path + "/", with: "")
                    let data = (try? Data(contentsOf: u)) ?? Data()
                    out[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
            }
            return out
        }
        let before = snapshot(dir)
        let sem = DispatchSemaphore(value: 0)
        Task { _ = await FigurePass.runIfEnabled(dir: dir, backend: StubLabelBackend()); sem.signal() }
        sem.wait()
        c.check("with the flag off, the pass writes nothing", snapshot(dir) == before)
        c.check("with the flag off, no figures.json exists", !FileManager.default.fileExists(atPath: FigureStore.url(dir: dir).path))
        c.check("with the flag off, FigureStore returns no figures without opening a file", FigureStore.figures(dir: dir).isEmpty)
        c.check("with the flag off, needsExtraction is false", !FigurePass.needsExtraction(dir: dir))

        // The index: identical term tables to a Phase 3 index of the same session.
        let idx = SearchIndex(cacheURL: root.appendingPathComponent("idx.json"))
        idx.rebuildFromDisk(root: root)
        let hits = idx.search("dollars")
        c.check("index hit count is the transcript's own (four spoken 'dollars')", hits.first?.matchCount == 4)
        c.check("index snippets come from the transcript, not a sidecar", hits.first?.snippets.allSatisfy { !$0.text.contains(" — ") } ?? false)

        // The bundle: the archive payload is the session folder — and the folder is unchanged.
        let bundle = root.appendingPathComponent("off.said")
        do {
            try SessionBundle.write(sessionDir: dir, to: bundle)
            let importRoot = figTempDir("figoffimport")
            defer { try? FileManager.default.removeItem(at: importRoot) }
            if case .imported(let dst) = try SessionBundle.read(bundle: bundle, into: importRoot) {
                let after = snapshot(dst)
                c.check("bundle round-trip: transcript.md byte-identical", after[SessionPaths.transcriptURL(in: dst).lastPathComponent] == before[SessionPaths.transcriptURL(in: dir).lastPathComponent])
                c.check("bundle round-trip: session.json byte-identical", after["session.json"] == before["session.json"])
                c.check("bundle round-trip: the SAME file set, nothing added", Set(after.keys) == Set(before.keys))
            } else { c.check("bundle imported", false) }
        } catch { c.check("bundle round-trip threw: \(error)", false) }

        // Chat context: no figures line.
        c.check("chat context carries no figures line", Intelligence.figuresContext(dir: dir).isEmpty)

        // The sidecar can exist on disk (a bundle from a Mac that had the feature on) and STILL be
        // inert with the flag off: no figures, no index terms, no context.
        let side = FigureSidecar(transcriptFingerprint: FigureStore.fingerprint(segments: segments, meta: meta),
                                 engine: "parakeet", engineModel: "v3", extractedAt: Date(), labelled: true, labelCalls: 1,
                                 figures: FigureDetector.detect(segments: segments).map { var f = $0; f.label = "ZZZUNIQUE"; return f })
        try? FigureStore.write(side, dir: dir)
        c.check("a sidecar on disk is inert with the flag off (no figures surfaced)", FigureStore.figures(dir: dir).isEmpty)
        let idx2 = SearchIndex(cacheURL: root.appendingPathComponent("idx2.json"))
        idx2.rebuildFromDisk(root: root)
        c.check("a sidecar on disk is inert with the flag off (no label terms indexed)", idx2.search("ZZZUNIQUE").isEmpty)
        c.check("a sidecar on disk is inert with the flag off (no context line)", Intelligence.figuresContext(dir: dir).isEmpty)

        c.finish(restore: flags.restore)
    }
}
