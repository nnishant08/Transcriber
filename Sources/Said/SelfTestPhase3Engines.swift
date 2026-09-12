import Foundation
import SaidKit

extension SelfTest {

    // MARK: - Word-boundary speaker alignment (§7.7)

    /// The Phase 3 additions to `--selftest-align`, called from the existing mode so the old
    /// assertions and the new ones live in one place and run together.
    ///
    /// The legacy guarantee is asserted TWICE, and the two do different jobs.
    ///
    /// **Structurally**, the dispatcher and the preserved `assignWholeSegment` must agree
    /// element-for-element on segments with no word timings. That is the stronger check and it
    /// cannot drift, because it compares the code against itself — `assignWholeSegment` IS the
    /// pre-Phase-3 function.
    ///
    /// **Against a fixture**, when one is committed. Note what this can and cannot be: the fixture
    /// necessarily comes from the CURRENT build (`--selftest-align --emit-fixture <path>`), because
    /// a pre-Phase-3 binary has no such flag. So it does not prove equivalence with the old build —
    /// the structural check already does that — it LOCKS today's behaviour against future drift in
    /// `assignWholeSegment` itself, which the structural check cannot catch.
    static func alignPhase3(check: (String, Bool) -> Void, emitFixture: String? = nil) {
        let turns = SpeakerAlignment.normalize([
            (id: "A", start: 0.0, end: 5.0),
            (id: "B", start: 5.0, end: 10.0),
        ])

        // ---- Legacy: no word timings ⇒ byte-identical to the pre-Phase-3 algorithm.
        let legacy = [
            TranscriptSegment(start: 0.0, end: 3.0, text: "one"),
            TranscriptSegment(start: 3.5, end: 6.0, text: "two"),
            TranscriptSegment(start: 20.0, end: 22.0, text: "three"),
        ]
        let viaDispatcher = SpeakerAlignment.assign(segments: legacy, turns: turns)
        let viaLegacy = SpeakerAlignment.assignWholeSegment(segments: legacy, turns: turns)
        check("legacy alignment is IDENTICAL to the pre-Phase-3 algorithm", viaDispatcher == viaLegacy)
        check("legacy alignment does not split segments", viaDispatcher.count == legacy.count)
        check("legacy alignment leaves text and timing untouched",
              viaDispatcher.map(\.text) == legacy.map(\.text)
                  && viaDispatcher.map(\.start) == legacy.map(\.start))

        // Emit the fixture on request, so a future change to `assignWholeSegment` has something to
        // fail against.
        if let emitFixture {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            if let data = try? enc.encode(viaDispatcher.map(\.speaker)) {
                try? data.write(to: URL(fileURLWithPath: emitFixture))
                print("  · wrote align fixture to \(emitFixture)")
            }
        }
        let fixture = URL(fileURLWithPath: "Fixtures/baselines/align-legacy-fixture.json")
        if let data = try? Data(contentsOf: fixture),
           let expected = try? JSONDecoder().decode([Int?].self, from: data) {
            check("legacy alignment matches the committed fixture",
                  viaDispatcher.map(\.speaker) == expected)
        } else {
            print("  · (no align-legacy-fixture.json yet — structural equivalence stands on its own;")
            print("     capture one with: --selftest-align --emit-fixture Fixtures/baselines/align-legacy-fixture.json)")
        }

        // ---- A speaker change INSIDE a segment: the case that was silently wrong before.
        // Speaker A talks to 5.0, B from 5.0. The segment straddles the boundary.
        let straddling = TranscriptSegment(
            start: 3.0, end: 8.0,
            text: "I think we should ship it no we absolutely should not ship it",
            words: [
                WordTiming(text: "I", start: 3.0, end: 3.2),
                WordTiming(text: "think", start: 3.3, end: 3.6),
                WordTiming(text: "we", start: 3.7, end: 3.9),
                WordTiming(text: "should", start: 4.0, end: 4.3),
                WordTiming(text: "ship", start: 4.4, end: 4.7),
                WordTiming(text: "it", start: 4.8, end: 4.95),
                WordTiming(text: "no", start: 5.2, end: 5.4),
                WordTiming(text: "we", start: 5.5, end: 5.7),
                WordTiming(text: "absolutely", start: 5.8, end: 6.3),
                WordTiming(text: "should", start: 6.4, end: 6.7),
                WordTiming(text: "not", start: 6.8, end: 7.0),
                WordTiming(text: "ship", start: 7.1, end: 7.4),
                WordTiming(text: "it", start: 7.5, end: 7.8),
            ])
        let split = SpeakerAlignment.assign(segments: [straddling], turns: turns)
        check("a mid-segment speaker change splits the segment", split.count == 2)
        check("the first half is speaker 1", split.first?.speaker == 1)
        check("the second half is speaker 2", split.last?.speaker == 2)
        check("the split lands at the right word",
              split.first?.text.hasSuffix("ship it") == true && split.last?.text.hasPrefix("no") == true)
        check("no text is lost across the split",
              split.map(\.text).joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
                  == straddling.text)
        check("each half carries its own words",
              (split.first?.validWords?.count ?? 0) == 6 && (split.last?.validWords?.count ?? 0) == 7)
        check("each half is timed by its own words",
              split.first?.start == 3.0 && split.last?.start == 5.2)

        // ---- A single stray word is diarizer noise, not a turn.
        let stray = TranscriptSegment(
            start: 0.0, end: 4.0, text: "one two three four five six seven",
            words: [
                WordTiming(text: "one", start: 0.0, end: 0.3),
                WordTiming(text: "two", start: 0.4, end: 0.7),
                WordTiming(text: "three", start: 0.8, end: 1.1),
                WordTiming(text: "four", start: 5.1, end: 5.3),   // one word inside speaker B
                WordTiming(text: "five", start: 1.5, end: 1.8),
                WordTiming(text: "six", start: 1.9, end: 2.2),
                WordTiming(text: "seven", start: 2.3, end: 2.6),
            ])
        // (Deliberately non-monotonic, so `validWords` rejects it and the whole-segment path runs —
        // which is itself the behaviour worth asserting: bad timings degrade, they do not split.)
        let strayResult = SpeakerAlignment.assign(segments: [stray], turns: turns)
        check("timings that fail validation do not split the segment", strayResult.count == 1)

        // A properly-ordered short run IS absorbed rather than split out.
        let shortRun = TranscriptSegment(
            start: 3.0, end: 7.0, text: "alpha beta gamma delta epsilon zeta",
            words: [
                WordTiming(text: "alpha", start: 3.0, end: 3.3),
                WordTiming(text: "beta", start: 3.4, end: 3.7),
                WordTiming(text: "gamma", start: 3.8, end: 4.1),
                WordTiming(text: "delta", start: 4.2, end: 4.5),
                WordTiming(text: "epsilon", start: 5.1, end: 5.4),   // 2 words in speaker B — below
                WordTiming(text: "zeta", start: 5.5, end: 5.8),      // minimumRunWords (3)
            ])
        check("a run shorter than the minimum is absorbed, not split out",
              SpeakerAlignment.assign(segments: [shortRun], turns: turns).count == 1)

        // ---- A stray word in the MIDDLE, which is where absorption used to leave a scar.
        // Absorbing the excursion leaves speaker-1 runs on both sides of it; unless they are
        // coalesced the caller sees two runs and splits one sentence into two consecutive lines
        // under the SAME label. The pre-existing short-run case above cannot catch this, because its
        // stray sits at the END and collapses to a single run either way.
        let interiorTurns = SpeakerAlignment.normalize([
            (id: "A", start: 0.0, end: 2.0),
            (id: "B", start: 2.0, end: 2.4),
            (id: "A", start: 2.4, end: 10.0),
        ])
        let interior = TranscriptSegment(
            start: 0.0, end: 4.5, text: "one two three four five six seven eight nine ten eleven",
            words: [
                WordTiming(text: "one", start: 0.0, end: 0.3),
                WordTiming(text: "two", start: 0.4, end: 0.7),
                WordTiming(text: "three", start: 0.8, end: 1.1),
                WordTiming(text: "four", start: 1.2, end: 1.5),
                WordTiming(text: "five", start: 1.6, end: 1.9),
                WordTiming(text: "six", start: 2.1, end: 2.3),      // the lone excursion
                WordTiming(text: "seven", start: 2.5, end: 2.8),
                WordTiming(text: "eight", start: 2.9, end: 3.2),
                WordTiming(text: "nine", start: 3.3, end: 3.6),
                WordTiming(text: "ten", start: 3.7, end: 4.0),
                WordTiming(text: "eleven", start: 4.1, end: 4.4),
            ])
        let interiorResult = SpeakerAlignment.assign(segments: [interior], turns: interiorTurns)
        check("a stray word mid-sentence is absorbed without splitting the line",
              interiorResult.count == 1)
        check("…and the whole line keeps one speaker", interiorResult.first?.speaker == 1)
        check("…with its text intact", interiorResult.first?.text == interior.text)

        // ---- A split must MOVE characters between parts, never drop them — including any that sit
        // before the first word the engine emitted.
        let leading = TranscriptSegment(
            start: 3.0, end: 8.0,
            text: "— I think we should ship it no we absolutely should not ship it",
            words: straddling.validWords ?? [])
        let leadingSplit = SpeakerAlignment.assign(segments: [leading], turns: turns)
        check("a leading character survives a split", leadingSplit.count == 2
              && leadingSplit.first?.text.hasPrefix("—") == true)
        check("…and nothing else is lost",
              leadingSplit.map(\.text).joined(separator: " ") == leading.text)

        // ---- Empty turns still change nothing.
        check("no diarizer turns → segments unchanged",
              SpeakerAlignment.assign(segments: [straddling], turns: []).count == 1)

        // ---- The slot mapping the voiceprint pass depends on agrees with `normalize`.
        let (turns2, slots) = SpeakerAlignment.normalizeWithSlots([
            (id: "spk_B", start: 0.0, end: 4.0),
            (id: "spk_A", start: 4.5, end: 9.0),
        ])
        check("normalizeWithSlots agrees with normalize", turns2.map(\.speaker) == [1, 2])
        check("…and reports the id → slot mapping", slots["spk_B"] == 1 && slots["spk_A"] == 2)
    }

    // MARK: - --selftest-parakeet

    /// Prepare Parakeet, transcribe, and assert the token timings map cleanly onto `WordTiming`.
    ///
    /// Needs real models, so it SKIPS rather than fails when they are absent or downloads are off.
    /// A red bar for "you are offline" would train everyone to ignore the suite.
    static func runParakeet(path: String?) {
        setbuf(stdout, nil)
        print("== parakeet self-test ==")
        let audioPath = path ?? "/tmp/transcriber_test.wav"
        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("SKIP: no audio at \(audioPath) (make one with `say` + `afconvert`)")
            exit(0)
        }
        var ok = true
        func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }

        let sema = SemaphoreBox()
        Task {
            let engine = TranscriptionEngine()
            do {
                try await engine.prepareParakeet { msg, frac in
                    print("  [status] \(msg) \(frac.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
                }
            } catch {
                print("SKIP: Parakeet models unavailable (\(error))")
                sema.result = true
                sema.signal()
                return
            }

            do {
                let started = Date()
                let samples = try await AudioFileIO.decodeTo16kMono(url: URL(fileURLWithPath: audioPath))
                let segments = try await engine.transcribeSamples(samples, language: "en")
                let elapsed = Date().timeIntervalSince(started)
                let audioSeconds = Double(samples.count) / 16_000.0

                print("  transcript: \(segments.map(\.text).joined(separator: " "))")
                print(String(format: "  RTFx: %.1f× (%.2fs of audio in %.2fs)",
                             audioSeconds / max(elapsed, 0.001), audioSeconds, elapsed))

                check("produced text", !segments.isEmpty && segments.contains { !$0.text.isEmpty })
                let timed = segments.filter { $0.validWords != nil }
                check("word timings are present", !timed.isEmpty)
                check("word timings are monotonic within each segment",
                      timed.allSatisfy { seg in
                          let w = seg.validWords ?? []
                          return zip(w, w.dropFirst()).allSatisfy { $0.start <= $1.start }
                      })
                check("word timings sit inside their segment", timed.allSatisfy { $0.validWords != nil })
                check("every word carries a confidence",
                      timed.allSatisfy { ($0.validWords ?? []).allSatisfy { $0.confidence != nil } })
                check("segments are in time order",
                      zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
                check("the engine identifies itself", engine.activeEngine == .parakeet)
                sema.result = ok
            } catch {
                print("  ERROR: \(error)")
                sema.result = false
            }
            sema.signal()
        }
        sema.wait()
        print(sema.result ? "OK" : "FAIL")
        exit(sema.result ? 0 : 2)
    }

    // MARK: - --selftest-bias

    /// §5.4's before/after assertion: a domain term the general model gets wrong comes out right
    /// once the vocabulary is supplied, and wrong without it.
    ///
    /// This is the test the engine swap is gated on. If it cannot pass, the vertical packs are inert
    /// on the default engine and that is a stop-the-build finding, not a nice-to-have.
    static func runBias(path: String?, terms: [String]) {
        setbuf(stdout, nil)
        print("== vocabulary-bias self-test ==")
        let audioPath = path ?? "/tmp/said_bias_test.wav"
        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("""
            SKIP: no audio at \(audioPath).
              Make one with a term a general model mishears, e.g.:
                say -o /tmp/said_bias.aiff "The surgeon completed the anastomosis without complication"
                afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/said_bias.aiff /tmp/said_bias_test.wav
              Then:  --selftest-bias /tmp/said_bias_test.wav --terms anastomosis
            """)
            exit(0)
        }
        guard let bias = VocabularyBias(terms: terms) else {
            print("SKIP: no terms given (--terms a,b,c)")
            exit(0)
        }

        let sema = SemaphoreBox()
        Task {
            let engine = TranscriptionEngine()
            do {
                try await engine.prepareParakeet { msg, _ in print("  [status] \(msg)") }
            } catch {
                print("SKIP: Parakeet models unavailable (\(error))")
                sema.result = true; sema.signal(); return
            }
            do {
                let samples = try await AudioFileIO.decodeTo16kMono(url: URL(fileURLWithPath: audioPath))
                let without = try await engine.transcribeSamples(samples, language: "en", bias: nil)
                let with = try await engine.transcribeSamples(samples, language: "en", bias: bias)
                let a = without.map(\.text).joined(separator: " ")
                let b = with.map(\.text).joined(separator: " ")
                print("  without vocabulary: \(a)")
                print("  with vocabulary:    \(b)")

                var ok = true
                func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }
                check("bias is reported as effective on this engine", engine.vocabularyBiasIsEffective)
                let found = terms.contains { b.localizedCaseInsensitiveContains($0) }
                let foundWithout = terms.contains { a.localizedCaseInsensitiveContains($0) }
                check("the term appears WITH the vocabulary", found)
                if foundWithout {
                    print("  · note: the term was already correct without biasing — pick a harder "
                          + "term to make this test meaningful.")
                }
                check("the two passes differ, or the term was already right", b != a || foundWithout)
                sema.result = ok
            } catch {
                print("  ERROR: \(error)")
                sema.result = false
            }
            sema.signal()
        }
        sema.wait()
        print(sema.result ? "OK" : "FAIL")
        exit(sema.result ? 0 : 2)
    }

    // MARK: - --compare-engines

    /// Re-transcribe a folder of real sessions through every available engine and report the
    /// difference. A CLI TOOL, not a self-test — it has no pass/fail.
    ///
    /// **This is a deliverable, not an extra** (§5.8). Making Parakeet the default rests on
    /// benchmarks other people ran on read-audiobook English, which is not what Said records. This
    /// is how the decision gets checked against the user's own audio, how a regression gets caught
    /// after a future dependency bump, and how "should we add Apple's SpeechAnalyzer" gets answered
    /// with evidence instead of a blog post.
    ///
    /// READ-ONLY on the input: it decodes each session's audio and writes only into `--out`.
    static func runCompareEngines(folder: String?, termsPath: String?, out: String?) {
        setbuf(stdout, nil)
        print("== engine comparison ==")
        let root = URL(fileURLWithPath: folder ?? SessionLocation.root.path)
        let outDir = URL(fileURLWithPath: out ?? "/tmp/said-engine-comparison")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var terms: [String] = []
        if let termsPath, let text = try? String(contentsOfFile: termsPath, encoding: .utf8) {
            terms = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            print("terms: \(terms.count) loaded from \(termsPath)")
        }

        let dirs = SessionStore.sessionDirectoryURLs(root: root)
        print("sessions: \(dirs.count) under \(root.path)")
        guard !dirs.isEmpty else { print("nothing to compare"); exit(0) }

        let sema = SemaphoreBox()
        Task {
            var rows: [Row] = []
            for dir in dirs {
                guard let doc = DocumentBuilder.readSession(dir),
                      let audioName = doc.meta.audioFile else { continue }
                let audio = dir.appendingPathComponent(audioName)
                guard FileManager.default.fileExists(atPath: audio.path) else { continue }

                print("→ \(dir.lastPathComponent)")
                guard let samples = try? await AudioFileIO.decodeTo16kMono(url: audio),
                      !samples.isEmpty else { continue }
                let audioSeconds = Double(samples.count) / 16_000.0
                let language = doc.meta.language ?? "en"

                var byEngine: [String: String] = [:]
                var timing: [String: Double] = [:]      // engine → RTFx

                for engineID in TranscriptionEngineID.allCases {
                    let engine = TranscriptionEngine()
                    do {
                        switch engineID {
                        case .parakeet:
                            try await engine.prepareParakeet { _, _ in }
                        case .whisper:
                            // `meta.engineModel` (public) rather than `meta.modelName` (internal to
                            // SaidKit) — and more correct besides: a session recorded on Parakeet
                            // names a Parakeet variant there, which is not something Whisper can
                            // load, so anything that is not a Whisper variant falls back to base.en.
                            let recorded = doc.meta.engineModel ?? ""
                            let variant = recorded.hasPrefix("openai_whisper-")
                                ? recorded : "openai_whisper-base.en"
                            try await engine.prepare(model: variant) { _, _ in }
                        }
                    } catch {
                        print("   \(engineID.displayName): unavailable (\(error))")
                        continue
                    }
                    let t0 = Date()
                    guard let segs = try? await engine.transcribeSamples(samples, language: language) else {
                        print("   \(engineID.displayName): failed")
                        continue
                    }
                    let elapsed = Date().timeIntervalSince(t0)
                    let text = segs.map(\.text).joined(separator: " ")
                    byEngine[engineID.rawValue] = text
                    timing[engineID.rawValue] = audioSeconds / max(elapsed, 0.001)
                    print(String(format: "   %@: %.1f× real time, %d chars",
                                 engineID.displayName, audioSeconds / max(elapsed, 0.001), text.count))
                    await engine.unloadAll()
                }
                guard byEngine.count > 1 else { continue }

                let row = Row(session: dir.lastPathComponent, audioSeconds: audioSeconds,
                              texts: byEngine, timing: timing, terms: terms)
                rows.append(row)
                try? row.detail().write(to: outDir.appendingPathComponent("\(dir.lastPathComponent).txt"),
                                        atomically: true, encoding: .utf8)
            }

            print("")
            print(Self.summaryTable(rows: rows, terms: terms))
            let summary = Self.summaryTable(rows: rows, terms: terms)
            try? summary.write(to: outDir.appendingPathComponent("SUMMARY.txt"),
                               atomically: true, encoding: .utf8)
            print("detail written to \(outDir.path)")
            sema.signal()
        }
        sema.wait()
        exit(0)
    }

    struct Row {
        let session: String
        let audioSeconds: Double
        let texts: [String: String]
        let timing: [String: Double]      // engine → RTFx
        let terms: [String]

        /// Per-term recall: did this engine's transcript contain the term at all?
        ///
        /// **This is the number that actually matters** and it is not what LibriSpeech measures. A
        /// character-level diff tells you the engines disagree; per-term recall tells you which one
        /// got the drug name right.
        func recall(_ engine: String) -> (found: Int, total: Int) {
            guard let text = texts[engine], !terms.isEmpty else { return (0, terms.count) }
            let found = terms.filter { text.localizedCaseInsensitiveContains($0) }.count
            return (found, terms.count)
        }

        func detail() -> String {
            var out = "SESSION: \(session)\n"
            out += String(format: "audio: %.1fs\n\n", audioSeconds)
            for (engine, text) in texts.sorted(by: { $0.key < $1.key }) {
                out += "--- \(engine)"
                if let rtfx = timing[engine] { out += String(format: "  (%.1f× real time)", rtfx) }
                if !terms.isEmpty {
                    let r = recall(engine)
                    out += "  [terms \(r.found)/\(r.total)]"
                }
                out += "\n\(text)\n\n"
            }
            if !terms.isEmpty {
                out += "--- per-term\n"
                for term in terms {
                    let marks = texts.keys.sorted().map { e in
                        (texts[e]?.localizedCaseInsensitiveContains(term) == true) ? "\(e):yes" : "\(e):NO"
                    }
                    out += "  \(term)  \(marks.joined(separator: "  "))\n"
                }
            }
            return out
        }
    }

    static func summaryTable(rows: [Row], terms: [String]) -> String {
        guard !rows.isEmpty else { return "no comparable sessions (each needs saved audio)" }
        var out = "SESSION                          AUDIO   ENGINE     RTFx   CHARS  DIVERGE  TERMS\n"
        out += String(repeating: "-", count: 84) + "\n"
        var totalRecall: [String: (Int, Int)] = [:]
        for row in rows {
            let engines = row.texts.keys.sorted()
            let reference = engines.first.flatMap { row.texts[$0] } ?? ""
            for e in engines {
                let text = row.texts[e] ?? ""
                let diverge = Self.divergence(reference, text)
                let r = row.recall(e)
                totalRecall[e, default: (0, 0)].0 += r.found
                totalRecall[e, default: (0, 0)].1 += r.total
                out += String(format: "%-32@ %5.0fs   %-9@ %5.1f  %6d  %6.1f%%  %3d/%-3d\n",
                              String(row.session.prefix(32)) as NSString, row.audioSeconds,
                              e as NSString, row.timing[e] ?? 0, text.count,
                              diverge * 100, r.found, r.total)
            }
        }
        if !terms.isEmpty {
            out += "\nPER-TERM RECALL ACROSS ALL SESSIONS (the number that decides the default):\n"
            for (engine, tally) in totalRecall.sorted(by: { $0.key < $1.key }) {
                let pct = tally.1 > 0 ? Double(tally.0) / Double(tally.1) * 100 : 0
                out += String(format: "  %-10@ %3d/%-3d  %5.1f%%\n",
                              engine as NSString, tally.0, tally.1, pct)
            }
        }
        return out
    }

    /// Normalised character-level divergence — 0 means identical, 1 means nothing in common.
    /// A cheap proxy: exact edit distance over multi-hour transcripts is not worth the wait, and the
    /// per-term recall above is the number that carries the decision anyway.
    static func divergence(_ a: String, _ b: String) -> Double {
        let x = Set(SearchIndex.tokenize(a))
        let y = Set(SearchIndex.tokenize(b))
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        let shared = x.intersection(y).count
        let union = x.union(y).count
        return union > 0 ? 1.0 - Double(shared) / Double(union) : 0
    }

}
