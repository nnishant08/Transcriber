import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Template registry (always available — references no macOS-26 types)

/// UI grouping for the Generation Studio template picker.
public enum GenerationGroup: String, CaseIterable, Sendable {
    case summary = "Summary"
    case meetingWork = "Meeting & work"
    case clinical = "Clinical"
    case interview = "Interview"
    case study = "Study"
    case creator = "Creator"
    case custom = "Custom"
}

/// Selects the output shape + renderer for a template. Built-in summary styles and Stage-1 custom
/// modes are unified into the Studio as kinds that delegate to the existing `Intelligence` string
/// path (so their output stays byte-identical); the rest are `@Generable` structured generators.
enum GenerationKind: Hashable, Sendable {
    case summaryStyle(SummaryStyle)     // unifies TL;DR / Detailed / Executive (Intelligence.summarize)
    case customMode                     // unifies Stage-1 custom modes (Intelligence.summarizeCustom)
    // Structured (`@Generable`) generators:
    case minutes, decisionLog, qa, objections
    case soap, dap
    case interview
    case flashcards, quiz, studyGuide
    case showNotes, titles, social, blog, emailRecap
}

/// One Studio template: an id (also its cache key), a display name + group, the kind that selects
/// its generation path, and — for `.customMode` — the user's free-form instructions.
public struct GenerationTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let group: GenerationGroup
    let kind: GenerationKind
    var instructions: String = ""       // used only for `.customMode`

    /// The session.json cache bucket: built-in styles / custom modes ride `meta.summaries` (so the
    /// classic Summary panel and the Studio share one cache, byte-identical to before); structured
    /// generators ride `meta.generatedArtifacts`.
    public var usesSummaryCache: Bool {
        switch kind { case .summaryStyle, .customMode: return true; default: return false }
    }
    /// Cache key inside whichever bucket. Built-ins keep their raw values; customs are namespaced.
    public var cacheKey: String {
        switch kind {
        case .summaryStyle(let s): return s.rawValue
        case .customMode: return "custom:\(name)"
        default: return id
        }
    }
}

/// The rendered result of one generation run.
public struct GenerationOutput: Sendable {
    public var text: String            // human-readable rendering (display / copy / share / export)
    public var format: String          // "text" or "json"
    public var json: String?           // structured JSON (flashcards / quiz) for CSV / Markdown export
}

// MARK: - Portable export DTOs (decoupled from the @Generable types, so caching + CSV are stable)

struct FlashcardDTO: Codable, Sendable, Hashable { var front: String; var back: String }
struct QuizItemDTO: Codable, Sendable, Hashable {
    var question: String; var choices: [String]; var answerIndex: Int; var explanation: String
}

// MARK: - Generation Studio service

/// Unified, templated structured-generation over a session's transcript (already
/// embedded in the timestamped transcript). 100% on-device via FoundationModels guided generation
/// (`@Generable`, macOS 26), behind the same availability guard as `Summarizer`. Outputs are cached
/// in `session.json` and re-run on demand. Nothing here mutates `transcript.md`.
public enum GenerationStudio {

    public static var isAvailable: Bool { Summarizer.isAvailable }
    public static func availabilityMessage() -> String? { Summarizer.availabilityMessage() }

    // MARK: Built-in registry

    /// The shipped built-in templates (excludes user custom modes, which are appended at the call site).
    public static let builtins: [GenerationTemplate] = [
        // Summary (unified Stage-0 styles)
        GenerationTemplate(id: "summary.tldr", name: "TL;DR", group: .summary, kind: .summaryStyle(.tldr)),
        GenerationTemplate(id: "summary.detailed", name: "Detailed notes", group: .summary, kind: .summaryStyle(.detailed)),
        GenerationTemplate(id: "summary.executive", name: "Executive", group: .summary, kind: .summaryStyle(.executive)),
        // Meeting & work
        GenerationTemplate(id: "minutes", name: "Meeting minutes", group: .meetingWork, kind: .minutes),
        GenerationTemplate(id: "decisions", name: "Decision log", group: .meetingWork, kind: .decisionLog),
        GenerationTemplate(id: "qa", name: "Q&A extraction", group: .meetingWork, kind: .qa),
        GenerationTemplate(id: "objections", name: "Sales objection log", group: .meetingWork, kind: .objections),
        // Clinical (draft only — clearly labeled in the rendered output; surfaced by the Medical pack)
        GenerationTemplate(id: "soap", name: "SOAP note (draft)", group: .clinical, kind: .soap),
        GenerationTemplate(id: "dap", name: "DAP note (draft)", group: .clinical, kind: .dap),
        // Interview
        GenerationTemplate(id: "interview", name: "Interview report", group: .interview, kind: .interview),
        // Study
        GenerationTemplate(id: "flashcards", name: "Flashcards", group: .study, kind: .flashcards),
        GenerationTemplate(id: "quiz", name: "Quiz", group: .study, kind: .quiz),
        GenerationTemplate(id: "studyguide", name: "Study guide", group: .study, kind: .studyGuide),
        // Creator
        GenerationTemplate(id: "shownotes", name: "Show notes", group: .creator, kind: .showNotes),
        GenerationTemplate(id: "titles", name: "Episode titles", group: .creator, kind: .titles),
        GenerationTemplate(id: "social", name: "Social posts", group: .creator, kind: .social),
        GenerationTemplate(id: "blog", name: "Blog / newsletter draft", group: .creator, kind: .blog),
        GenerationTemplate(id: "email", name: "Email recap", group: .creator, kind: .emailRecap),
    ]

    /// Full template list = built-ins + the user's custom summary modes (Feature D2 / Stage 1),
    /// so "one Studio, two sources" as specified.
    public static func allTemplates(customModes: [CustomSummaryMode]) -> [GenerationTemplate] {
        builtins + customModes.map {
            GenerationTemplate(id: "custom:\($0.name)", name: $0.name, group: .custom,
                               kind: .customMode, instructions: $0.instructions)
        }
    }

    public static func template(id: String, customModes: [CustomSummaryMode] = []) -> GenerationTemplate? {
        allTemplates(customModes: customModes).first { $0.id == id }
    }

    // MARK: Grounding preamble

    /// Shared grounding rules prepended to every structured generator's instructions: stay on the
    /// transcript, cite `[mm:ss]`, never invent. (Mirrors `Intelligence`'s chat/ask grounding.)
    private static let grounding = """
        You work ONLY from the provided transcript (each line is prefixed with its [mm:ss] \
        timestamp). Do not invent facts, names, numbers, or \
        outcomes not present in the transcript. When a field should reference a moment, use an \
        [mm:ss] timestamp that actually appears in the transcript. Be concise and faithful.
        """

    /// Clip overly long transcripts to the on-device context window (logged, not silent).
    private static func clip(_ text: String, max: Int = 9000) -> String {
        if text.count <= max { return text }
        NSLog("[Studio] transcript clipped to \(max) chars (was \(text.count)) for generation")
        return String(text.prefix(max))
    }

    // MARK: Run

    /// Generate `template` over `sourceText` (a timestamped transcript). Throws `SummaryError` when
    /// Apple Intelligence is unavailable or the input is empty, so callers can show the reason and
    /// cache only on success.
    public static func generate(template: GenerationTemplate, sourceText: String) async throws -> GenerationOutput {
        let base = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, SessionStore.meaningfulWordCount(base) >= 3 else { throw SummaryError.emptyTranscript }
        let text = clip(base)

        switch template.kind {
        case .summaryStyle(let style):
            // Delegate to the existing path so output stays byte-identical to the classic Summary panel.
            let out = try await Intelligence.summarize(transcript: SessionStore.plainText(fromMarkdown: text), style: style)
            return GenerationOutput(text: out, format: "text", json: nil)
        case .customMode:
            let mode = CustomSummaryMode(name: template.name, instructions: template.instructions)
            let out = try await Intelligence.summarizeCustom(transcript: SessionStore.plainText(fromMarkdown: text), mode: mode)
            return GenerationOutput(text: out, format: "text", json: nil)
        default:
            return try await generateStructured(kind: template.kind, transcript: text)
        }
    }

    // MARK: Structured generators (macOS 26 guided generation)

    private static func generateStructured(kind: GenerationKind, transcript: String) async throws -> GenerationOutput {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: break
            case .unavailable: throw SummaryError.unavailable(availabilityMessage() ?? "On-device model unavailable.")
            }
            return try await StructuredGen.run(kind: kind, transcript: transcript, grounding: grounding)
        }
        #endif
        throw SummaryError.needsMacOS26
    }

    // MARK: Portable exports (Anki-friendly CSV + Markdown) from a cached artifact

    /// Decode cached flashcards JSON → CSV (front,back per line) for Anki import.
    public static func flashcardsCSV(fromJSON json: String) -> String? {
        guard let cards = decode([FlashcardDTO].self, json) else { return nil }
        var out = ""
        for c in cards { out += csvField(c.front) + "," + csvField(c.back) + "\n" }
        return out
    }
    static func flashcardsMarkdown(fromJSON json: String) -> String? {
        guard let cards = decode([FlashcardDTO].self, json) else { return nil }
        return cards.map { "**Q:** \($0.front)\n\n**A:** \($0.back)" }.joined(separator: "\n\n---\n\n")
    }
    public static func quizCSV(fromJSON json: String) -> String? {
        guard let items = decode([QuizItemDTO].self, json) else { return nil }
        var out = "question,choices,answer,explanation\n"
        for q in items {
            let choices = q.choices.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " | ")
            let answer = q.choices.indices.contains(q.answerIndex) ? q.choices[q.answerIndex] : ""
            out += [q.question, choices, answer, q.explanation].map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: Display rendering (pure — usable to re-render cached JSON even when AI is unavailable)

    /// The human-readable text to show for a cached artifact: stored text as-is, or re-rendered from
    /// the structured JSON for flashcards/quiz.
    public static func displayText(_ art: GeneratedArtifact) -> String {
        guard art.format == "json" else { return art.content }
        switch art.templateId {
        case "flashcards": return flashcardsDisplay(fromJSON: art.content) ?? art.content
        case "quiz": return quizDisplay(fromJSON: art.content) ?? art.content
        default: return art.content
        }
    }

    static func flashcardsDisplay(fromJSON json: String) -> String? {
        guard let cards = decode([FlashcardDTO].self, json) else { return nil }
        guard !cards.isEmpty else { return "No flashcards generated." }
        return "# Flashcards (\(cards.count))\n\n" + cards.enumerated()
            .map { "**\($0.offset + 1). \($0.element.front)**\n\($0.element.back)" }
            .joined(separator: "\n\n")
    }
    static func quizDisplay(fromJSON json: String) -> String? {
        guard let items = decode([QuizItemDTO].self, json) else { return nil }
        guard !items.isEmpty else { return "No quiz questions generated." }
        return "# Quiz (\(items.count))\n\n" + items.enumerated().map { i, q in
            var out = "**\(i + 1). \(q.question)**\n"
            for (j, c) in q.choices.enumerated() {
                let mark = j == q.answerIndex ? "✓ " : "  "
                let letter = Character(UnicodeScalar(65 + min(25, max(0, j)))!)
                out += "\(mark)\(letter). \(c)\n"
            }
            if !q.explanation.isEmpty { out += "_\(q.explanation)_\n" }
            return out
        }.joined(separator: "\n")
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func csvField(_ s: String) -> String {
        let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n")
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuote ? "\"\(escaped)\"" : escaped
    }
}
