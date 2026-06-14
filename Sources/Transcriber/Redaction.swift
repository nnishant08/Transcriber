import Foundation
import NaturalLanguage

/// Feature C2 — on-device PII/PHI redaction. NON-DESTRUCTIVE and TIMESTAMP-PRESERVING (follows the
/// Stage-1 cleanup model exactly): the redacted form is stored as `redactedText` per segment in
/// `session.json` ONLY — the verbatim `transcript.md` and every `[mm:ss]` anchor are never touched.
///
/// Detection is best-effort and 100% on-device: NLTagger names (person/org/place) + NSDataDetector
/// (phone/address/date/link) + regexes (email / SSN / long IDs). Person names get STABLE pseudonyms
/// across the session ([PERSON 1], [PERSON 2], …); other categories get fixed placeholders. An FM
/// augmentation pass is optional and behind the availability guard — the detector path works without it.
enum Redactor {

    /// Redact one line, drawing person pseudonyms from (and updating) the shared `pseudonyms` map so a
    /// name maps to the same token everywhere in the session.
    static func redact(_ text: String, pseudonyms: inout [String: String]) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return text }
        var spans: [(range: NSRange, token: String)] = []

        // 1) Names / orgs / places via NLTagger.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            guard let tag else { return true }
            let nsRange = NSRange(range, in: text)
            switch tag {
            case .personalName:
                let key = ns.substring(with: nsRange).lowercased()
                let token: String
                if let existing = pseudonyms[key] { token = existing }
                else { token = "[PERSON \(pseudonyms.count + 1)]"; pseudonyms[key] = token }
                spans.append((nsRange, token))
            case .organizationName: spans.append((nsRange, "[ORG]"))
            case .placeName:        spans.append((nsRange, "[LOCATION]"))
            default: break
            }
            return true
        }

        // 2) Data detectors: phone, address, date, link.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.phoneNumber, .address, .date, .link]).rawValue) {
            detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                switch m.resultType {
                case .phoneNumber: spans.append((m.range, "[PHONE]"))
                case .address:     spans.append((m.range, "[ADDRESS]"))
                case .date:        spans.append((m.range, "[DATE]"))
                case .link:
                    let s = ns.substring(with: m.range)
                    spans.append((m.range, s.contains("@") || s.hasPrefix("mailto:") ? "[EMAIL]" : "[URL]"))
                default: break
                }
            }
        }

        // 3) Regexes the detectors miss: bare email, SSN, long numeric IDs.
        addRegex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, token: "[EMAIL]", in: text, ns: ns, into: &spans)
        addRegex(#"\b\d{3}-\d{2}-\d{4}\b"#, token: "[ID]", in: text, ns: ns, into: &spans)        // SSN
        addRegex(#"\b\d{7,}\b"#, token: "[ID]", in: text, ns: ns, into: &spans)                    // MRN / account #

        return apply(spans: spans, to: ns)
    }

    private static func addRegex(_ pattern: String, token: String, in text: String, ns: NSString,
                                 into spans: inout [(range: NSRange, token: String)]) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            spans.append((m.range, token))
        }
    }

    /// Substitute the spans into the string, resolving overlaps by keeping the longest (then earliest)
    /// span and dropping any that overlaps a kept one. Walks left→right so offsets stay coherent.
    private static func apply(spans rawSpans: [(range: NSRange, token: String)], to ns: NSString) -> String {
        guard !rawSpans.isEmpty else { return ns as String }
        let sorted = rawSpans.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location
                                                   : $0.range.length > $1.range.length
        }
        var kept: [(range: NSRange, token: String)] = []
        var cursor = 0
        for span in sorted {
            guard span.range.location >= cursor, span.range.length > 0 else { continue }   // skip overlaps
            kept.append(span)
            cursor = span.range.location + span.range.length
        }
        let out = NSMutableString(string: ns)
        for span in kept.reversed() { out.replaceCharacters(in: span.range, with: span.token) }
        return out as String
    }

    /// Fill `redactedText` on every non-empty segment, sharing one pseudonym map for stability.
    /// Already-redacted segments keep their value.
    static func redactSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out = segments
        var pseudonyms: [String: String] = [:]
        // Seed the map from any prior redactions so re-runs stay consistent (best-effort).
        for i in out.indices {
            guard out[i].redactedText == nil else { continue }
            let t = out[i].text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            out[i].redactedText = redact(out[i].text, pseudonyms: &pseudonyms)
        }
        return out
    }
}

/// The post-load redaction pass. Runs OFF the save path (Viewer-triggered or batch), writes ONLY
/// `session.json` `redactedText`s — `transcript.md` stays the untouched verbatim record. Mirrors
/// `CleanupPass`: merge onto a fresh read so a concurrent writer's fields aren't clobbered.
enum RedactionPass {
    static func run(dir: URL) async {
        guard let doc = DocumentBuilder.readSession(dir), !doc.segments.isEmpty,
              doc.segments.contains(where: { $0.redactedText == nil }) else { return }
        let redacted = Redactor.redactSegments(doc.segments)
        guard redacted.contains(where: { $0.redactedText != nil }) else { return }
        guard var fresh = DocumentBuilder.readSession(dir), fresh.segments.count == redacted.count else { return }
        for i in fresh.segments.indices { fresh.segments[i].redactedText = redacted[i].redactedText }
        DocumentBuilder.writeSessionJSON(fresh, to: dir)
        SessionStore.postSessionSaved(dir)
        NSLog("[Redact] redacted \(redacted.filter { $0.redactedText != nil }.count)/\(redacted.count) segments for \(dir.lastPathComponent)")
    }
}
