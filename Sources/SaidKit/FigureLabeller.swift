import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The labeller (§P2)
//
// The optional layer on top of the detector. It answers ONE question per candidate — what is this
// a number of? — and may veto a candidate the detector let through. It is never asked where a
// figure is: the request carries an index, the response is matched back by that index, and no
// character offset ever crosses the model boundary in either direction (prime directive #4).
//
// Degradation is a supported state, not an error state: no Apple Intelligence, a model that is
// not ready, a throw mid-batch, or the call cap — every candidate survives with a null label and
// the UI shows figures without labels. Nothing here surfaces a banner.

/// What the model sees for one candidate.
public struct FigureLabelRequest: Sendable, Equatable {
    public let index: Int            // position in the batch — the ONLY join key
    public let raw: String
    public let kind: FigureClass
    public init(index: Int, raw: String, kind: FigureClass) { self.index = index; self.raw = raw; self.kind = kind }
}

/// What the model says about one candidate.
public struct FigureLabelResult: Sendable, Equatable {
    public let index: Int
    public let label: String?
    public let keep: Bool
    public let confidence: Double
    public init(index: Int, label: String?, keep: Bool, confidence: Double) {
        self.index = index; self.label = label; self.keep = keep; self.confidence = confidence
    }
}

/// The seam the self-test stubs. One batch = the candidates of ONE turn, with that turn plus its
/// neighbours as context.
public protocol FigureLabelBackend: Sendable {
    var isAvailable: Bool { get }
    func label(_ requests: [FigureLabelRequest], context: String) async throws -> [FigureLabelResult]
}

public enum FigureLabeller {

    /// Below this the model's label is discarded and the figure is kept with a null label. The
    /// number was still said; an uncertain name for it is worse than none.
    public static let confidenceFloor = 0.5

    /// Model calls per extraction. Batching is by turn, so this is a cap on TURNS with figures, not
    /// on figures — a 90-minute finance review has a few dozen figure-bearing turns, not hundreds.
    /// Past the cap the remaining candidates keep null labels and the sidecar records `labelled =
    /// false`, so a re-run can pick them up.
    public static let maxCallsPerSession = 40

    /// Characters of surrounding transcript handed to the model per batch: the containing turn plus
    /// one turn either side, then cut. Not the whole transcript (§P2).
    public static let contextCap = 1_400

    public struct Outcome: Sendable {
        public var figures: [Figure]
        public var calls: Int
        /// True when every batch that needed a call got one and none threw.
        public var complete: Bool
    }

    /// Label `figures` in place. Candidates already carrying a label are left alone (a re-extraction
    /// reuses what the model said last time). Pure apart from the backend.
    public static func run(_ figures: [Figure], segments: [TranscriptSegment],
                           backend: FigureLabelBackend, maxCalls: Int = maxCallsPerSession) async -> Outcome {
        guard backend.isAvailable else { return Outcome(figures: figures, calls: 0, complete: false) }
        var out = figures
        var calls = 0
        var complete = true
        // Batch by turn, in transcript order.
        let turns = Array(Set(figures.enumerated().filter { $0.element.label == nil }.map { $0.element.segmentIndex })).sorted()
        var dropped = Set<Int>()   // indices into `out`
        for si in turns {
            let members = out.enumerated().filter { $0.element.segmentIndex == si && $0.element.label == nil }
            guard !members.isEmpty else { continue }
            guard calls < maxCalls else { complete = false; break }
            let requests = members.enumerated().map { FigureLabelRequest(index: $0.offset, raw: $0.element.element.raw, kind: $0.element.element.kind) }
            calls += 1
            let results: [FigureLabelResult]
            do { results = try await backend.label(requests, context: context(for: si, in: segments)) }
            catch {
                NSLog("[Figures] labelling turn \(si) failed: \(error)")
                complete = false
                continue   // this turn's figures keep their null labels
            }
            for r in results {
                guard members.indices.contains(r.index) else { continue }   // an index the model invented
                let target = members[r.index].offset
                if !r.keep, r.confidence >= confidenceFloor { dropped.insert(target); continue }
                guard r.confidence >= confidenceFloor else { continue }     // keep, unlabelled
                let l = sanitize(r.label)
                out[target].label = l
                out[target].confidence = l == nil ? nil : r.confidence
            }
        }
        if !dropped.isEmpty { out = out.enumerated().filter { !dropped.contains($0.offset) }.map(\.element) }
        return Outcome(figures: out, calls: calls, complete: complete)
    }

    /// The containing turn plus one either side, capped.
    static func context(for si: Int, in segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        for i in max(0, si - 1)...min(segments.count - 1, si + 1) where segments.indices.contains(i) {
            let marker = i == si ? "» " : "  "
            lines.append("\(marker)[\(DocumentBuilder.timestamp(segments[i].start))] \(segments[i].text)")
        }
        let joined = lines.joined(separator: "\n")
        return joined.count <= contextCap ? joined : String(joined.prefix(contextCap))
    }

    static func sanitize(_ label: String?) -> String? {
        guard var l = label?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        l = l.trimmingCharacters(in: CharacterSet(charactersIn: ".:;,\"'“”"))
        if l.lowercased() == "unknown" || l.lowercased() == "none" || l.lowercased() == "n/a" { return nil }
        guard !l.isEmpty, l.count <= 60 else { return nil }
        return l
    }
}

// MARK: - The on-device backend

/// FoundationModels guided generation, behind the existing availability check. Returns nothing but
/// an index, a label, a keep flag and a confidence — the four fields §P2 allows.
public struct OnDeviceFigureLabelBackend: FigureLabelBackend {
    public init() {}

    public var isAvailable: Bool { Intelligence.isAvailable }

    public func label(_ requests: [FigureLabelRequest], context: String) async throws -> [FigureLabelResult] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: break
            case .unavailable: throw SummaryError.unavailable(Intelligence.availabilityMessage() ?? "On-device model unavailable.")
            }
            let instructions = """
                You label numbers that were spoken in a transcript. For each numbered figure, say in \
                2–5 words what the number is a quantity OF (for example "customer acquisition cost", \
                "annual contract value", "headcount", "renewal deadline"). Use the transcript's own \
                words where possible. Set keep=false ONLY when the item is clearly not a quantity \
                (a room number, a version, a time of day). Give a confidence from 0 to 1. Return \
                exactly one item per figure, with the same index. Never describe where the figure is \
                in the text.
                """
            var prompt = "TRANSCRIPT (» marks the turn containing the figures):\n\(context)\n\nFIGURES:\n"
            for r in requests { prompt += "\(r.index). \"\(r.raw)\" (\(r.kind.rawValue))\n" }
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: 600)
            let response = try await session.respond(to: prompt, generating: FigureLabelBatch.self, options: options)
            return response.content.items.map {
                FigureLabelResult(index: $0.index, label: $0.label.isEmpty ? nil : $0.label,
                                  keep: $0.keep, confidence: min(1, max(0, $0.confidence)))
            }
        }
        #endif
        throw SummaryError.needsMacOS26
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct FigureLabelItem {
    @Guide(description: "The figure's index, copied from the list") var index: Int
    @Guide(description: "What the number is a quantity of, in 2–5 words; empty if unknown") var label: String
    @Guide(description: "false only when this is clearly not a quantity") var keep: Bool
    @Guide(description: "Confidence in the label, 0 to 1") var confidence: Double
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct FigureLabelBatch {
    @Guide(description: "One item per listed figure, same indices") var items: [FigureLabelItem]
}
#endif
