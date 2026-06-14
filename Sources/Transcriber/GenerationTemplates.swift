import Foundation
#if canImport(FoundationModels)
import FoundationModels

// MARK: - @Generable output types (macOS 26 guided generation)
//
// All gated `@available(macOS 26.0, *)` because `@Generable` conforms the type to
// `FoundationModels.Generable`, which is itself macOS-26-only (the app's deployment floor is 14).
// Fields are non-optional with empty-string sentinels for "not stated" — sidesteps any Optional
// Generable-conformance subtlety and renders cleanly. Each carries a `render()` for display text.

@available(macOS 26.0, *)
@Generable
struct GenActionItem {
    @Guide(description: "The task, follow-up, or commitment") var task: String
    @Guide(description: "The owner if one was named, otherwise an empty string") var owner: String
    @Guide(description: "An [mm:ss] timestamp from the transcript if relevant, otherwise an empty string") var timestamp: String
}

@available(macOS 26.0, *)
@Generable
struct GenMeetingMinutes {
    @Guide(description: "A short descriptive title for the meeting") var title: String
    @Guide(description: "A 3–6 sentence executive overview of the meeting") var overview: String
    @Guide(description: "The concrete decisions that were made") var decisions: [String]
    @Guide(description: "Action items, each with owner and [mm:ss] when stated") var actionItems: [GenActionItem]

    func render() -> String {
        var out = "# \(title)\n\n## Overview\n\(overview)\n"
        if !decisions.isEmpty { out += "\n## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !actionItems.isEmpty {
            out += "\n## Action items\n" + actionItems.map { GenRender.actionItem($0) }.joined(separator: "\n") + "\n"
        }
        return out
    }
}

@available(macOS 26.0, *)
@Generable
struct GenDecision { @Guide(description: "The decision made") var decision: String; @Guide(description: "[mm:ss] from the transcript, or empty") var timestamp: String; @Guide(description: "Brief context or rationale") var context: String }

@available(macOS 26.0, *)
@Generable
struct GenDecisionLog {
    @Guide(description: "Every decision reached, in chronological order") var decisions: [GenDecision]
    func render() -> String {
        guard !decisions.isEmpty else { return "No decisions were recorded in this session." }
        return "# Decision log\n\n" + decisions.map { d in
            let ts = d.timestamp.isEmpty ? "" : "[\(GenRender.cleanTS(d.timestamp))] "
            let ctx = d.context.isEmpty ? "" : "\n  - \(d.context)"
            return "- \(ts)\(d.decision)\(ctx)"
        }.joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
@Generable
struct GenQAPair { @Guide(description: "A question raised") var question: String; @Guide(description: "The answer given, or 'unanswered'") var answer: String; @Guide(description: "[mm:ss] from the transcript, or empty") var timestamp: String }

@available(macOS 26.0, *)
@Generable
struct GenQAList {
    @Guide(description: "Questions raised and how they were answered") var pairs: [GenQAPair]
    func render() -> String {
        guard !pairs.isEmpty else { return "No questions were identified." }
        return "# Q&A\n\n" + pairs.map { p in
            let ts = p.timestamp.isEmpty ? "" : " [\(GenRender.cleanTS(p.timestamp))]"
            return "**Q\(ts):** \(p.question)\n**A:** \(p.answer)"
        }.joined(separator: "\n\n")
    }
}

@available(macOS 26.0, *)
@Generable
struct GenObjection { @Guide(description: "The objection or concern raised") var objection: String; @Guide(description: "The response given, or 'no response'") var response: String; @Guide(description: "[mm:ss] from the transcript, or empty") var timestamp: String }

@available(macOS 26.0, *)
@Generable
struct GenObjectionLog {
    @Guide(description: "Objections raised by the prospect and how each was handled") var objections: [GenObjection]
    func render() -> String {
        guard !objections.isEmpty else { return "No objections were raised." }
        return "# Objection log\n\n" + objections.map { o in
            let ts = o.timestamp.isEmpty ? "" : " [\(GenRender.cleanTS(o.timestamp))]"
            return "**Objection\(ts):** \(o.objection)\n**Response:** \(o.response)"
        }.joined(separator: "\n\n")
    }
}

@available(macOS 26.0, *)
@Generable
struct GenSOAP {
    @Guide(description: "Subjective: what the patient reports (symptoms, history, concerns)") var subjective: String
    @Guide(description: "Objective: observable, measurable findings stated") var objective: String
    @Guide(description: "Assessment: the clinical impression discussed") var assessment: String
    @Guide(description: "Plan: next steps, treatment, follow-up discussed") var plan: String
    func render() -> String {
        GenRender.clinicalDisclaimer + "# SOAP note (draft)\n\n## Subjective\n\(subjective)\n\n## Objective\n\(objective)\n\n## Assessment\n\(assessment)\n\n## Plan\n\(plan)\n"
    }
}

@available(macOS 26.0, *)
@Generable
struct GenDAP {
    @Guide(description: "Data: what was observed and reported in the session") var data: String
    @Guide(description: "Assessment: the clinical interpretation discussed") var assessment: String
    @Guide(description: "Plan: next steps and follow-up discussed") var plan: String
    func render() -> String {
        GenRender.clinicalDisclaimer + "# DAP note (draft)\n\n## Data\n\(data)\n\n## Assessment\n\(assessment)\n\n## Plan\n\(plan)\n"
    }
}

@available(macOS 26.0, *)
@Generable
struct GenQuote { @Guide(description: "A notable verbatim quote from the transcript") var quote: String; @Guide(description: "[mm:ss] from the transcript, or empty") var timestamp: String }

@available(macOS 26.0, *)
@Generable
struct GenInterviewReport {
    @Guide(description: "The main themes that emerged") var themes: [String]
    @Guide(description: "Notable quotes with their [mm:ss]") var quotes: [GenQuote]
    @Guide(description: "Suggested follow-up questions") var followUps: [String]
    func render() -> String {
        var out = "# Interview report\n"
        if !themes.isEmpty { out += "\n## Themes\n" + themes.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !quotes.isEmpty {
            out += "\n## Notable quotes\n" + quotes.map { q in
                let ts = q.timestamp.isEmpty ? "" : "[\(GenRender.cleanTS(q.timestamp))] "
                return "- \(ts)“\(q.quote)”"
            }.joined(separator: "\n") + "\n"
        }
        if !followUps.isEmpty { out += "\n## Follow-up questions\n" + followUps.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out
    }
}

@available(macOS 26.0, *)
@Generable
struct GenFlashcard { @Guide(description: "The front of the card (a question or term)") var front: String; @Guide(description: "The back of the card (the answer or definition)") var back: String }

@available(macOS 26.0, *)
@Generable
struct GenFlashcards {
    @Guide(description: "Study flashcards covering the key facts and concepts") var cards: [GenFlashcard]
    func dtos() -> [FlashcardDTO] { cards.map { FlashcardDTO(front: $0.front, back: $0.back) } }
}

@available(macOS 26.0, *)
@Generable
struct GenQuizItem {
    @Guide(description: "The question") var question: String
    @Guide(description: "3–4 answer choices") var choices: [String]
    @Guide(description: "The 0-based index of the correct choice") var answerIndex: Int
    @Guide(description: "A one-sentence explanation of the correct answer") var explanation: String
}

@available(macOS 26.0, *)
@Generable
struct GenQuiz {
    @Guide(description: "Multiple-choice quiz questions covering the material") var items: [GenQuizItem]
    func dtos() -> [QuizItemDTO] { items.map { QuizItemDTO(question: $0.question, choices: $0.choices, answerIndex: $0.answerIndex, explanation: $0.explanation) } }
}

@available(macOS 26.0, *)
@Generable
struct GenConcept { @Guide(description: "A key term or concept") var term: String; @Guide(description: "Its definition or explanation") var definition: String }

@available(macOS 26.0, *)
@Generable
struct GenStudyGuide {
    @Guide(description: "Key concepts with definitions") var concepts: [GenConcept]
    @Guide(description: "A concise summary of the material") var summary: String
    func render() -> String {
        var out = "# Study guide\n"
        if !concepts.isEmpty { out += "\n## Key concepts\n" + concepts.map { "- **\($0.term):** \($0.definition)" }.joined(separator: "\n") + "\n" }
        if !summary.isEmpty { out += "\n## Summary\n\(summary)\n" }
        return out
    }
}

@available(macOS 26.0, *)
@Generable
struct GenChapter { @Guide(description: "[mm:ss] start from the transcript") var timestamp: String; @Guide(description: "A short chapter / topic title") var title: String }

@available(macOS 26.0, *)
@Generable
struct GenShowNotes {
    @Guide(description: "A 2–4 sentence episode summary") var summary: String
    @Guide(description: "Timestamped topics / chapters in order") var chapters: [GenChapter]
    func render() -> String {
        var out = "# Show notes\n\n\(summary)\n"
        if !chapters.isEmpty {
            out += "\n## Chapters\n" + chapters.map { "- [\(GenRender.cleanTS($0.timestamp))] \($0.title)" }.joined(separator: "\n") + "\n"
        }
        return out
    }
}

@available(macOS 26.0, *)
@Generable
struct GenTitles {
    @Guide(description: "5–8 candidate episode titles") var titles: [String]
    func render() -> String {
        titles.isEmpty ? "No titles generated." : "# Title ideas\n\n" + titles.map { "- \($0)" }.joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
@Generable
struct GenSocialPosts {
    @Guide(description: "A short post suitable for X/Twitter (≤ 280 characters)") var x: String
    @Guide(description: "A longer professional post suitable for LinkedIn") var linkedIn: String
    func render() -> String { "# Social posts\n\n## X\n\(x)\n\n## LinkedIn\n\(linkedIn)\n" }
}

@available(macOS 26.0, *)
@Generable
struct GenBlog {
    @Guide(description: "A blog/newsletter post title") var title: String
    @Guide(description: "The post body in a few short paragraphs") var body: String
    func render() -> String { "# \(title)\n\n\(body)\n" }
}

@available(macOS 26.0, *)
@Generable
struct GenEmailRecap {
    @Guide(description: "A concise email subject line") var subject: String
    @Guide(description: "The email body recapping the session") var body: String
    func render() -> String { "Subject: \(subject)\n\n\(body)\n" }
}

// MARK: - Render helpers + JSON encoding

@available(macOS 26.0, *)
enum GenRender {
    static let clinicalDisclaimer = "_Draft — not a medical record. Review and edit before any clinical use._\n\n"

    static func actionItem(_ a: GenActionItem) -> String {
        var line = "- \(a.task)"
        if !a.owner.isEmpty { line += " (\(a.owner))" }
        if !a.timestamp.isEmpty { line += " [\(cleanTS(a.timestamp))]" }
        return line
    }

    /// Normalize a model-emitted timestamp to bare `mm:ss` (strip stray brackets/spaces).
    static func cleanTS(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]() \t"))
        return SessionStore.firstTimestamp(in: t) ?? t
    }

    static func jsonString<T: Encodable>(_ value: T) -> String? {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Structured dispatcher

/// Runs one structured (`@Generable`) template. Separated from `GenerationStudio` so all the
/// macOS-26-only `@Generable` references live behind a single availability gate.
@available(macOS 26.0, *)
enum StructuredGen {
    static func run(kind: GenerationKind, transcript: String, grounding: String) async throws -> GenerationOutput {
        switch kind {
        case .minutes:
            let v = try await call(GenMeetingMinutes.self, grounding,
                "Produce structured meeting minutes from this transcript.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .decisionLog:
            let v = try await call(GenDecisionLog.self, grounding,
                "Extract every decision reached, in chronological order.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .qa:
            let v = try await call(GenQAList.self, grounding,
                "Extract questions raised and how each was answered.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .objections:
            let v = try await call(GenObjectionLog.self, grounding,
                "This is a sales call. Extract the prospect's objections and how each was handled.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .soap:
            let v = try await call(GenSOAP.self, grounding,
                "This is a clinical encounter. Draft a SOAP note from what was discussed.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .dap:
            let v = try await call(GenDAP.self, grounding,
                "This is a clinical/therapy session. Draft a DAP note from what was discussed.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .interview:
            let v = try await call(GenInterviewReport.self, grounding,
                "This is an interview. Produce an interview report with themes, notable quotes, and follow-ups.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .flashcards:
            let v = try await call(GenFlashcards.self, grounding,
                "Create study flashcards (front = question/term, back = answer/definition) covering the key facts.", transcript)
            let json = GenRender.jsonString(v.dtos())
            return .init(text: json.flatMap { GenerationStudio.flashcardsDisplay(fromJSON: $0) } ?? "No flashcards generated.",
                         format: "json", json: json)
        case .quiz:
            let v = try await call(GenQuiz.self, grounding,
                "Create a multiple-choice quiz covering the material; answerIndex is the 0-based correct choice.", transcript)
            let json = GenRender.jsonString(v.dtos())
            return .init(text: json.flatMap { GenerationStudio.quizDisplay(fromJSON: $0) } ?? "No quiz questions generated.",
                         format: "json", json: json)
        case .studyGuide:
            let v = try await call(GenStudyGuide.self, grounding,
                "Create a study guide: key concepts with definitions, then a concise summary.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .showNotes:
            let v = try await call(GenShowNotes.self, grounding,
                "Produce podcast/video show notes: a short summary, then timestamped chapters in order.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .titles:
            let v = try await call(GenTitles.self, grounding,
                "Suggest catchy candidate episode titles based on the content.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .social:
            let v = try await call(GenSocialPosts.self, grounding,
                "Write social posts promoting this content: one for X (≤280 chars) and one for LinkedIn.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .blog:
            let v = try await call(GenBlog.self, grounding,
                "Draft a blog/newsletter post repurposing this content.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .emailRecap:
            let v = try await call(GenEmailRecap.self, grounding,
                "Write a concise email recapping this session for someone who missed it.", transcript)
            return .init(text: v.render(), format: "text", json: nil)
        case .summaryStyle, .customMode:
            // Handled by GenerationStudio before reaching here.
            throw SummaryError.unavailable("Not a structured template.")
        }
    }

    /// One guided-generation call: instructions = grounding + task, prompt = transcript.
    private static func call<T: Generable>(_ type: T.Type, _ grounding: String, _ task: String,
                                           _ transcript: String) async throws -> T {
        let session = LanguageModelSession(instructions: grounding + "\n\nTASK: " + task)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 1500)
        let response = try await session.respond(to: "TRANSCRIPT:\n\n\(transcript)",
                                                 generating: type, options: options)
        return response.content
    }
}
#endif
