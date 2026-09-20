import Foundation

// MARK: - The detector (§P1)
//
// Pure. Given the segments and their word timings, returns every figure with an exact character
// range, an exact word-index range and a class. No I/O, no model, and the same input gives the
// same output on every run and on both platforms — which is what the cross-platform fixture
// asserts.
//
// **The model never returns offsets** (prime directive #4). Every range here comes from this file.
//
// What it is built from, and what it is not:
// - `NSDataDetector` for phone numbers (a NEGATIVE — phone numbers are excluded) and for calendar
//   dates behind a deadline preposition ("by March 3rd"). It has NO currency or measurement type,
//   so money, percentages, multipliers and units are a lexicon plus regular expressions below.
// - `NumberFormatter` `.decimal` / `.currency` for digits (locale `en_US`: the POSIX locale does
//   not parse grouped digits at all) and `.spellOut` for words — WRAPPED, because raw `.spellOut`
//   parses "twenty four" as 2004, "fifth" as 5 and "two point four million" as nothing. The
//   wrapper hyphenates tens+units, splits at scale words and refuses ordinals before it asks.

public enum FigureDetector {

    // MARK: Lexicon
    //
    // Small and explicit rather than clever (§P1). Every entry here is something a person says
    // out loud; nothing is inferred from morphology.

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    /// Scale words and their multipliers. "hundred" composes inside a chunk; the rest split chunks.
    static let bigScales: [String: Double] = [
        "thousand": 1e3, "million": 1e6, "billion": 1e9, "trillion": 1e12,
        "k": 1e3, "m": 1e6, "mm": 1e6, "bn": 1e9, "b": 1e9,
    ]
    static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "hundredth",
    ]

    /// Currency words → ISO code. "pounds" is money here, not mass: in a conversation about
    /// numbers "two hundred pounds" is far more often a price than a weight, and a weight reads
    /// fine as money-mislabelled while a price read as a weight is a wrong revenue number.
    static let currencyWords: [String: String] = [
        "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD", "usd": "USD",
        "cent": "USD", "cents": "USD",
        "euro": "EUR", "euros": "EUR", "eur": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP", "gbp": "GBP",
    ]
    static let currencySymbols: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP"]

    static let percentWords: Set<String> = ["percent", "percentage", "pct"]
    /// Two-token forms, matched as a pair.
    static let percentPairs: [[String]] = [["per", "cent"], ["basis", "points"], ["basis", "point"]]
    static let bpsWords: Set<String> = ["bps", "bp"]

    static let multiplierWords: Set<String> = ["times", "x", "fold"]
    /// Words that ARE a multiplier on their own — accepted only with a base nearby (§3).
    static let bareMultipliers: [String: Double] = ["doubled": 2, "tripled": 3, "quadrupled": 4, "halved": 0.5]

    /// Count units, singular form as the stored `unit`.
    static let countUnits: [String: String] = {
        var m: [String: String] = [:]
        func add(_ singular: String, _ forms: String...) { m[singular] = singular; for f in forms { m[f] = singular } }
        add("hour", "hours", "hr", "hrs"); add("minute", "minutes", "min", "mins"); add("second", "seconds", "sec", "secs")
        add("person", "people", "persons"); add("user", "users"); add("customer", "customers")
        add("employee", "employees"); add("engineer", "engineers"); add("seat", "seats")
        add("license", "licenses", "licence", "licences"); add("unit", "units"); add("item", "items")
        add("order", "orders"); add("ticket", "tickets"); add("request", "requests"); add("call", "calls")
        add("session", "sessions"); add("meeting", "meetings"); add("store", "stores"); add("country", "countries")
        add("market", "markets"); add("deal", "deals"); add("client", "clients"); add("account", "accounts")
        add("lead", "leads"); add("hire", "hires"); add("candidate", "candidates"); add("team", "teams")
        add("server", "servers"); add("node", "nodes"); add("core", "cores"); add("gpu", "gpus")
        add("byte", "bytes"); add("kilobyte", "kilobytes", "kb"); add("megabyte", "megabytes", "mb")
        add("gigabyte", "gigabytes", "gb", "gig", "gigs"); add("terabyte", "terabytes", "tb"); add("petabyte", "petabytes", "pb")
        add("kilometre", "kilometres", "kilometer", "kilometers", "km"); add("mile", "miles")
        add("metre", "metres", "meter", "meters"); add("kilogram", "kilograms", "kg", "kilo", "kilos")
        add("tonne", "tonnes", "ton", "tons"); add("litre", "litres", "liter", "liters")
        add("page", "pages"); add("slide", "slides"); add("word", "words"); add("line", "lines")
        add("step", "steps"); add("point", "points"); add("vote", "votes"); add("student", "students")
        add("participant", "participants"); add("respondent", "respondents"); add("sample", "samples")
        add("download", "downloads"); add("install", "installs"); add("subscriber", "subscribers")
        add("view", "views"); add("click", "clicks"); add("visit", "visits"); add("signup", "signups")
        add("transaction", "transactions"); add("invoice", "invoices"); add("share", "shares")
        add("fte", "ftes"); add("headcount"); add("dose", "doses"); add("patient", "patients")
        add("case", "cases"); add("bed", "beds"); add("room", "rooms"); add("floor", "floors")
        add("bug", "bugs"); add("commit", "commits"); add("pr", "prs"); add("issue", "issues")
        add("degree", "degrees"); add("watt", "watts", "kw", "kilowatt", "kilowatts", "mw", "megawatt", "megawatts")
        return m
    }()

    /// Duration units, singular form as `unit`. A number + one of these is a `.duration`.
    static let durationUnits: [String: String] = {
        var m: [String: String] = [:]
        func add(_ singular: String, _ forms: String...) { m[singular] = singular; for f in forms { m[f] = singular } }
        add("day", "days"); add("week", "weeks", "wk", "wks"); add("month", "months", "mo", "mos")
        add("year", "years", "yr", "yrs"); add("quarter", "quarters"); add("sprint", "sprints")
        add("decade", "decades"); add("fortnight", "fortnights"); add("semester", "semesters")
        return m
    }()

    /// A number that follows one of these is an identifier, not a quantity (§3 "not figures").
    static let identifierPrefixes: Set<String> = [
        "slide", "page", "section", "chapter", "figure", "fig", "table", "room", "step", "item",
        "line", "track", "episode", "version", "v", "speaker", "route", "highway", "gate", "floor",
        "suite", "phone", "extension", "ext", "number", "no", "#", "flight", "seat", "bus", "platform",
        "exhibit", "appendix", "part", "act", "scene", "verse", "psalm", "level", "grade", "zone",
        "district", "ward", "block", "lot", "unit", "apartment", "apt", "building", "pier", "dock",
        "chromosome", "iphone", "windows", "python", "java", "swift", "ios", "macos", "android",
    ]

    /// Deadline phrases (no number of their own). Matched case-insensitively at word boundaries.
    static let deadlinePattern: NSRegularExpression = {
        let prep = "(?:by|before|until|till|through|in|within|no later than|not later than)"
        let target = "(?:year[- ]end|end of (?:the |this |next )?(?:year|quarter|month|week|day|sprint|half)"
            + "|q[1-4](?: (?:of )?\\d{4})?|h[12](?: \\d{4})?|eoy|eoq|eom|eow|eod"
            + "|(?:next|this|the next|the coming) (?:sprint|quarter|month|week|year|half|cycle|release))"
        return try! NSRegularExpression(pattern: "\\b\(prep) \(target)\\b|\\b(?:next|this) sprint\\b",
                                        options: [.caseInsensitive])
    }()
    static let deadlinePrepositions: Set<String> = ["by", "before", "until", "till", "within", "through"]

    /// Digit tokens: optional symbol, grouped or plain digits, optional decimals, optional
    /// k/m/bn suffix, optional % or x suffix. Case-insensitive.
    static let digitPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "^([$€£])?(\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.(\\d+))?(k|m|mm|bn|b)?(%|x)?$",
            options: [.caseInsensitive])
    }()
    static let timeOfDayPattern = try! NSRegularExpression(pattern: "^\\d{1,2}(?::\\d{2})?(?:am|pm)$", options: [.caseInsensitive])
    static let ordinalSuffixPattern = try! NSRegularExpression(pattern: "^\\d+(?:st|nd|rd|th)$", options: [.caseInsensitive])

    static let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US"); return f
    }()
    static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = Locale(identifier: "en_US"); return f
    }()
    static let spellOutFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .spellOut; f.locale = Locale(identifier: "en_US"); return f
    }()

    // MARK: Tokens

    /// One whitespace-delimited token, with its punctuation peeled off. `core` is what the rules
    /// look at; `range` is the core's `Character` range in the segment text.
    struct Token {
        let core: String          // lowercased, no leading/trailing punctuation
        let original: String      // the core as written (case preserved)
        let range: Range<Int>     // of `original` in the text
        let trailingBreak: Bool   // ended in . , ; : ! ? — a number phrase cannot continue past it
        let index: Int
    }

    static func tokenize(_ text: String) -> [Token] {
        let chars = Array(text)
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            let start = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            var lo = start, hi = i
            while lo < hi, !(chars[lo].isLetter || chars[lo].isNumber || chars[lo] == "$" || chars[lo] == "€" || chars[lo] == "£" || chars[lo] == "#") { lo += 1 }
            while hi > lo, !(chars[hi - 1].isLetter || chars[hi - 1].isNumber || chars[hi - 1] == "%") { hi -= 1 }
            guard lo < hi else { continue }
            let original = String(chars[lo..<hi])
            let tail = String(chars[hi..<i])
            let brk = tail.contains { ".,;:!?".contains($0) }
            out.append(Token(core: original.lowercased(), original: original, range: lo..<hi,
                             trailingBreak: brk, index: out.count))
        }
        return out
    }

    // MARK: Entry point

    /// Every figure in `segments`, in transcript order. Figures never span a segment (a figure
    /// belongs to exactly one speaker), and overlaps are resolved by longest match, then class
    /// priority (money > percentage > multiplier > count > duration).
    public static func detect(segments: [TranscriptSegment]) -> [Figure] {
        var out: [Figure] = []
        for (si, seg) in segments.enumerated() {
            out.append(contentsOf: detect(segmentIndex: si, segment: seg))
        }
        return out
    }

    /// A single segment. The unit of work for the labeller's batching too.
    public static func detect(segmentIndex si: Int, segment seg: TranscriptSegment) -> [Figure] {
        let text = seg.text
        guard text.contains(where: { $0.isNumber }) || containsNumberWord(text) else { return [] }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        let excluded = excludedRanges(in: text)
        var raws: [RawCandidate] = []
        raws.append(contentsOf: digitAndSpelled(tokens: tokens, excluded: excluded))
        raws.append(contentsOf: bareMultiplierCandidates(tokens: tokens, numeric: raws))
        raws.append(contentsOf: deadlineCandidates(text: text, tokens: tokens, excluded: excluded))

        let chosen = resolveOverlaps(raws)
        let ranges = seg.validWords.flatMap { WordAlignment.characterRanges(words: $0, text: text) }
        let chars = Array(text)
        return chosen.sorted { $0.range.lowerBound < $1.range.lowerBound }.map { c in
            var wordRange: Range<Int>? = nil
            var start = seg.start, end = seg.end
            if let ranges, let words = seg.validWords, let wr = WordAlignment.wordRange(covering: c.range, ranges: ranges) {
                wordRange = wr
                start = words[wr.lowerBound].start
                end = words[wr.upperBound - 1].end
            }
            return Figure(segmentIndex: si, wordStart: wordRange?.lowerBound, wordEnd: wordRange?.upperBound,
                          charStart: c.range.lowerBound, charEnd: c.range.upperBound,
                          start: start, end: end, raw: String(chars[c.range]), kind: c.kind,
                          value: c.value, unit: c.unit, speaker: seg.speaker)
        }
    }

    /// A candidate before anchoring. Public so `--selftest-figures-detect` can drive the overlap
    /// resolver with hand-built conflicts, which real text rarely produces on demand.
    public struct RawCandidate: Equatable, Sendable {
        public var range: Range<Int>
        public var kind: FigureClass
        public var value: Double?
        public var unit: String?
        public init(range: Range<Int>, kind: FigureClass, value: Double?, unit: String?) {
            self.range = range; self.kind = kind; self.value = value; self.unit = unit
        }
    }

    private static let numberWordSet: Set<String> = Set(units.keys).union(tens.keys).union(["hundred"]).union(bigScales.keys)
        .union(bareMultipliers.keys).union(["next", "this", "by", "year-end", "eoy", "eoq"])

    static func containsNumberWord(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).contains {
            numberWordSet.contains(String($0)) || $0.contains("-") && $0.split(separator: "-").contains { numberWordSet.contains(String($0)) }
        }
    }

    // MARK: Exclusions

    /// Character ranges that can never be part of a figure: phone numbers and clock times.
    static func excludedRanges(in text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let ns = text as NSString
        if let det = phoneDetector {
            for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let r = characterRange(from: m.range, in: text) { out.append(r) }
            }
        }
        // Clock references: 3:30, 3:30 pm, 2pm, 11 o'clock.
        if let re = try? NSRegularExpression(pattern: "\\b\\d{1,2}:\\d{2}(?:\\s?(?:am|pm))?\\b|\\b\\d{1,2}\\s?(?:am|pm)\\b|\\b\\d{1,2}\\s+o'?clock\\b",
                                             options: [.caseInsensitive]) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let r = characterRange(from: m.range, in: text) { out.append(r) }
            }
        }
        return out
    }

    static func characterRange(from ns: NSRange, in text: String) -> Range<Int>? {
        guard let r = Range(ns, in: text) else { return nil }
        let lo = text.distance(from: text.startIndex, to: r.lowerBound)
        let hi = text.distance(from: text.startIndex, to: r.upperBound)
        return lo..<hi
    }

    static func overlapsExcluded(_ r: Range<Int>, _ excluded: [Range<Int>]) -> Bool {
        excluded.contains { $0.overlaps(r) }
    }

    // MARK: Numbers (digits and words)

    struct Phrase {
        var value: Double
        var firstToken: Int
        var lastToken: Int
        var currency: String?      // from a symbol prefix
        var pct: Bool              // % attached
        var mult: Bool             // x attached
        var isSpelled: Bool
    }

    static func digitAndSpelled(tokens: [Token], excluded: [Range<Int>]) -> [RawCandidate] {
        var out: [RawCandidate] = []
        var i = 0
        while i < tokens.count {
            guard let phrase = parseNumberPhrase(tokens, at: i) else { i += 1; continue }
            let first = tokens[phrase.firstToken], last = tokens[phrase.lastToken]
            let span = first.range.lowerBound..<last.range.upperBound
            i = phrase.lastToken + 1
            if overlapsExcluded(span, excluded) { continue }
            // An identifier, not a quantity: "slide 5", "version 2", "Speaker 1". Checked on the
            // word BEFORE the number, and only for digit forms — "page five" is rare enough that a
            // spoken form is left to the unit rule.
            if phrase.firstToken > 0 {
                let prev = tokens[phrase.firstToken - 1]
                if identifierPrefixes.contains(prev.core) && !prev.trailingBreak { continue }
            }
            guard let classified = classify(phrase, tokens: tokens) else { continue }
            var c = classified
            c.range = span.lowerBound..<max(span.upperBound, c.range.upperBound)
            if overlapsExcluded(c.range, excluded) { continue }
            out.append(c)
            i = max(i, tokenIndex(endingAt: c.range.upperBound, in: tokens) + 1)
        }
        return out
    }

    static func tokenIndex(endingAt upper: Int, in tokens: [Token]) -> Int {
        tokens.firstIndex { $0.range.upperBound >= upper } ?? tokens.count - 1
    }

    /// Parse a number phrase starting at token `i`: a digit token (with optional scale word after),
    /// or a run of spelled number words. `nil` if `tokens[i]` does not start one.
    static func parseNumberPhrase(_ tokens: [Token], at i: Int) -> Phrase? {
        let t = tokens[i]
        if let d = parseDigits(t) {
            var p = Phrase(value: d.value, firstToken: i, lastToken: i, currency: d.currency, pct: d.pct, mult: d.mult, isSpelled: false)
            // "2.4 million", "240 thousand", "$3 billion" — a scale word directly after digits.
            if !t.trailingBreak, !d.pct, !d.mult, !d.scaled, i + 1 < tokens.count,
               let scale = bigScales[tokens[i + 1].core], tokens[i + 1].core.count > 2 {
                p.value *= scale
                p.lastToken = i + 1
            }
            return p
        }
        return parseSpelled(tokens, at: i)
    }

    struct Digits { var value: Double; var currency: String?; var pct: Bool; var mult: Bool; var scaled: Bool }

    static func parseDigits(_ t: Token) -> Digits? {
        // Ordinals ("5th"), times ("3pm") and anything with letters inside are not numbers.
        let ns = t.original as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard ordinalSuffixPattern.firstMatch(in: t.original, range: full) == nil,
              timeOfDayPattern.firstMatch(in: t.original, range: full) == nil,
              let m = digitPattern.firstMatch(in: t.original, range: full) else { return nil }
        func group(_ n: Int) -> String? {
            let r = m.range(at: n); return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let symbol = group(1).flatMap { $0.first }.flatMap { currencySymbols[$0] }
        var numeric = group(2) ?? ""
        if let dec = group(3) { numeric += "." + dec }
        guard let n = decimalFormatter.number(from: numeric)?.doubleValue else { return nil }
        var value = n
        var scaled = false
        if let suf = group(4)?.lowercased(), let s = bigScales[suf] { value *= s; scaled = true }
        let tail = group(5)?.lowercased()
        // A bare 4-digit number reads as a year far more often than as a quantity; without a unit
        // or a symbol it is dropped by `classify` anyway, but a symbol-less "2024" with a scale word
        // ("2024 million") is not something anyone says.
        return Digits(value: value, currency: symbol, pct: tail == "%", mult: tail == "x", scaled: scaled)
    }

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || tens[w] != nil || w == "hundred" || bigScales[w] != nil && w.count > 2
    }

    /// A run of spelled number words starting at `i`, composed through `.spellOut` per chunk.
    static func parseSpelled(_ tokens: [Token], at i: Int) -> Phrase? {
        var words: [String] = []
        var j = i
        var lastIndex = i - 1
        var sawNumber = false
        while j < tokens.count {
            let t = tokens[j]
            let parts = t.core.split(separator: "-").map(String.init)
            let allNumeric = !parts.isEmpty && parts.allSatisfy { isNumberWord($0) || $0 == "point" }
            let isA = (t.core == "a" || t.core == "an") && j + 1 < tokens.count
                && (tokens[j + 1].core == "hundred" || bigScales[tokens[j + 1].core] != nil && tokens[j + 1].core.count > 2)
            let isAnd = t.core == "and" && sawNumber && j + 1 < tokens.count && isNumberWord(tokens[j + 1].core)
                && words.last == "hundred"
            let isPoint = t.core == "point" && sawNumber && j + 1 < tokens.count && units[tokens[j + 1].core] != nil
            if ordinalWords.contains(t.core) { break }
            if allNumeric || isA || isAnd || isPoint {
                if isA { words.append("one") }
                else if isAnd { /* dropped: "one hundred and twenty" → "one hundred twenty" */ }
                else { words.append(contentsOf: parts) }
                if allNumeric { sawNumber = true }
                lastIndex = j
                if t.trailingBreak { break }
                j += 1
            } else { break }
        }
        guard sawNumber, lastIndex >= i, let value = composeSpelled(words) else { return nil }
        return Phrase(value: value, firstToken: i, lastToken: lastIndex, currency: nil, pct: false, mult: false, isSpelled: true)
    }

    /// Compose spelled words into a value. Chunks split at the big scales; each chunk is handed to
    /// `.spellOut` after tens+units are hyphenated ("twenty four" → "twenty-four", because the raw
    /// formatter reads the unhyphenated form as 2004).
    public static func composeSpelled(_ words: [String]) -> Double? {
        var total = 0.0
        var chunk: [String] = []
        var pendingChunkValue: Double? = nil
        func flushChunk() -> Double? {
            guard !chunk.isEmpty else { return nil }
            let v = parseChunk(chunk); chunk = []; return v
        }
        for w in words {
            if let scale = bigScales[w] {
                let base = flushChunk() ?? pendingChunkValue ?? 1
                pendingChunkValue = nil
                total += base * scale
            } else {
                chunk.append(w)
            }
        }
        if let rest = flushChunk() { total += rest }
        else if let p = pendingChunkValue { total += p }
        return total
    }

    static func parseChunk(_ chunk: [String]) -> Double? {
        var joined: [String] = []
        var k = 0
        while k < chunk.count {
            let w = chunk[k]
            if tens[w] != nil, k + 1 < chunk.count, let u = units[chunk[k + 1]], u > 0, u < 10 {
                joined.append(w + "-" + chunk[k + 1]); k += 2
            } else { joined.append(w); k += 1 }
        }
        let s = joined.joined(separator: " ")
        if let n = spellOutFormatter.number(from: s)?.doubleValue { return n }
        // "point" chains the formatter cannot handle ("two point four five") — compose by hand.
        if let p = joined.firstIndex(of: "point"), p > 0 {
            guard let whole = spellOutFormatter.number(from: joined[..<p].joined(separator: " "))?.doubleValue else { return nil }
            var frac = ""
            for d in joined[(p + 1)...] { guard let u = units[d], u < 10 else { return nil }; frac += String(u) }
            return Double("\(Int(whole)).\(frac)")
        }
        return nil
    }

    // MARK: Classification

    /// Attach the unit that follows (or the symbol that preceded) and pick the class. A number
    /// with no recognised unit is NOT a figure (§3): that rule alone is what keeps page numbers,
    /// years, and "we have three options" out.
    static func classify(_ p: Phrase, tokens: [Token]) -> RawCandidate? {
        let last = tokens[p.lastToken]
        let span = tokens[p.firstToken].range.lowerBound..<last.range.upperBound
        if p.pct { return RawCandidate(range: span, kind: .percentage, value: p.value, unit: "%") }
        if p.mult { return RawCandidate(range: span, kind: .multiplier, value: p.value, unit: "x") }
        if let cur = p.currency { return RawCandidate(range: span, kind: .money, value: p.value, unit: cur) }

        // A currency CODE before the number: "USD 240".
        if p.firstToken > 0, let code = currencyWords[tokens[p.firstToken - 1].core], code == tokens[p.firstToken - 1].core.uppercased() {
            let r = tokens[p.firstToken - 1].range.lowerBound..<span.upperBound
            return RawCandidate(range: r, kind: .money, value: p.value, unit: code)
        }

        guard !last.trailingBreak, p.lastToken + 1 < tokens.count else { return nil }
        let next = tokens[p.lastToken + 1]
        let extended = span.lowerBound..<next.range.upperBound

        if let code = currencyWords[next.core] {
            return RawCandidate(range: extended, kind: .money, value: p.value, unit: code)
        }
        if percentWords.contains(next.core) { return RawCandidate(range: extended, kind: .percentage, value: p.value, unit: "%") }
        if bpsWords.contains(next.core) { return RawCandidate(range: extended, kind: .percentage, value: p.value, unit: "bps") }
        if p.lastToken + 2 < tokens.count, !next.trailingBreak {
            let after = tokens[p.lastToken + 2]
            for pair in percentPairs where pair[0] == next.core && pair[1] == after.core {
                let r = span.lowerBound..<after.range.upperBound
                return RawCandidate(range: r, kind: .percentage, value: p.value, unit: pair[0] == "basis" ? "bps" : "%")
            }
        }
        if multiplierWords.contains(next.core) { return RawCandidate(range: extended, kind: .multiplier, value: p.value, unit: "x") }
        if next.core.hasSuffix("-fold") || next.core == "fold" { return RawCandidate(range: extended, kind: .multiplier, value: p.value, unit: "x") }
        if let u = durationUnits[next.core] { return RawCandidate(range: extended, kind: .duration, value: p.value, unit: u) }
        if let u = countUnits[next.core] { return RawCandidate(range: extended, kind: .count, value: p.value, unit: u) }
        return nil
    }

    // MARK: Bare multipliers ("doubled")

    /// "doubled" / "tripled" / "halved" count only when a base is adjacent — a number phrase within
    /// four tokens on either side ("doubled to 4 million", "from 2 to 4 million, doubled"). The
    /// base need not be a figure itself: "4 million" alone is a bare number, but it is what makes
    /// "doubled" a quantity rather than a figure of speech.
    static func bareMultiplierCandidates(tokens: [Token], numeric: [RawCandidate]) -> [RawCandidate] {
        var out: [RawCandidate] = []
        for t in tokens {
            guard let v = bareMultipliers[t.core] else { continue }
            let window = max(0, t.index - 4)...min(tokens.count - 1, t.index + 4)
            let hasBase = window.contains { j in j != t.index && parseNumberPhrase(tokens, at: j) != nil }
            guard hasBase else { continue }
            out.append(RawCandidate(range: t.range, kind: .multiplier, value: v, unit: "x"))
        }
        return out
    }

    // MARK: Deadlines

    static func deadlineCandidates(text: String, tokens: [Token], excluded: [Range<Int>]) -> [RawCandidate] {
        var out: [RawCandidate] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in deadlinePattern.matches(in: text, range: full) {
            guard let r = characterRange(from: m.range, in: text), !overlapsExcluded(r, excluded) else { continue }
            out.append(RawCandidate(range: r, kind: .duration, value: nil, unit: "deadline"))
        }
        // A calendar date is a figure ONLY behind a deadline preposition: "by March 3rd" is a
        // commitment, "on March 3rd" is a diary entry. Clock times were excluded above.
        if let det = dateDetector {
            for m in det.matches(in: text, range: full) {
                guard let r = characterRange(from: m.range, in: text), !overlapsExcluded(r, excluded) else { continue }
                guard let tok = tokens.first(where: { $0.range.lowerBound == r.lowerBound || $0.range.contains(r.lowerBound) }),
                      tok.index > 0 else { continue }
                let prev = tokens[tok.index - 1]
                guard deadlinePrepositions.contains(prev.core), !prev.trailingBreak else { continue }
                let matched = ns.substring(with: m.range)
                guard !matched.contains(":"), !matched.lowercased().contains("am"), !matched.lowercased().contains("pm") else { continue }
                out.append(RawCandidate(range: prev.range.lowerBound..<r.upperBound, kind: .duration, value: nil, unit: "deadline"))
            }
        }
        return out
    }

    // MARK: Overlaps

    /// Longest match wins; on an exact tie, class priority; on a full tie, the earlier start.
    public static func resolveOverlaps(_ raws: [RawCandidate]) -> [RawCandidate] {
        let ordered = raws.sorted { a, b in
            if a.range.count != b.range.count { return a.range.count > b.range.count }
            if a.kind.priority != b.kind.priority { return a.kind.priority < b.kind.priority }
            return a.range.lowerBound < b.range.lowerBound
        }
        var chosen: [RawCandidate] = []
        for c in ordered where !chosen.contains(where: { $0.range.overlaps(c.range) }) {
            chosen.append(c)
        }
        return chosen
    }
}
