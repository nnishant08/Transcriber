import Foundation
import AppleArchive
import System

// MARK: - The `.said` session bundle
//
// One session, whole and self-contained, in one file: `transcript.md`, `session.json`, the audio
// and video it produced, `images/` if it has any, plus a `manifest.json` at the root.
//
// WHY A BUNDLE AT ALL. Until there is an account, moving a session between devices is a TRANSFER,
// not a sync — so the thing being moved should be an obvious, single object you can AirDrop, mail,
// or drop on the Dock. `SessionMeta.id` rides along inside `session.json`, which is what lets the
// receiving side tell "this is the session I already have" from "this is a new one".
//
// ARCHIVING: AppleArchive (macOS 11+ / iOS 14+), LZFSE. NOT `ditto`/`zip` — those need `Process`,
// which does not exist on iOS, and this code is shared. No new SPM dependency; AppleArchive and
// System are both system frameworks.
//
// ENCRYPTION: every read goes through `SessionIO.readData`, which transparently decrypts a
// `TRENC1`-prefixed file. A bundle therefore always contains PLAINTEXT, so the receiving device can
// actually open it — an export only its origin Mac's Keychain could read would be useless. On
// import, files are written back through `SessionIO.writeData`, so they are re-encrypted if (and
// only if) the receiving device has encryption on.

public struct SessionBundleManifest: Codable, Sendable {
    public var formatVersion: Int
    public var sessionID: UUID?
    public var createdAt: Date
    public var producedBy: String

    public static let currentFormatVersion = 1

    public init(formatVersion: Int = SessionBundleManifest.currentFormatVersion,
                sessionID: UUID?, createdAt: Date, producedBy: String) {
        self.formatVersion = formatVersion
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.producedBy = producedBy
    }
}

public enum SessionBundleError: Error, LocalizedError {
    case notASession(URL)
    case archiveFailed(String)
    case extractFailed(String)
    case badManifest(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notASession(let u):     return "\(u.lastPathComponent) is not a session folder (no transcript.md)."
        case .archiveFailed(let m):   return "Couldn't write the .said bundle: \(m)"
        case .extractFailed(let m):   return "Couldn't read the .said bundle: \(m)"
        case .badManifest(let m):     return "That .said file is missing or has a damaged manifest: \(m)"
        case .unsupportedVersion(let v): return "That .said file was written by a newer version of Said (format \(v))."
        }
    }
}

/// What an import did — the Mac surfaces the difference between "added" and "already had it".
public enum SessionImportOutcome: Sendable {
    case imported(URL)
    /// The store already holds a session with this `sessionID`. Deterministic by design: never
    /// import, never duplicate — point at the one that's already there.
    case alreadyPresent(URL)

    public var directory: URL {
        switch self {
        case .imported(let u), .alreadyPresent(let u): return u
        }
    }
    public var isDuplicate: Bool {
        if case .alreadyPresent = self { return true }
        return false
    }
}

public enum SessionBundle {

    public static let fileExtension = "said"
    public static let manifestName = "manifest.json"
    /// Present in a bundle ONLY when the sender explicitly opted in (see `write`). An older build of
    /// Said that does not know this filename simply installs it into the session folder and ignores
    /// it — degradation, not corruption, which is the same rule `formatVersion` is held at 1 for.
    public static let voiceprintsName = "voiceprints.json"

    // MARK: - Write

    /// Archive `sessionDir` into a `.said` file at `output`, injecting a manifest.
    ///
    /// The folder is staged into a temp directory first rather than archived in place, for two
    /// reasons: the manifest must appear INSIDE the archive without ever being written into the
    /// user's real session folder, and encrypted files have to be decrypted on the way in.
    /// - Parameter includingVoiceprints: carry the VOICE PROFILES of this session's speakers into
    ///   the bundle. **Defaults to false and must stay that way.** A voiceprint is biometric data;
    ///   the recipient could use it to identify those speakers in their own recordings, which is a
    ///   consequence the sender has to opt into knowingly rather than inherit from a share sheet.
    ///
    ///   The default is safe by construction rather than by remembering to filter: voiceprints live
    ///   in Application Support, and `stageDecrypted` copies the SESSION FOLDER, so there is nothing
    ///   to exclude. Including them requires this explicit injection.
    @discardableResult
    public static func write(sessionDir: URL, to output: URL,
                             includingVoiceprints: Bool = false) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionDir.appendingPathComponent("transcript.md").path) else {
            throw SessionBundleError.notASession(sessionDir)
        }

        let meta = DocumentBuilder.readSession(sessionDir)?.meta
        let staging = fm.temporaryDirectory
            .appendingPathComponent("said-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try stageDecrypted(from: sessionDir, into: staging)

        let manifest = SessionBundleManifest(sessionID: meta?.id,
                                             createdAt: meta?.date ?? Date(),
                                             producedBy: SaidAppInfo.producedBy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))

        if includingVoiceprints {
            // Only the voices that actually appear in THIS session, not the whole store — sharing
            // one meeting should not hand over every colleague the user has ever recorded.
            let slots = Set((DocumentBuilder.readSession(sessionDir)?.segments ?? []).compactMap(\.speaker))
            let names = Set(slots.compactMap { meta?.speakerNames?[String($0)] }
                                 .map { $0.lowercased() })
            let relevant = VoiceprintStore.all().filter { names.contains($0.name.lowercased()) }
            if !relevant.isEmpty, let data = try? encoder.encode(relevant) {
                try data.write(to: staging.appendingPathComponent(voiceprintsName))
            }
        }

        try? fm.removeItem(at: output)
        try archive(directory: staging, to: output)
        return output
    }

    /// Copy a session folder's contents, decrypting anything encrypted at rest so the bundle is
    /// readable on the receiving device. Directories (`images/`) are copied recursively.
    private static func stageDecrypted(from source: URL, into staging: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let dest = staging.appendingPathComponent(entry.lastPathComponent)
            if isDir {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try stageDecrypted(from: entry, into: dest)
            } else if try isEncryptedAtRest(entry) {
                // readData strips the TRENC1 wrapper so the bundle carries plaintext.
                try SessionIO.readData(entry).write(to: dest)
            } else {
                // Plain file (the default, since encryption is off): COPY it rather than round-trip
                // it through `Data`. A screen recording can be several GB, and reading one into
                // memory to write it straight back out is both slower and a real OOM risk.
                try fm.copyItem(at: entry, to: dest)
            }
        }
    }

    /// Whether a file on disk actually carries the `TRENC1` wrapper. Cheap: reads only the magic
    /// prefix, never the whole file — which is the point (see `stageDecrypted`).
    private static func isEncryptedAtRest(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return SessionIO.isEncryptedBlob(head)
    }

    // MARK: - Read

    /// Extract a `.said` bundle into `root`, honouring the collision rule.
    ///
    /// If a session with the same `sessionID` is already in `root`, nothing is written and the
    /// existing folder is returned as `.alreadyPresent`. Otherwise a new folder is created with the
    /// store's normal `<yyyy-MM-dd HH-mm-ss>` naming, the incoming id is preserved, and the session
    /// is indexed.
    @discardableResult
    public static func read(bundle: URL, into root: URL = SessionLocation.root) throws -> SessionImportOutcome {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("said-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try extract(archive: bundle, to: staging)

        // The archive may unpack either flat or under a single wrapper directory depending on how
        // it was produced; accept both rather than assuming.
        let payload = try locatePayload(in: staging)

        let manifest = try readManifest(at: payload.appendingPathComponent(manifestName))
        guard manifest.formatVersion <= SessionBundleManifest.currentFormatVersion else {
            throw SessionBundleError.unsupportedVersion(manifest.formatVersion)
        }
        guard fm.fileExists(atPath: payload.appendingPathComponent("transcript.md").path) else {
            throw SessionBundleError.extractFailed("the bundle has no transcript.md")
        }

        // Collision rule — deterministic: same id ⇒ don't import, don't duplicate.
        if let incoming = manifest.sessionID ?? DocumentBuilder.readSession(payload)?.meta.id,
           let existing = findSession(id: incoming, in: root) {
            return .alreadyPresent(existing)
        }

        let date = DocumentBuilder.readSession(payload)?.meta.date ?? manifest.createdAt
        let dest = DocumentBuilder.makeSessionFolder(date: date, root: root)
        try installPayload(from: payload, into: dest)

        // A bundle whose sender opted into sharing voice profiles: stage them for the user to
        // ACCEPT, never merge them into their store silently. "Never silently merged" is the rule
        // this is enforcing — the recipient is being handed biometric data about other people and
        // has to agree to keep it.
        let incomingVoices = payload.appendingPathComponent(voiceprintsName)
        if fm.fileExists(atPath: incomingVoices.path) {
            VoiceprintStore.stagePending(from: incomingVoices)
        }

        SearchIndex.shared.index(sessionDir: dest)
        SessionStore.postSessionSaved(dest)
        return .imported(dest)
    }

    /// Look up a session by its stable id. Linear over the store, which is the right cost here:
    /// imports are rare and human-initiated, and an index would be another thing to keep true.
    public static func findSession(id: UUID, in root: URL = SessionLocation.root) -> URL? {
        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            if DocumentBuilder.readSession(dir)?.meta.id == id { return dir }
        }
        return nil
    }

    /// The extracted payload root: either `staging` itself, or a lone wrapper directory inside it.
    private static func locatePayload(in staging: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appendingPathComponent(manifestName).path) { return staging }
        let entries = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if fm.fileExists(atPath: entry.appendingPathComponent(manifestName).path) { return entry }
        }
        throw SessionBundleError.badManifest("no \(manifestName) at the archive root")
    }

    private static func readManifest(at url: URL) throws -> SessionBundleManifest {
        guard let data = try? Data(contentsOf: url) else {
            throw SessionBundleError.badManifest("could not read \(manifestName)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(SessionBundleManifest.self, from: data) }
        catch { throw SessionBundleError.badManifest("\(error)") }
    }

    /// Copy the extracted payload into the destination session folder, minus the manifest (which is
    /// bundle metadata, not session state), writing through `SessionIO` so the receiving device's
    /// encryption setting is applied.
    private static func installPayload(from payload: URL, into dest: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])
        // `voiceprintsName` is excluded for a reason that outlasts this function: a voiceprint file
        // sitting INSIDE a session folder would be picked up by `stageDecrypted` and re-exported in
        // every future `.said` of that session — silently, with no opt-in. Keeping the store out of
        // session folders is the mechanism that makes the default safe, so the import path must not
        // be the thing that puts one there. It is handed to `VoiceprintStore.stagePending` instead.
        for entry in entries where entry.lastPathComponent != manifestName
                                && entry.lastPathComponent != voiceprintsName {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let target = dest.appendingPathComponent(entry.lastPathComponent)
            if isDir {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try installPayload(from: entry, into: target)
            } else if SessionIO.isEncryptionEnabled {
                // The receiving device encrypts at rest, so route the write through SessionIO.
                try SessionIO.writeData(Data(contentsOf: entry), to: target)
            } else {
                // Same reasoning as `stageDecrypted`: stream-copy rather than buffer whole files.
                try fm.copyItem(at: entry, to: target)
            }
        }
    }

    // MARK: - AppleArchive plumbing

    private static func archive(directory: URL, to output: URL) throws {
        let source = FilePath(directory.path)
        let dest = FilePath(output.path)
        guard let keys = ArchiveHeader.FieldKeySet.defaultForArchive as ArchiveHeader.FieldKeySet? else {
            throw SessionBundleError.archiveFailed("could not build the archive field key set")
        }
        do {
            try ArchiveByteStream.withFileStream(
                path: dest, mode: .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite, .groupRead, .otherRead]
            ) { file in
                try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { compressed in
                    guard let encoder = ArchiveStream.encodeStream(writingTo: compressed) else {
                        throw SessionBundleError.archiveFailed("could not open the encode stream")
                    }
                    defer { try? encoder.close() }
                    try encoder.writeDirectoryContents(archiveFrom: source, keySet: keys)
                }
            }
        } catch let e as SessionBundleError {
            throw e
        } catch {
            throw SessionBundleError.archiveFailed("\(error)")
        }
    }

    private static func extract(archive: URL, to directory: URL) throws {
        let source = FilePath(archive.path)
        let dest = FilePath(directory.path)
        do {
            try ArchiveByteStream.withFileStream(
                path: source, mode: .readOnly, options: [], permissions: []
            ) { file in
                guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
                    throw SessionBundleError.extractFailed("could not open the decompression stream")
                }
                defer { try? decompressed.close() }
                guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
                    throw SessionBundleError.extractFailed("could not open the decode stream")
                }
                defer { try? decoder.close() }
                guard let extractor = ArchiveStream.extractStream(extractingTo: dest) else {
                    throw SessionBundleError.extractFailed("could not open the extract stream")
                }
                defer { try? extractor.close() }
                _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
            }
        } catch let e as SessionBundleError {
            throw e
        } catch {
            throw SessionBundleError.extractFailed("\(error)")
        }
    }
}
