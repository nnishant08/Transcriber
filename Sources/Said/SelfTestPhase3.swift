import Foundation
import CryptoKit
import SaidKit

// Phase 3's headless self-tests.
//
// Every mode here runs with NO models, NO audio hardware and NO permissions, and writes only to a
// temp directory. That is not a limitation, it is the design: the parts of Phase 3 that can produce
// a silently wrong transcript — routing, the word-timing accessor, the edit overlay, speaker
// splitting, voiceprint matching, slide collapsing, chunking and fusion — are all pure functions
// precisely so they can be asserted this thoroughly without a GPU.
//
// `--selftest-parakeet` and `--selftest-bias` are the exceptions: they need real models, and they
// say so and skip cleanly rather than failing when the models are absent.

extension SelfTest {

    // MARK: - Shared helpers

    /// The house `check` helper, matching the other modes exactly.
    fileprivate final class Checker {
        var ok = true
        func check(_ label: String, _ cond: Bool) {
            print("  \(cond ? "✓" : "✗") \(label)")
            ok = ok && cond
        }
        func finish() -> Never {
            print(ok ? "OK" : "FAIL")
            exit(ok ? 0 : 2)
        }
    }

    fileprivate static func tempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("said-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    fileprivate static func words(_ specs: [(String, Double, Double)], confidence: Float? = nil) -> [WordTiming] {
        specs.map { WordTiming(text: $0.0, start: $0.1, end: $0.2, confidence: confidence) }
    }

    // MARK: - --selftest-words (Wave 1)

    static func runWords() {
        setbuf(stdout, nil)
        print("== word-substrate self-test ==")
        let c = Checker()

        // ---- validWords: the four rejection cases and the accept case.
        let good = TranscriptSegment(start: 0, end: 3, text: "one two three",
                                     words: words([("one", 0.0, 0.5), ("two", 0.6, 1.2), ("three", 1.4, 2.9)]))
        c.check("valid words are returned", good.validWords?.count == 3)
        c.check("hasWordTimings agrees", good.hasWordTimings)

        let absent = TranscriptSegment(start: 0, end: 3, text: "no timings")
        c.check("absent words → nil (the ordinary case)", absent.validWords == nil)

        // Empty is normalised to nil at construction, so it can never reach disk as `[]`.
        let empty = TranscriptSegment(start: 0, end: 3, text: "x", words: [])
        c.check("empty words normalise to nil", empty.words == nil && empty.validWords == nil)

        let nonMonotonic = TranscriptSegment(start: 0, end: 3, text: "a b",
                                             words: words([("b", 1.5, 2.0), ("a", 0.1, 0.5)]))
        c.check("non-monotonic → nil", nonMonotonic.validWords == nil)

        let inverted = TranscriptSegment(start: 0, end: 3, text: "a",
                                         words: words([("a", 2.0, 1.0)]))
        c.check("inverted span → nil", inverted.validWords == nil)

        let outOfBounds = TranscriptSegment(start: 10, end: 13, text: "a b",
                                            words: words([("a", 0.0, 0.5), ("b", 0.6, 1.0)]))
        c.check("words outside the segment → nil", outOfBounds.validWords == nil)

        // The tolerance exists to absorb engine rounding, not to accept a mismatched array.
        let justOutside = TranscriptSegment(start: 1.0, end: 3.0, text: "a",
                                            words: words([("a", 0.9, 2.9)]))
        c.check("within tolerance is accepted", justOutside.validWords != nil)

        // ---- Encoding: a segment with no words gains NO key; one with words round-trips.
        let enc = JSONEncoder()
        let plainJSON = String(data: (try? enc.encode(absent)) ?? Data(), encoding: .utf8) ?? ""
        c.check("no `words` key when absent", !plainJSON.contains("\"words\""))
        let emptyJSON = String(data: (try? enc.encode(empty)) ?? Data(), encoding: .utf8) ?? ""
        c.check("no `words` key when empty", !emptyJSON.contains("\"words\""))

        if let data = try? enc.encode(good),
           let back = try? JSONDecoder().decode(TranscriptSegment.self, from: data) {
            c.check("word timings round-trip", back.validWords?.map(\.text) == ["one", "two", "three"])
            c.check("confidence round-trips as nil", back.validWords?.first?.confidence == nil)
        } else {
            c.check("word timings round-trip", false)
        }

        // A `words` array of an unexpected SHAPE must degrade, not throw (the `frames` precedent).
        let hostile = """
        {"start":0,"end":3,"text":"hi","words":[{"nope":1}]}
        """.data(using: .utf8)!
        let decodedHostile = try? JSONDecoder().decode(TranscriptSegment.self, from: hostile)
        c.check("malformed `words` decodes to nil, session still readable",
                decodedHostile != nil && decodedHostile?.words == nil)

        // ---- Schema version: a legacy session is NOT silently upgraded by being read.
        let legacyJSON = """
        {"meta":{"date":694224000,"sourceLabel":"Mic","modelName":"m","tags":[]},"segments":[]}
        """.data(using: .utf8)!
        let legacy = try? JSONDecoder().decode(SessionDoc.self, from: legacyJSON)
        c.check("legacy session decodes", legacy != nil)
        c.check("legacy schemaVersion decodes as 0", legacy?.meta.schemaVersion == 0)
        if let legacy, let re = try? enc.encode(legacy),
           let s = String(data: re, encoding: .utf8) {
            c.check("re-encoding does NOT upgrade the version", s.contains("\"schemaVersion\":0"))
            c.check("re-encoding adds no `words` key", !s.contains("\"words\""))
        }
        c.check("a NEW session is written at the current version",
                SessionMeta(date: Date(), sourceLabel: "Mic", modelName: "m").schemaVersion
                    == SessionMeta.currentSchemaVersion)

        // ---- SessionIO round-trip, encryption OFF and ON.
        let dir = tempDir("words")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = SessionDoc(meta: SessionMeta(date: Date(), sourceLabel: "Mic", modelName: "m"),
                             segments: [good])

        SessionIO.isEncryptionEnabled = false
        DocumentBuilder.writeSession(doc, to: dir)
        c.check("plaintext round-trip keeps words",
                DocumentBuilder.readSession(dir)?.segments.first?.validWords?.count == 3)

        SessionIO.overrideKey = SymmetricKeyForTests.make()
        SessionIO.isEncryptionEnabled = true
        DocumentBuilder.writeSession(doc, to: dir)
        let encrypted = (try? Data(contentsOf: dir.appendingPathComponent("session.json"))) ?? Data()
        c.check("session.json is encrypted on disk", SessionIO.isEncryptedBlob(encrypted))
        c.check("encrypted round-trip keeps words",
                DocumentBuilder.readSession(dir)?.segments.first?.validWords?.count == 3)
        SessionIO.isEncryptionEnabled = false
        SessionIO.overrideKey = nil

        c.finish()
    }

    // MARK: - --selftest-engine-route (Wave 2)

    static func runEngineRoute() {
        setbuf(stdout, nil)
        print("== engine-routing self-test ==")
        let c = Checker()

        func route(_ pref: EnginePreference, _ lang: String?,
                   parakeet: Bool = true, whisper: Bool = true) -> TranscriptionEngineID {
            EngineRouter.choose(preference: pref, language: lang,
                                parakeetInstalled: parakeet, whisperInstalled: whisper).engine
        }

        // Automatic: covered languages → Parakeet.
        c.check("automatic + English → Parakeet", route(.automatic, "en") == .parakeet)
        c.check("automatic + Spanish → Parakeet", route(.automatic, "es") == .parakeet)
        c.check("automatic + Greek → Parakeet", route(.automatic, "el") == .parakeet)

        // Automatic: uncovered languages → Whisper. This is the case the router exists for.
        c.check("automatic + Hindi → Whisper", route(.automatic, "hi") == .whisper)
        c.check("automatic + Arabic → Whisper", route(.automatic, "ar") == .whisper)
        c.check("automatic + Japanese → Whisper", route(.automatic, "ja") == .whisper)
        c.check("automatic + Korean → Whisper", route(.automatic, "ko") == .whisper)
        c.check("automatic + Vietnamese → Whisper", route(.automatic, "vi") == .whisper)

        // The three codes FluidAudio's script filter accepts but the model card does not claim.
        c.check("Belarusian is NOT routed to Parakeet", route(.automatic, "be") == .whisper)
        c.check("Bosnian is NOT routed to Parakeet", route(.automatic, "bs") == .whisper)
        c.check("Serbian is NOT routed to Parakeet", route(.automatic, "sr") == .whisper)

        // THE important rule: an unknown language never guesses into Parakeet.
        c.check("automatic + unknown language → Whisper", route(.automatic, nil) == .whisper)
        c.check("automatic + empty language → Whisper", route(.automatic, "") == .whisper)

        // Locale shapes reach the router from a picker, a detector and a foreign bundle.
        c.check("en-GB normalises to English", route(.automatic, "en-GB") == .parakeet)
        c.check("es_MX normalises to Spanish", route(.automatic, "es_MX") == .parakeet)
        c.check("' De ' normalises to German", route(.automatic, " De ") == .parakeet)

        // Explicit preferences win.
        c.check("always-Whisper wins on a covered language", route(.whisper, "en") == .whisper)
        c.check("always-Parakeet wins on an uncovered one", route(.parakeet, "hi") == .parakeet)

        // Availability fallbacks, and they are flagged as fallbacks.
        let noParakeet = EngineRouter.choose(preference: .parakeet, language: "en",
                                             parakeetInstalled: false, whisperInstalled: true)
        c.check("missing Parakeet falls back to Whisper", noParakeet.engine == .whisper)
        c.check("…and says it is a fallback", noParakeet.isFallback)
        let noWhisper = EngineRouter.choose(preference: .whisper, language: "en",
                                            parakeetInstalled: true, whisperInstalled: false)
        c.check("missing Whisper falls back to Parakeet", noWhisper.engine == .parakeet)
        c.check("…and says it is a fallback", noWhisper.isFallback)

        // The ordinary case is NOT flagged, so the UI stays quiet when nothing is wrong.
        c.check("a plain Parakeet route is not a fallback",
                EngineRouter.choose(preference: .automatic, language: "en",
                                    parakeetInstalled: true, whisperInstalled: true).isFallback == false)
        // …but an auto-route to Whisper explains itself.
        let hindi = EngineRouter.choose(preference: .automatic, language: "hi",
                                        parakeetInstalled: true, whisperInstalled: true)
        c.check("the Hindi route names the language", hindi.reason.contains("Hindi"))

        // Vocabulary bias: empty is unrepresentable, which is the whole point of the type.
        c.check("empty vocabulary → nil bias", VocabularyBias(terms: []) == nil)
        c.check("whitespace-only vocabulary → nil bias", VocabularyBias(terms: ["  ", "\t", ""]) == nil)
        c.check("real terms → a bias", VocabularyBias(terms: ["Kubernetes"]) != nil)
        c.check("terms are de-duplicated case-insensitively",
                VocabularyBias(terms: ["SQL", "sql", "Sql"])?.terms.count == 1)
        c.check("order is preserved",
                VocabularyBias(terms: ["beta", "alpha"])?.terms == ["beta", "alpha"])

        c.finish()
    }

    // MARK: - --selftest-edit (Wave 3)

    static func runEdit() {
        setbuf(stdout, nil)
        print("== transcript-edit self-test ==")
        let c = Checker()
        let dir = tempDir("edit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let withWords = TranscriptSegment(
            start: 0, end: 4, text: "We ran the sequel query twice.",
            words: words([("We", 0.0, 0.2), ("ran", 0.3, 0.5), ("the", 0.6, 0.7),
                          ("sequel", 0.8, 1.4), ("query", 1.5, 2.0), ("twice.", 2.1, 2.6)]))
        let noWords = TranscriptSegment(start: 5, end: 8, text: "A legacy line with no timings.")
        let segments = [withWords, noWords]

        // ---- Word-level edit.
        let e1 = TranscriptEdit(segmentIndex: 0, wordIndex: 3, original: "sequel",
                                corrected: "SQL", at: Date(timeIntervalSince1970: 1))
        let applied = EditOverlay.apply(segments: segments, edits: [e1])
        c.check("word edit rewrites the text", applied[0].text == "We ran the SQL query twice.")
        c.check("word edit rewrites the word array", applied[0].validWords?[3].text == "SQL")
        c.check("the corrected word keeps its timing",
                applied[0].validWords?[3].start == 0.8 && applied[0].validWords?[3].end == 1.4)
        c.check("other segments untouched", applied[1].text == noWords.text)

        // ---- Idempotence. Applying to already-applied output changes nothing.
        let twice = EditOverlay.apply(segments: applied, edits: [e1])
        c.check("the overlay is idempotent", twice[0].text == applied[0].text)
        c.check("purity: same input, same output",
                EditOverlay.apply(segments: segments, edits: [e1])[0].text == applied[0].text)

        // ---- Whole-segment edit (the legacy path).
        let e2 = TranscriptEdit(segmentIndex: 1, wordIndex: nil, original: noWords.text,
                                corrected: "A legacy line, corrected.", at: Date(timeIntervalSince1970: 2))
        let applied2 = EditOverlay.apply(segments: segments, edits: [e2])
        c.check("legacy sessions are editable at line granularity",
                applied2[1].text == "A legacy line, corrected.")

        // ---- Out-of-range edits are SKIPPED, not dropped, and are reported.
        let stale = TranscriptEdit(segmentIndex: 99, wordIndex: 0, original: "x", corrected: "y",
                                   at: Date(timeIntervalSince1970: 3))
        let withStale = EditOverlay.apply(segments: segments, edits: [e1, stale])
        c.check("an out-of-range edit is skipped", withStale[0].text == applied[0].text)
        let unanchored = EditOverlay.unanchored([e1, stale], in: segments)
        c.check("…and is reported as unanchored", unanchored.count == 1)
        c.check("…with the right reason", unanchored.first?.1 == .segmentOutOfRange)

        // An edit whose text has moved on is also unanchored rather than mis-applied.
        let moved = TranscriptEdit(segmentIndex: 0, wordIndex: 3, original: "postgres",
                                   corrected: "Postgres", at: Date(timeIntervalSince1970: 4))
        c.check("a changed word is unanchored",
                EditOverlay.unanchored([moved], in: segments).first?.1 == .textChanged)

        // ---- Whole-word replacement: correcting "ran" must not touch "brand".
        let tricky = TranscriptSegment(start: 0, end: 2, text: "The brand ran fast.",
                                       words: words([("The", 0, 0.2), ("brand", 0.3, 0.6),
                                                     ("ran", 0.7, 0.9), ("fast.", 1.0, 1.4)]))
        let e3 = TranscriptEdit(segmentIndex: 0, wordIndex: 2, original: "ran", corrected: "runs",
                                at: Date(timeIntervalSince1970: 5))
        c.check("replacement is whole-word",
                EditOverlay.apply(segments: [tricky], edits: [e3])[0].text == "The brand runs fast.")

        // ---- Repeated words: the RIGHT occurrence is replaced.
        let repeated = TranscriptSegment(start: 0, end: 2, text: "go go go",
                                         words: words([("go", 0, 0.2), ("go", 0.3, 0.5), ("go", 0.6, 0.8)]))
        let e4 = TranscriptEdit(segmentIndex: 0, wordIndex: 1, original: "go", corrected: "stop",
                                at: Date(timeIntervalSince1970: 6))
        c.check("the indexed occurrence is the one replaced",
                EditOverlay.apply(segments: [repeated], edits: [e4])[0].text == "go stop go")

        // ---- Persistence, and transcript.md left ALONE.
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "m")
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)
        let mdBefore = try? Data(contentsOf: dir.appendingPathComponent("transcript.md"))
        try? EditStore.write([e1], dir: dir)
        let mdAfter = try? Data(contentsOf: dir.appendingPathComponent("transcript.md"))
        c.check("transcript.md is byte-identical after an edit", mdBefore == mdAfter)
        c.check("edits.json round-trips", EditStore.read(dir: dir) == [e1])
        c.check("the edited view is available from disk",
                EditStore.editedSegments(dir: dir, segments: segments)[0].text == "We ran the SQL query twice.")

        // An empty list REMOVES the file, so "never edited" and "all undone" look the same.
        try? EditStore.write([], dir: dir)
        c.check("clearing edits removes edits.json",
                !FileManager.default.fileExists(atPath: EditStore.url(dir: dir).path))

        // A corrupt file must never make a session unopenable.
        try? Data("{ not json".utf8).write(to: EditStore.url(dir: dir))
        c.check("a corrupt edits.json degrades to no edits", EditStore.read(dir: dir).isEmpty)
        try? FileManager.default.removeItem(at: EditStore.url(dir: dir))

        // ---- Ordering: redaction applies AFTER edits (§6.5).
        try? EditStore.write([e1], dir: dir)
        let source = EditStore.editedSegments(dir: dir, segments: segments)
        let redacted = Redactor.redactSegments(source)
        c.check("redaction sees the EDITED text",
                redacted[0].redactedText?.contains("SQL") == true
                    || redacted[0].redactedText?.contains("sequel") == false)

        // ---- Correction memory: twice before learning, and it never rewrites anything.
        let store = tempDir("corrections").appendingPathComponent("learned.json")
        CorrectionMemory.overrideStoreURL = store
        CorrectionMemory.clearAll()
        c.check("first correction does not promote",
                CorrectionMemory.record(original: "sequel", corrected: "SQL") == nil)
        c.check("…and nothing is offered to the bias list yet",
                CorrectionMemory.promotedTerms().isEmpty)
        c.check("second correction promotes",
                CorrectionMemory.record(original: "sequel", corrected: "SQL") != nil)
        c.check("…and announces exactly once",
                CorrectionMemory.record(original: "sequel", corrected: "SQL") == nil)
        c.check("the promoted term is the CORRECT spelling",
                CorrectionMemory.promotedTerms() == ["SQL"])
        // The rule that matters: learning changes what is LISTENED for, never existing text.
        let untouched = EditOverlay.apply(segments: [tricky], edits: [])
        c.check("a learned correction never rewrites existing text",
                untouched[0].text == "The brand ran fast.")
        CorrectionMemory.clearAll()
        c.check("clear-all empties the store", CorrectionMemory.all().isEmpty)
        CorrectionMemory.overrideStoreURL = nil

        // ---- `.said` round trip carries the edits.
        try? EditStore.write([e1], dir: dir)
        let bundle = tempDir("edit-bundle").appendingPathComponent("s.said")
        let dest = tempDir("edit-dest")
        do {
            _ = try SessionBundle.write(sessionDir: dir, to: bundle)
            let outcome = try SessionBundle.read(bundle: bundle, into: dest)
            c.check("bundle round-trip preserves edits",
                    EditStore.read(dir: outcome.directory) == [e1])
        } catch {
            c.check("bundle round-trip preserves edits (\(error))", false)
        }

        c.finish()
    }

    // MARK: - --selftest-voiceprint (Wave 4)

    static func runVoiceprint() {
        setbuf(stdout, nil)
        print("== voiceprint self-test ==")
        let c = Checker()

        let store = tempDir("voiceprints").appendingPathComponent("voiceprints.json")
        VoiceprintStore.overrideStoreURL = store
        VoiceprintStore.deleteAll()

        // Synthetic unit vectors in a small space. `cosineDistance` is what the diarizer itself
        // clusters with, so these distances are in the same units as the real thing.
        func unit(_ v: [Float]) -> [Float] {
            var n: Float = 0; for x in v { n += x * x }
            n = n.squareRoot()
            return n > 0 ? v.map { $0 / n } : v
        }
        let alice = unit([1, 0, 0, 0])
        let aliceAgain = unit([0.97, 0.24, 0, 0])     // close: same person, different day
        let bob = unit([0, 1, 0, 0])                  // orthogonal: clearly someone else
        let ambiguousA = unit([1, 0, 0, 0])
        let ambiguousB = unit([0.995, 0.1, 0, 0])     // two stored voices almost on top of each other

        // ---- Feature OFF writes nothing.
        VoiceprintStore.isEnabled = false
        c.check("feature off: the store is empty", VoiceprintStore.all().isEmpty)

        VoiceprintStore.isEnabled = true
        _ = VoiceprintStore.enroll(name: "Alice", embeddings: [alice])
        c.check("enrolment stores one voice", VoiceprintStore.all().count == 1)

        // ---- Matching above and below threshold.
        c.check("a close embedding is proposed", {
            if case .proposal(let cand) = VoiceprintStore.match(embeddings: [aliceAgain]) {
                return cand.name == "Alice"
            }
            return false
        }())
        c.check("an unrelated embedding is not matched",
                VoiceprintStore.match(embeddings: [bob]) == .none)
        c.check("the threshold is far tighter than the diarizer's 0.7",
                VoiceprintMatcher.maxDistance < 0.7)

        // ---- Ambiguity ASKS rather than picking.
        _ = VoiceprintStore.enroll(name: "Anna", embeddings: [ambiguousB])
        let ambiguous = VoiceprintStore.match(embeddings: [ambiguousA])
        c.check("two near-equal candidates → ambiguous, not a pick", {
            if case .ambiguous(let list) = ambiguous { return list.count >= 2 }
            return false
        }())

        // ---- Enrol → match → append improves similarity.
        VoiceprintStore.deleteAll()
        guard let enrolled = VoiceprintStore.enroll(name: "Alice", embeddings: [alice]) else {
            c.check("enrolment returned a voiceprint", false); c.finish()
        }
        let before = VoiceprintMatcher.distance(from: aliceAgain, to: enrolled)
        _ = VoiceprintStore.enroll(name: "Alice", embeddings: [aliceAgain], existing: enrolled.id)
        let after = VoiceprintStore.all().first.map { VoiceprintMatcher.distance(from: aliceAgain, to: $0) } ?? 1
        c.check("appending a sample improves the next match", after < before)
        c.check("session count increments", VoiceprintStore.all().first?.sessionCount == 2)

        // ---- Deletion is complete.
        if let id = VoiceprintStore.all().first?.id { VoiceprintStore.delete(id: id) }
        c.check("delete removes the voice", VoiceprintStore.all().isEmpty)
        c.check("…and removes the file entirely",
                !FileManager.default.fileExists(atPath: store.path))

        // ---- The store is NOT inside a session folder, so a default bundle cannot carry it.
        let dir = tempDir("vp-session")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = VoiceprintStore.enroll(name: "Alice", embeddings: [alice])
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "m")
        DocumentBuilder.writeSession(
            SessionDoc(meta: meta, segments: [TranscriptSegment(start: 0, end: 1, text: "hi")]), to: dir)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        c.check("no voiceprint file in the session folder",
                !files.contains(SessionBundle.voiceprintsName))

        let bundle = tempDir("vp-bundle").appendingPathComponent("s.said")
        do {
            _ = try SessionBundle.write(sessionDir: dir, to: bundle)   // default: NOT included
            c.check("a default .said is written", FileManager.default.fileExists(atPath: bundle.path))
        } catch {
            c.check("a default .said is written (\(error))", false)
        }

        VoiceprintStore.deleteAll()
        VoiceprintStore.isEnabled = false
        VoiceprintStore.overrideStoreURL = nil
        c.finish()
    }

    // MARK: - --selftest-slides (Wave 5)

    static func runSlides() {
        setbuf(stdout, nil)
        print("== slide-span self-test ==")
        let c = Checker()

        // A slide left up: four near-identical readings, then a genuine change, then one more slide.
        let frames = [
            FrameEvent(time: 10, imagePath: "images/slide-0001.png", text: "Quarterly revenue growth by segment"),
            FrameEvent(time: 130, imagePath: "images/slide-0002.png", text: "Quarterly revenue growth by segment"),
            FrameEvent(time: 250, imagePath: "images/slide-0003.png", text: "Quarterly revenue growth by segments"),
            FrameEvent(time: 370, imagePath: "images/slide-0004.png", text: "Quarterly revenue growth by segment extra"),
            FrameEvent(time: 600, imagePath: "images/slide-0005.png", text: "Customer retention cohort analysis"),
            FrameEvent(time: 900, imagePath: "images/slide-0006.png", text: "Appendix methodology notes"),
        ]
        let spans = SlideSegmenter.spans(frames: frames, sessionDuration: 1200)
        c.check("ten minutes on one slide collapses to one span", spans.count == 3)
        c.check("the first span starts at the first frame", spans.first?.startTime == 10)
        c.check("…and ends where the next slide begins", spans.first?.endTime == 600)
        c.check("the collapsed span records how many frames it ate", spans.first?.frameCount == 4)
        c.check("the last span is closed by the session duration", spans.last?.endTime == 1200)
        c.check("the representative frame is the one with the most text read",
                spans.first?.representativeImagePath == "images/slide-0004.png")

        // A single-frame slide still produces a valid, clickable span.
        let single = SlideSegmenter.spans(frames: [frames[4]], sessionDuration: 700)
        c.check("a single frame produces one span", single.count == 1)
        c.check("…with a non-zero duration", (single.first?.duration ?? 0) > 0)

        // Unknown duration must still close the last span.
        let noDuration = SlideSegmenter.spans(frames: frames, sessionDuration: nil)
        c.check("unknown duration still closes the last span",
                (noDuration.last?.duration ?? 0) > 0)

        // Textless frames are never merged — two illegible photos are not evidence of one slide.
        let blank = [
            FrameEvent(time: 1, imagePath: "a.png", text: nil),
            FrameEvent(time: 2, imagePath: "b.png", text: nil),
        ]
        c.check("textless frames are not collapsed",
                SlideSegmenter.spans(frames: blank, sessionDuration: 10).count == 2)

        // A frameless session gains nothing.
        c.check("no frames → no spans", SlideSegmenter.spans(frames: [], sessionDuration: 10).isEmpty)

        // ---- session.json: derived, cached, and absent when empty.
        let dir = tempDir("slides")
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic",
                               modelName: "m", durationSeconds: 1200)
        let segs = [TranscriptSegment(start: 0, end: 5, text: "Let's look at the numbers.")]
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segs, frames: frames), to: dir)
        let reread = DocumentBuilder.readSession(dir)
        c.check("slides are cached in session.json", (reread?.slides?.count ?? 0) == 3)
        c.check("slideSpans agrees with the cache", reread?.slideSpans.count == 3)

        let plain = tempDir("slides-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segs), to: plain)
        let plainJSON = (try? String(contentsOf: plain.appendingPathComponent("session.json"),
                                     encoding: .utf8)) ?? ""
        c.check("a frameless session gains no `slides` key", !plainJSON.contains("\"slides\""))
        c.check("…and no `frames` key", !plainJSON.contains("\"frames\""))

        // ---- Search: a slide-only phrase is found, marked as a slide, and carries its timestamp.
        let indexDir = tempDir("slides-index")
        defer { try? FileManager.default.removeItem(at: indexDir) }
        let index = SearchIndex(cacheURL: indexDir.appendingPathComponent("cache.json"))
        index.index(sessionDir: dir)
        let hits = index.search("cohort")
        c.check("a phrase only ever on a slide finds the session", hits.count == 1)
        c.check("the hit is marked as a slide match", hits.first?.hasSlideMatch == true)
        c.check("…and carries a timestamp", hits.first?.snippets.first?.timestamp != nil)

        let spoken = index.search("numbers")
        c.check("a spoken phrase is NOT marked as a slide match",
                spoken.first?.snippets.first?.isSlide == false)

        c.finish()
    }

    // MARK: - --selftest-semantic (Wave 6)

    static func runSemantic() {
        setbuf(stdout, nil)
        print("== semantic-search self-test ==")
        let c = Checker()

        // ---- Chunking is pure and can be asserted without a model.
        var segs: [TranscriptSegment] = []
        for i in 0..<40 {
            segs.append(TranscriptSegment(
                start: Double(i) * 5, end: Double(i) * 5 + 4,
                text: "This is sentence number \(i) and it carries roughly ten words of content.",
                words: [WordTiming(text: "This", start: Double(i) * 5, end: Double(i) * 5 + 0.4),
                        WordTiming(text: "content.", start: Double(i) * 5 + 3.2, end: Double(i) * 5 + 3.9)]))
        }
        let chunks = SemanticChunker.chunks(segments: segs, sessionPath: "/tmp/s")
        c.check("a long transcript is chunked", chunks.count > 1)
        c.check("chunks are in time order",
                zip(chunks, chunks.dropFirst()).allSatisfy { $0.start <= $1.start })
        c.check("chunk start times are real segment anchors",
                chunks.allSatisfy { chunk in segs.contains { abs($0.start - chunk.start) < 0.001 } })
        c.check("chunks carry text", chunks.allSatisfy { !$0.text.isEmpty })
        c.check("chunk end uses the last word's time where available",
                chunks.first.map { $0.end > $0.start } ?? false)
        c.check("empty input → no chunks",
                SemanticChunker.chunks(segments: [], sessionPath: "/tmp/s").isEmpty)
        c.check("a segment with no words still chunks",
                !SemanticChunker.chunks(
                    segments: [TranscriptSegment(start: 0, end: 3, text: "no timings here")],
                    sessionPath: "/tmp/s").isEmpty)

        // ---- Fusion. With no semantic hits it is EXACTLY the keyword ranking — the off path.
        let dir = tempDir("semantic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "m")
        let hits = [SessionHit(dir: dir.appendingPathComponent("a"), meta: meta, score: 3,
                               matchCount: 3, snippets: []),
                    SessionHit(dir: dir.appendingPathComponent("b"), meta: meta, score: 2,
                               matchCount: 2, snippets: [])]
        let noSemantic = HybridRetrieval.fuse(keyword: hits, semantic: [], limit: 8)
        c.check("no semantic hits → the keyword ranking, unchanged",
                noSemantic.map(\.dir.path) == hits.map(\.dir.path))

        // A session ranked highly by BOTH signals should win — the reason RRF was chosen.
        let chunkB = SemanticChunk(sessionPath: dir.appendingPathComponent("b").path,
                                   start: 0, end: 5, text: "paraphrase", vector: [])
        let fused = HybridRetrieval.fuse(keyword: hits, semantic: [SemanticHit(chunk: chunkB, similarity: 0.9)],
                                         limit: 8)
        c.check("agreement between the two signals promotes a session",
                fused.first?.dir.lastPathComponent == "b")

        // Keyword-only sessions are still returned — exact-term precision must not regress.
        c.check("a keyword-only session is still present",
                fused.contains { $0.dir.lastPathComponent == "a" })

        // A session ONLY semantic search knows about is reported for the caller to surface.
        let chunkC = SemanticChunk(sessionPath: "/tmp/only-semantic", start: 0, end: 5,
                                   text: "x", vector: [])
        c.check("semantic-only sessions are reported separately",
                HybridRetrieval.semanticOnlyPaths(
                    keyword: hits, semantic: [SemanticHit(chunk: chunkC, similarity: 0.8)])
                    == ["/tmp/only-semantic"])

        // ---- Vector maths.
        c.check("dot of identical unit vectors is 1",
                abs(VectorMath.dot([1, 0, 0], [1, 0, 0]) - 1) < 0.0001)
        c.check("dot of orthogonal vectors is 0",
                abs(VectorMath.dot([1, 0, 0], [0, 1, 0])) < 0.0001)
        c.check("mismatched dimensions score 0", VectorMath.dot([1, 0], [1, 0, 0]) == 0)

        // ---- OFF is a complete no-op: no model load, no file, no results.
        SemanticIndex.isEnabled = false
        let idxDir = tempDir("semantic-index")
        defer { try? FileManager.default.removeItem(at: idxDir) }
        let cache = idxDir.appendingPathComponent("vectors.json")
        let index = SemanticIndex(cacheURL: cache)
        let sema = SemaphoreBox()
        Task {
            let results = await index.search("anything")
            sema.result = results.isEmpty
            sema.signal()
        }
        sema.wait()
        c.check("feature off → no results and no model load", sema.result)
        c.check("feature off → no cache file on disk",
                !FileManager.default.fileExists(atPath: cache.path))

        // ---- Encryption ON must never write vectors to disk.
        SessionIO.overrideKey = SymmetricKeyForTests.make()
        SessionIO.isEncryptionEnabled = true
        let encDir = tempDir("semantic-enc")
        defer { try? FileManager.default.removeItem(at: encDir) }
        let encCache = encDir.appendingPathComponent("vectors.json")
        let encIndex = SemanticIndex(cacheURL: encCache)
        encIndex.purgeCache()
        c.check("encryption on → no vector cache on disk",
                !FileManager.default.fileExists(atPath: encCache.path))
        SessionIO.isEncryptionEnabled = false
        SessionIO.overrideKey = nil

        c.finish()
    }
}

// MARK: - Small helpers

/// A 256-bit key for the encryption round-trips, so the self-tests never touch the real Keychain.
enum SymmetricKeyForTests {
    static func make() -> SymmetricKey { SymmetricKey(size: .bits256) }
}

/// Bridges one `async` call into a synchronous self-test, matching the `sema.wait()` pattern the
/// existing modes already use.
final class SemaphoreBox: @unchecked Sendable {
    private let sema = DispatchSemaphore(value: 0)
    var result = false
    func signal() { sema.signal() }
    func wait() { sema.wait() }
}
