import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummaryError: LocalizedError {
    case needsMacOS26
    case unavailable(String)
    case emptyTranscript
    case emptyTemplate

    var errorDescription: String? {
        switch self {
        case .needsMacOS26: return "AI summaries need macOS 26 with Apple Intelligence."
        case .unavailable(let why): return why
        case .emptyTranscript: return "There's no transcript to summarize yet."
        case .emptyTemplate: return "This custom summary mode has no instructions yet — edit it in Settings."
        }
    }
}

/// On-device transcript summarization via Apple's Foundation Models framework (Apple Intelligence).
/// 100% local — no cloud, no API key, works offline. Requires macOS 26 with Apple Intelligence enabled.
enum Summarizer {
    /// Is on-device summarization usable right now?
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// A human-readable reason the model is unavailable, or nil if it's available.
    static func availabilityMessage() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence (System Settings ▸ Apple Intelligence & Siri) to enable on-device summaries."
                case .deviceNotEligible:
                    return "This Mac doesn't support Apple Intelligence, so on-device summaries aren't available."
                case .modelNotReady:
                    return "Apple Intelligence is still preparing its model — try again in a few minutes."
                @unknown default:
                    return "On-device summarization is currently unavailable."
                }
            }
        }
        #endif
        return "AI summaries need macOS 26 with Apple Intelligence."
    }

    /// Summarize a transcript fully on-device. Throws SummaryError if unavailable.
    static func summarize(_ transcript: String) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError.emptyTranscript }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: break
            case .unavailable:
                throw SummaryError.unavailable(availabilityMessage() ?? "On-device model unavailable.")
            }
            // Keep within the on-device model's context window.
            let clipped = String(text.prefix(8000))
            let session = LanguageModelSession(instructions: """
                You summarize spoken-word transcripts. Produce a 1–2 sentence overview, then 3–6 concise \
                bullet points covering the key points, decisions, or action items. Stay faithful to the \
                transcript — do not invent details. Use plain text (no markdown headers).
                """)
            let response = try await session.respond(to: "Transcript:\n\n\(clipped)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw SummaryError.needsMacOS26
    }
}
