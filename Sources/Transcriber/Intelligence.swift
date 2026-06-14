import Foundation
import CoreGraphics
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Summary styles

enum SummaryStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case tldr, detailed, executive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tldr: return "TL;DR"
        case .detailed: return "Detailed notes"
        case .executive: return "Executive"
        }
    }
    var instruction: String {
        switch self {
        case .tldr:
            return "Produce a 1–2 sentence TL;DR, then 3–5 short bullet points of the key takeaways."
        case .detailed:
            return "Produce a thorough set of notes: a 2–3 sentence overview, then 5–9 detailed bullet points covering topics, decisions, and specifics. Stay faithful to the transcript."
        case .executive:
            return "Produce an executive briefing: a 1-sentence bottom-line, then 3–5 bullets focused on decisions, outcomes, risks, and next steps."
        }
    }
}

// MARK: - Chat / Ask result types

struct ChatTurn: Sendable, Identifiable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

struct AskResult: Sendable {
    var text: String
    var sources: [SessionHit]
    var available: Bool
}

// MARK: - On-device intelligence (chat, cross-session ask, styled summaries / action items / chapters)

/// All flows are 100% on-device via Apple FoundationModels (text-only — see decision #2; image input
/// is absent in the macOS 26 SDK and is gated behind `#available(macOS 27)` at the (currently inert)
/// attach site). Everything reuses `Summarizer`'s availability checks and degrades to a clear,
/// non-crashing fallback string when Apple Intelligence is unavailable.
enum Intelligence {
    static var isAvailable: Bool { Summarizer.isAvailable }
    static func availabilityMessage() -> String? { Summarizer.availabilityMessage() }

    // MARK: A1 — chat with one session (grounded, cites [mm:ss])

    /// Answer a question grounded in ONE session's transcript + OCR text. Builds context from the
    /// whole timestamped transcript when it fits, else retrieves relevant passages via `SearchIndex`.
    /// The answer is instructed to cite `[mm:ss]`; the Viewer makes those citations clickable.
    static func answerForSession(dir: URL, question: String, history: [ChatTurn]) async -> String {
        let context = groundingContext(dir: dir, question: question)
        guard !context.isEmpty else { return "There's no transcript text to answer from yet." }

        let instructions = """
            You answer questions about a single transcribed session. Use ONLY the provided transcript \
            excerpts (each line is prefixed with its [mm:ss] timestamp; lines marked (slide) are OCR'd \
            on-screen text). When you state a fact, cite the supporting [mm:ss] in your answer. If the \
            transcript doesn't contain the answer, say so plainly — do not invent details. Be concise.
            """
        var prompt = "TRANSCRIPT EXCERPTS:\n\(context)\n\n"
        if !history.isEmpty {
            prompt += "EARLIER IN THIS CHAT:\n"
            for t in history.suffix(6) {
                prompt += (t.role == .user ? "Q: " : "A: ") + t.text + "\n"
            }
            prompt += "\n"
        }
        prompt += "QUESTION: \(question)"

        // Feature D — Multimodal Slide Chat (macOS 27). When the session has slides and the model can
        // accept image input, attach the relevant slide image(s) so the model can reason over the
        // diagram/chart itself, not just OCR text. The image symbols exist only in the macOS 27 SDK,
        // so the call is double-gated: compiled only with the 27 SDK (TRANSCRIBER_MACOS27) AND run
        // only on a macOS 27 runtime (#available). On macOS 26 this whole block is absent and the
        // text+OCR path below is used verbatim — byte-for-byte the current behavior.
        #if TRANSCRIBER_MACOS27
        if #available(macOS 27, *) {
            let frames = DocumentBuilder.readSession(dir)?.frames ?? []
            let slides = SlideChat.selectSlides(frames: frames, question: question)
            if !slides.isEmpty {
                if let answer = try? await answerWithSlides(dir: dir, slides: slides,
                                                            instructions: instructions, prompt: prompt) {
                    return answer
                }
                // Image attach failed / too many images → fall through to text+OCR for this turn.
                NSLog("[SlideChat] image path unavailable for this turn — using text+OCR fallback")
            }
        }
        #endif

        do {
            return try await run(instructions: instructions, prompt: prompt, temperature: 0.2, maxTokens: 700)
        } catch {
            return fallbackMessage(for: error)
        }
    }

    #if TRANSCRIBER_MACOS27
    /// macOS 27 image-input call. VERIFY against the macOS 27 SDK: the exact image value type accepted
    /// inside `Prompt { }` (it wraps a CGImage / image source), how multiple images are passed, and any
    /// per-prompt image-count/size limits (`SlideChat.maxImages` is a conservative default). Pass the
    /// slide image(s) + the existing transcript/OCR grounding; keep answers citing [mm:ss].
    @available(macOS 27, *)
    private static func answerWithSlides(dir: URL, slides: [FrameEvent],
                                         instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 700)
        // Load slide PNGs (decrypting via SessionIO when encryption is on).
        let images: [CGImage] = slides.compactMap { frame in
            guard let data = try? SessionIO.readData(dir.appendingPathComponent(frame.imagePath)),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return img
        }
        let response = try await session.respond(options: options) {
            prompt
            "Relevant slide image(s) follow — reason over the visual content, not just the OCR text:"
            for img in images {
                // The macOS 27 SDK exposes an image value usable inside the PromptBuilder. Adjust the
                // wrapper type here once verified at the SDK (e.g. `Image(cgImage:)` / image content).
                Image(cgImage: img)
            }
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    // MARK: A2 — ask across all sessions (links back to source sessions)

    /// Retrieve over the whole corpus via `SearchIndex`, feed the top hits to the model, and answer
    /// with references back to the source sessions (+ their [mm:ss]). The `sources` are returned so
    /// the Library can render clickable links even if FM is unavailable.
    static func ask(question: String, index: SearchIndex) async -> AskResult {
        let hits = Array(index.search(question).prefix(6))
        guard !hits.isEmpty else {
            return AskResult(text: "Nothing in your sessions matched that. Try different keywords.",
                             sources: [], available: isAvailable)
        }
        guard isAvailable else {
            // Graceful fallback: no model → still surface the retrieved sources as links.
            return AskResult(text: "Apple Intelligence is unavailable, so here are the sessions that mention this:",
                             sources: hits, available: false)
        }

        var context = ""
        for (i, h) in hits.enumerated() {
            context += "SOURCE \(i + 1) — \"\(h.title)\":\n"
            for s in h.snippets.prefix(3) {
                context += "  [\(s.timestamp ?? "--:--")] \(s.text)\n"
            }
            context += "\n"
        }
        let instructions = """
            You answer a question using excerpts retrieved from several recorded sessions. Each SOURCE \
            is a different session. Synthesize an answer from the excerpts only; do not invent details. \
            When you use a source, refer to it by its title and cite the [mm:ss]. If the excerpts don't \
            answer the question, say so. Be concise.
            """
        let prompt = "RETRIEVED EXCERPTS:\n\(context)\nQUESTION: \(question)"
        do {
            let text = try await run(instructions: instructions, prompt: prompt, temperature: 0.2, maxTokens: 700)
            return AskResult(text: text, sources: hits, available: true)
        } catch {
            return AskResult(text: fallbackMessage(for: error), sources: hits, available: false)
        }
    }

    // MARK: A3 — styled summaries / action items / chapters

    /// Styled summary (TL;DR / detailed / executive). Throws on unavailability so callers can show the
    /// reason (the Viewer caches a successful result in session.json).
    static func summarize(transcript: String, style: SummaryStyle) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.emptyTranscript }
        let instructions = """
            You summarize spoken-word transcripts. \(style.instruction) Use plain text with simple \
            bullet lines (start each bullet with "- "). Stay faithful to the transcript; do not invent.
            """
        return try await run(instructions: instructions, prompt: "Transcript:\n\n\(String(text.prefix(9000)))",
                             temperature: 0.3, maxTokens: 800)
    }

    /// User-authored custom summary mode (Feature D2). Same contract as `summarize(transcript:style:)`
    /// — throws on unavailability so the Viewer can show the reason and cache successes. An
    /// empty/blank template is rejected up front (no model call — the documented no-op).
    static func summarizeCustom(transcript: String, mode: CustomSummaryMode) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.emptyTranscript }
        let template = mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw SummaryError.emptyTemplate }
        let instructions = """
            You produce a written digest of a spoken-word transcript, following the user's template \
            instructions exactly. Stay faithful to the transcript; do not invent details. Use plain \
            text with simple "- " bullet lines where lists are needed.
            USER TEMPLATE "\(mode.name)": \(template)
            """
        return try await run(instructions: instructions, prompt: "Transcript:\n\n\(String(text.prefix(9000)))",
                             temperature: 0.3, maxTokens: 900)
    }

    /// Auto-extract action items as a bullet list (empty when none / unavailable — never throws).
    static func actionItems(transcript: String) async -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isAvailable else { return [] }
        let instructions = """
            Extract concrete action items (tasks, follow-ups, commitments) from the transcript. Output \
            ONLY a list, one action per line starting with "- ". Include an owner in parentheses when \
            stated. If there are none, output exactly "NONE". Do not invent tasks.
            """
        do {
            let out = try await run(instructions: instructions, prompt: "Transcript:\n\n\(String(text.prefix(9000)))",
                                    temperature: 0.2, maxTokens: 500)
            if out.uppercased().contains("NONE") && out.count < 12 { return [] }
            return out.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { line -> String in
                    var l = line
                    while let f = l.first, "-*•–‣◦ \t".contains(f) { l.removeFirst() }
                    l = l.trimmingCharacters(in: .whitespaces)
                    // The model sometimes appends "(none)" when no owner was stated — drop it.
                    if l.lowercased().hasSuffix("(none)") { l = String(l.dropLast(6)).trimmingCharacters(in: .whitespaces) }
                    return l
                }
                .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
        } catch {
            return []
        }
    }

    /// Topic chapters with start times, parsed from the timestamped transcript. Empty when
    /// unavailable / no timestamps. Each chapter carries a `start` (seconds from T0).
    static func chapters(timestamped: String) async -> [Chapter] {
        let text = timestamped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isAvailable else { return [] }
        // No timestamps in the body (e.g. legacy session) → chapters can't anchor; skip cleanly.
        guard text.contains("["), SessionStore.firstTimestamp(in: text) != nil else { return [] }
        let instructions = """
            Divide this timestamped transcript into 3–8 topic chapters. Output ONLY lines of the form \
            "mm:ss — Chapter title", using a start timestamp that appears in the transcript, in \
            increasing time order. No other text.
            """
        do {
            let out = try await run(instructions: instructions, prompt: text, temperature: 0.2, maxTokens: 400)
            return parseChapters(out)
        } catch {
            return []
        }
    }

    static func parseChapters(_ raw: String) -> [Chapter] {
        var chapters: [Chapter] = []
        for line in raw.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "-*•–‣◦ \t".contains(f) { l.removeFirst() }
            guard let ts = SessionStore.firstTimestamp(in: l) else { continue }
            // Strip the leading timestamp + a separator (— / - / :) to get the title.
            guard let r = l.range(of: ts) else { continue }
            var title = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            while let f = title.first, "—-–:•| \t".contains(f) { title.removeFirst() }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            chapters.append(Chapter(start: secondsFromTimestamp(ts), title: String(title.prefix(80))))
        }
        // Keep monotonic, de-duplicated by start.
        var seen = Set<Int>()
        return chapters.sorted { $0.start < $1.start }.filter { seen.insert(Int($0.start)).inserted }
    }

    /// "mm:ss" or "h:mm:ss" → seconds.
    static func secondsFromTimestamp(_ ts: String) -> TimeInterval {
        let parts = ts.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return 0
        }
    }

    // MARK: - Internal

    /// Build the grounding context for per-session chat: the whole timestamped transcript when it
    /// fits, else the passages most relevant to the question (retrieved via SearchIndex over this one
    /// session), with a head-of-transcript fallback when the query has no keyword hits.
    private static func groundingContext(dir: URL, question: String) -> String {
        let full = SessionStore.timestampedTranscript(dir: dir, maxChars: 100_000)
        if full.count <= 8_000 { return full }
        let terms = SearchIndex.tokenize(question)
        let passages = SearchIndex.extractSnippets(dir: dir, terms: terms, limit: 18)
        if passages.isEmpty { return String(full.prefix(8_000)) }
        return passages.map { "[\($0.timestamp ?? "--:--")] \($0.text)" }.joined(separator: "\n")
    }

    private static func fallbackMessage(for error: Error) -> String {
        if let le = error as? LocalizedError, let d = le.errorDescription { return "⚠︎ " + d }
        return "⚠︎ " + (availabilityMessage() ?? error.localizedDescription)
    }

    /// Single on-device FoundationModels call (text-only). Mirrors `Summarizer`'s availability guard.
    static func run(instructions: String, prompt: String, temperature: Double = 0.3, maxTokens: Int? = nil) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: break
            case .unavailable:
                throw SummaryError.unavailable(availabilityMessage() ?? "On-device model unavailable.")
            }
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw SummaryError.needsMacOS26
    }
}
