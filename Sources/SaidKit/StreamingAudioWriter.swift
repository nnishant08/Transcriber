import Foundation

/// Writes capture samples to disk AS THEY ARRIVE, so a recording survives the app being killed.
///
/// **Why this exists.** Until now audio lived in `SampleSink` — an in-memory `[Float]` — and was
/// written once, at stop. That is fine on a Mac, where the app is rarely killed under it. On a phone
/// it fails twice: iOS terminates backgrounded apps at will, and a 90-minute session is ~345 MB of
/// Float32 held in RAM, which is a jetsam risk on its own.
///
/// **Format: raw little-endian Float32, 16 kHz mono.** Deliberately not CAF or M4A during capture.
/// A container's header records the frame count, so a process killed mid-write leaves a file whose
/// header disagrees with its contents — exactly the case this class exists to survive. A raw file
/// has no header to be wrong: a truncated one is simply fewer samples, and `count = bytes / 4`. The
/// compact `.m4a` is produced at `finish()`, from the raw file, through the existing `AudioFileIO`
/// path — so the saved artifact is byte-identical in kind to what the Mac writes.
///
/// **This is additive.** The Mac never constructs one; its save path is unchanged.
public final class StreamingAudioWriter: SampleReceiver, @unchecked Sendable {

    /// The in-progress raw file inside the session folder. Its presence with no `audio.m4a` is what
    /// marks a session as unfinished (see `RecoverableSession`).
    public static let rawFilename = "recording.pcm"

    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int = 0
    private let url: URL

    /// Samples buffered in memory before a write. At 16 kHz this flushes about twice a second —
    /// often enough that a kill loses a negligible tail, rarely enough not to syscall per buffer.
    private static let flushThreshold = 8_000
    private var pending: [Float] = []

    public private(set) var isOpen = false

    /// Open (or re-open, appending) the raw file inside `sessionDir`.
    public init(sessionDir: URL) throws {
        self.url = sessionDir.appendingPathComponent(Self.rawFilename)
        let fm = FileManager.default
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        written = Int((try? h.offset()) ?? 0) / MemoryLayout<Float>.size
        isOpen = true
    }

    /// Samples arrive here from the capture chain, POST-gate — so a paused stretch is absent from
    /// the file exactly as it is absent from `SampleSink`, and the two stay in lockstep.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: samples)
        let due = pending.count >= Self.flushThreshold
        lock.unlock()
        if due { flush() }
    }

    /// Push buffered samples to the file. Safe to call at any time.
    public func flush() {
        lock.lock()
        guard isOpen, !pending.isEmpty, let handle else { lock.unlock(); return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        batch.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let data = Data(bytes: base, count: buf.count * MemoryLayout<Float>.size)
            do { try handle.write(contentsOf: data) }
            catch { NSLog("[AudioWriter] write failed: \(error)") }
        }
        lock.lock(); written += batch.count; lock.unlock()
    }

    /// Samples committed to disk so far.
    public var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return written }
    public var seconds: Double { Double(sampleCount) / 16_000 }

    /// Flush, close, and convert the raw file into the session's compact `audio.m4a`.
    ///
    /// - Parameter keepRaw: leave the `.pcm` in place (self-tests only). Normally it is removed —
    ///   it is 4× the size of the m4a and has served its purpose.
    /// - Returns: the written audio URL, or nil when there was nothing worth keeping.
    @discardableResult
    public func finish(keepRaw: Bool = false) -> URL? {
        flush()
        lock.lock()
        try? handle?.close()
        handle = nil
        isOpen = false
        lock.unlock()
        return Self.convertRaw(at: url, keepRaw: keepRaw)
    }

    /// Convert a raw capture file into `audio.m4a` beside it. Used by `finish()` and by recovery.
    @discardableResult
    public static func convertRaw(at rawURL: URL, keepRaw: Bool = false) -> URL? {
        let fm = FileManager.default
        guard let samples = readRaw(at: rawURL), samples.count > 1_600 else {
            if !keepRaw { try? fm.removeItem(at: rawURL) }
            return nil
        }
        let out = rawURL.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        guard let written = try? AudioFileIO.writeCompactAudio(samples, to: out) else { return nil }
        if !keepRaw { try? fm.removeItem(at: rawURL) }
        return written
    }

    /// Read a raw capture file back into samples. Tolerates a trailing partial sample, which is
    /// what a process killed mid-write leaves behind.
    public static func readRaw(at rawURL: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: rawURL), data.count >= MemoryLayout<Float>.size else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, from: 0..<(count * MemoryLayout<Float>.size))
        }
        return out
    }
}

/// State persisted alongside a live recording so a cold launch can finish what a kill interrupted.
///
/// Written periodically during capture and deleted on a clean stop. Its presence at launch is the
/// signal that a session needs recovering.
public struct RecoveryState: Codable, Sendable, Equatable {
    public static let filename = "recovery.json"

    public var sessionID: UUID?
    /// Wall-clock start, so a recovered session lands at the right date in the library.
    public var startedAt: Date
    /// Accumulated paused time, so the recovered transcript's timestamps stay on the same
    /// pause-compressed clock the audio was recorded against.
    public var accumulatedPause: TimeInterval
    public var sourceLabel: String
    public var modelName: String
    public var language: String?

    public init(sessionID: UUID?, startedAt: Date, accumulatedPause: TimeInterval,
                sourceLabel: String, modelName: String, language: String? = nil) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.accumulatedPause = accumulatedPause
        self.sourceLabel = sourceLabel
        self.modelName = modelName
        self.language = language
    }

    public func write(to sessionDir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? SessionIO.writeData(data, to: sessionDir.appendingPathComponent(Self.filename))
    }

    public static func read(from sessionDir: URL) -> RecoveryState? {
        guard let data = try? SessionIO.readData(sessionDir.appendingPathComponent(Self.filename)) else { return nil }
        return try? JSONDecoder().decode(RecoveryState.self, from: data)
    }

    public static func clear(in sessionDir: URL) {
        try? FileManager.default.removeItem(at: sessionDir.appendingPathComponent(Self.filename))
    }
}

/// Finds sessions that were interrupted mid-recording.
public enum RecoveryScanner {

    /// Session folders under `root` carrying recovery state — i.e. a recording that never stopped
    /// cleanly. Oldest first, so recovering several is deterministic.
    public static func unfinishedSessions(root: URL = SessionLocation.root) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                && fm.fileExists(atPath: url.appendingPathComponent(RecoveryState.filename).path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
