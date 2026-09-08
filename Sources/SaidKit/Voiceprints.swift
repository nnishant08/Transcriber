import Foundation
import FluidAudio

// MARK: - The stored identity

/// One person's stored voice, so "Speaker 1" can become "Alice" in a session recorded next week.
///
/// **This is biometric data and it is treated as the most sensitive thing Said has ever stored.**
/// It lives in Application Support, never in a session folder — which is not a filing preference
/// but the mechanism that keeps it out of a `.said` bundle by default, since `SessionBundle` stages
/// a session folder's entire contents rather than an allow-list. Getting a voiceprint into a bundle
/// requires an explicit, separately-confirmed opt-in (`SessionBundle.write(includingVoiceprints:)`).
public struct Voiceprint: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    /// Several embeddings per person, not one averaged vector. A voice recorded on AirPods in a car
    /// and on a desk mic in a quiet room lands in genuinely different places; averaging them
    /// produces a centroid that matches neither well, whereas keeping both and matching against the
    /// nearest is what makes the second recording recognisable at all.
    public var embeddings: [[Float]]
    public let createdAt: Date
    public var updatedAt: Date
    public var sessionCount: Int

    public init(id: UUID = UUID(), name: String, embeddings: [[Float]],
                createdAt: Date = Date(), updatedAt: Date = Date(), sessionCount: Int = 1) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionCount = sessionCount
    }
}

/// One stored voice the matcher considered, with how far away it was.
public struct VoiceprintCandidate: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let distance: Float

    public init(id: UUID, name: String, distance: Float) {
        self.id = id
        self.name = name
        self.distance = distance
    }
}

/// What the matcher concluded about one speaker slot.
public enum VoiceprintMatch: Sendable, Equatable {
    /// Close enough to one stored voice, and clearly closer to it than to any other.
    case proposal(VoiceprintCandidate)
    /// Within range of more than one stored voice, with no clear winner. **Asks; never picks.**
    case ambiguous([VoiceprintCandidate])
    /// Nothing close enough.
    case none
}

// MARK: - Matching

/// The pure matching rules. No I/O, no models — `--selftest-voiceprint` asserts every branch with
/// synthetic vectors.
public enum VoiceprintMatcher {

    /// Maximum cosine DISTANCE at which a stored voice may be proposed. Lower is stricter.
    ///
    /// Measured in exactly the units FluidAudio clusters in (`SpeakerUtilities.cosineDistance`), so
    /// this number is directly comparable to the diarizer's own `clusteringThreshold` of 0.7 — and
    /// it is deliberately far tighter than that, for two reasons:
    ///
    /// 1. **The task is harder.** 0.7 separates speakers *within one recording*, where the mic, the
    ///    room and the day are constant. Cross-session matching has none of that held fixed.
    /// 2. **The costs are wildly asymmetric.** A missed match costs one click. A false merge
    ///    silently attributes one person's words to another, and in a legal or clinical session that
    ///    is a serious harm that nobody may ever notice. So the threshold is set where misses are
    ///    expected and false merges are not.
    ///
    /// **Tuned, not derived.** WeSpeaker same-speaker pairs typically sit around 0.1–0.4 distance
    /// and different-speaker pairs around 0.7–1.0; 0.45 sits inside that gap, nearer the safe side.
    /// It wants empirical tuning on real multi-session recordings — see `PHASE3-REPORT.md`.
    public static let maxDistance: Float = 0.45

    /// How much closer the best candidate must be than the runner-up to be proposed at all.
    ///
    /// Without this, two people with similar voices produce a coin-flip that reads to the user as
    /// confidence. Inside this margin the answer is `.ambiguous`, which asks.
    public static let ambiguityMargin: Float = 0.08

    /// Distance from one embedding to a voiceprint = the distance to its NEAREST stored embedding.
    /// Nearest, not mean: see `Voiceprint.embeddings` for why several are kept.
    public static func distance(from embedding: [Float], to print: Voiceprint) -> Float {
        var best = Float.greatestFiniteMagnitude
        for candidate in print.embeddings where candidate.count == embedding.count {
            // `SpeakerUtilities`, NOT `SpeakerOperations` — the FILE is SpeakerOperations.swift but
            // the type inside it is `public enum SpeakerUtilities` (FluidAudio 0.15.2). The
            // identifier `SpeakerOperations` does not exist anywhere in the dependency's sources.
            best = min(best, SpeakerUtilities.cosineDistance(embedding, candidate))
        }
        return best
    }

    /// Match one speaker slot's embeddings against the store.
    ///
    /// The slot's own embeddings are reduced by taking the BEST (smallest) distance across them: if
    /// any clean sample of this speaker matches a stored voice, that is evidence, and averaging it
    /// with a noisy sample from the same slot would only dilute it.
    public static func match(embeddings: [[Float]], against store: [Voiceprint]) -> VoiceprintMatch {
        guard !embeddings.isEmpty, !store.isEmpty else { return .none }

        var scored: [VoiceprintCandidate] = []
        for print in store {
            let d = embeddings.map { distance(from: $0, to: print) }.min() ?? .greatestFiniteMagnitude
            if d.isFinite { scored.append(VoiceprintCandidate(id: print.id, name: print.name, distance: d)) }
        }
        let within = scored.filter { $0.distance <= maxDistance }.sorted { $0.distance < $1.distance }
        guard let best = within.first else { return .none }
        if within.count > 1, within[1].distance - best.distance < ambiguityMargin {
            return .ambiguous(Array(within.prefix(3)))
        }
        return .proposal(best)
    }
}

// MARK: - The store

/// `voiceprints.json` in Application Support — never in a session folder.
///
/// Routed through `SessionIO`, so when at-rest encryption is on the voiceprint store is encrypted
/// with everything else. It would be incoherent to encrypt a transcript and leave the biometric
/// data that identifies its speakers in plaintext beside it.
public enum VoiceprintStore {

    /// OFF by default. With the feature off nothing here is ever called: no embedding is extracted,
    /// no file is created, and `session.json` gains no keys.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceprintsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceprintsEnabled") }
    }

    public static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Said", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiceprints.json")
    }

    /// Test hook — self-tests point the store at a temp dir rather than the user's real one.
    public static var overrideStoreURL: URL?
    static var activeURL: URL { overrideStoreURL ?? storeURL }

    public static func all() -> [Voiceprint] {
        let u = activeURL
        guard FileManager.default.fileExists(atPath: u.path),
              let data = try? SessionIO.readData(u),
              let list = try? JSONDecoder().decode([Voiceprint].self, from: data) else { return [] }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ list: [Voiceprint]) {
        guard !list.isEmpty else { deleteAll(); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? SessionIO.writeData(data, to: activeURL)
    }

    /// Enroll a new voice, or add samples to an existing one.
    ///
    /// **Never merges two existing voiceprints** (§7.4). If a new sample matches two people, the
    /// caller has already been told `.ambiguous` and has asked the user; this function only ever
    /// attaches samples to the ONE identity it is given.
    @discardableResult
    public static func enroll(name: String, embeddings: [[Float]], existing id: UUID? = nil,
                              now: Date = Date()) -> Voiceprint? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embeddings.isEmpty else { return nil }
        var list = all()

        if let id, let i = list.firstIndex(where: { $0.id == id }) {
            list[i].embeddings.append(contentsOf: embeddings)
            // Keep the store bounded. More samples improve matching with diminishing returns, and an
            // unbounded list would make every match slower forever.
            if list[i].embeddings.count > maxSamplesPerVoice {
                list[i].embeddings = Array(list[i].embeddings.suffix(maxSamplesPerVoice))
            }
            list[i].name = trimmed
            list[i].updatedAt = now
            list[i].sessionCount += 1
            save(list)
            return list[i]
        }

        let print = Voiceprint(name: trimmed, embeddings: Array(embeddings.prefix(maxSamplesPerVoice)),
                               createdAt: now, updatedAt: now, sessionCount: 1)
        list.append(print)
        save(list)
        return print
    }

    /// Samples kept per person. Enough for several recording conditions; few enough that matching
    /// stays instant and the file stays small.
    public static let maxSamplesPerVoice = 12

    public static func rename(id: UUID, to name: String) {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        list[i].updatedAt = Date()
        save(list)
    }

    /// Delete one voice. Immediate and complete — the samples are gone from disk, not tombstoned.
    public static func delete(id: UUID) {
        let remaining = all().filter { $0.id != id }
        if remaining.isEmpty { deleteAll() } else { save(remaining) }
    }

    /// Delete every voice. The file itself is removed, so "delete all" leaves nothing behind rather
    /// than an empty container that still says a store existed.
    public static func deleteAll() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    public static func match(embeddings: [[Float]]) -> VoiceprintMatch {
        VoiceprintMatcher.match(embeddings: embeddings, against: all())
    }

    // MARK: Voices arriving in a `.said`

    /// Where voice profiles from an imported bundle wait for the user's decision. Separate from the
    /// real store on purpose: until the user accepts, these are someone else's data that happens to
    /// be on this machine, not part of this user's library.
    static var pendingURL: URL {
        activeURL.deletingLastPathComponent().appendingPathComponent("pending-voiceprints.json")
    }

    /// Park voice profiles that arrived in a bundle. Overwrites any previous pending set — the user
    /// is being asked about the import they just did, not a queue of old ones.
    static func stagePending(from file: URL) {
        guard let data = try? Data(contentsOf: file),
              let incoming = try? JSONDecoder().decode([Voiceprint].self, from: data),
              !incoming.isEmpty else { return }
        try? SessionIO.writeData(data, to: pendingURL)
        NSLog("[Voiceprint] \(incoming.count) voice profile(s) arrived in a bundle, awaiting confirmation")
    }

    /// Voice profiles waiting for a decision, if any.
    public static func pending() -> [Voiceprint] {
        guard FileManager.default.fileExists(atPath: pendingURL.path),
              let data = try? SessionIO.readData(pendingURL),
              let list = try? JSONDecoder().decode([Voiceprint].self, from: data) else { return [] }
        return list
    }

    /// Accept the pending voices into the store.
    ///
    /// A name that already exists gains the incoming samples rather than creating a second entry
    /// with the same label — but it is still not a MERGE of two identities: the user has just said
    /// these are the same person by accepting a name they already use. Two *stored* voiceprints are
    /// never merged with each other automatically, under any circumstances.
    public static func acceptPending() {
        let incoming = pending()
        guard !incoming.isEmpty else { return }
        var list = all()
        for v in incoming {
            if let i = list.firstIndex(where: { $0.name.lowercased() == v.name.lowercased() }) {
                list[i].embeddings.append(contentsOf: v.embeddings)
                if list[i].embeddings.count > maxSamplesPerVoice {
                    list[i].embeddings = Array(list[i].embeddings.suffix(maxSamplesPerVoice))
                }
                list[i].updatedAt = Date()
            } else {
                list.append(v)
            }
        }
        save(list)
        discardPending()
    }

    public static func discardPending() {
        try? FileManager.default.removeItem(at: pendingURL)
    }
}

// MARK: - The post-save pass

/// A speaker slot the matcher has something to say about, cached in `session.json` so the Viewer can
/// show the proposal when the user next opens the session — the pass runs off the save path and the
/// user is usually not looking at the session when it finishes.
public struct VoiceprintProposal: Codable, Sendable, Equatable {
    public var slot: Int
    public var voiceprintID: UUID?
    public var name: String
    public var distance: Float
    /// True when more than one stored voice was in range — the Viewer must ASK, not offer a default.
    public var isAmbiguous: Bool
    /// The alternatives, for an ambiguous proposal.
    public var alternatives: [String]

    public init(slot: Int, voiceprintID: UUID?, name: String, distance: Float,
                isAmbiguous: Bool, alternatives: [String] = []) {
        self.slot = slot
        self.voiceprintID = voiceprintID
        self.name = name
        self.distance = distance
        self.isAmbiguous = isAmbiguous
        self.alternatives = alternatives
    }
}

/// Runs after diarization + alignment, in the same serial post-save chain, never on the save path.
///
/// **A match is a proposal, never an assignment** (§7.4). This pass writes `meta.voiceprintProposals`
/// and nothing else — it does not set `speakerNames`, does not re-render `transcript.md`, and does
/// not touch the search index. The user confirms in the Viewer, and only then is a name applied and
/// the new embedding appended to that voiceprint.
public enum VoiceprintPass {

    public static func run(dir: URL, embeddings: [Int: [[Float]]]) async {
        guard VoiceprintStore.isEnabled, !embeddings.isEmpty else { return }
        let store = VoiceprintStore.all()
        guard !store.isEmpty else { return }   // nothing enrolled yet — nothing to propose

        var proposals: [VoiceprintProposal] = []
        for (slot, vectors) in embeddings.sorted(by: { $0.key < $1.key }) {
            switch VoiceprintMatcher.match(embeddings: vectors, against: store) {
            case .proposal(let c):
                proposals.append(VoiceprintProposal(slot: slot, voiceprintID: c.id, name: c.name,
                                                    distance: c.distance, isAmbiguous: false))
            case .ambiguous(let candidates):
                guard let first = candidates.first else { continue }
                proposals.append(VoiceprintProposal(slot: slot, voiceprintID: nil, name: first.name,
                                                    distance: first.distance, isAmbiguous: true,
                                                    alternatives: candidates.map(\.name)))
            case .none:
                continue
            }
        }
        guard !proposals.isEmpty else { return }

        // Merge onto a fresh read, like every other post-save pass, so a concurrent writer's fields
        // are not clobbered.
        guard var doc = DocumentBuilder.readSession(dir) else { return }
        doc.meta.voiceprintProposals = proposals
        DocumentBuilder.writeSessionJSON(doc, to: dir)
        SessionStore.postSessionSaved(dir)
        NSLog("[Voiceprint] \(proposals.count) proposal(s) for \(dir.lastPathComponent)")
    }
}
