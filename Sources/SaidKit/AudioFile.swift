import Foundation
import AVFoundation

enum AudioIOError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case emptyBuffer
    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "The file has no decodable audio track."
        case .readerFailed(let m): return "Audio reader failed: \(m)"
        case .emptyBuffer: return "There were no audio samples to write."
        }
    }
}

/// Decode arbitrary audio/video files to the canonical 16 kHz mono Float32 buffer, and write that
/// buffer back out to a compact file — both converging on the same `Resampler16k` the live capture
/// path uses, so the format invariant is identical everywhere. (Verified APIs; AVAudioFile opens
/// audio containers, AVAssetReader handles .mp4/.mov; AVAudioFile(forWriting:) encodes to AAC.)
public enum AudioFileIO {

    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "caf"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    public static func isSupported(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased(); return audioExtensions.contains(e) || videoExtensions.contains(e)
    }

    // MARK: Decode → 16 kHz mono Float32

    /// AVAudioFile opens .wav/.caf/.aiff/.m4a/.aac/.mp3 directly; .mp4/.mov (and anything AVAudioFile
    /// rejects) fall through to AVAssetReader. Both push through `Resampler16k` → 16 kHz mono Float32.
    public static func decodeTo16kMono(url: URL) async throws -> [Float] {
        if let file = try? AVAudioFile(forReading: url) {
            return try decodeViaAVAudioFile(file)
        }
        return try await decodeViaAssetReader(url: url)
    }

    private static func decodeViaAVAudioFile(_ file: AVAudioFile) throws -> [Float] {
        let resampler = Resampler16k()
        let fmt = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(fmt.sampleRate, 16_000))   // ~1 s chunks
        var out: [Float] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            if let samples = resampler.resample(buf) { out.append(contentsOf: samples) }
        }
        return out
    }

    private static func decodeViaAssetReader(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioIOError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioIOError.readerFailed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioIOError.readerFailed(reader.error?.localizedDescription ?? "startReading returned false")
        }

        let resampler = Resampler16k()
        var out: [Float] = []
        while reader.status == .reading {
            guard let sbuf = output.copyNextSampleBuffer() else { break }
            if let pcm = sbuf.asPCMBuffer, let samples = resampler.resample(pcm) { out.append(contentsOf: samples) }
            CMSampleBufferInvalidate(sbuf)
        }
        if reader.status == .failed {
            throw AudioIOError.readerFailed(reader.error?.localizedDescription ?? "unknown reader failure")
        }
        return out
    }

    // MARK: Write 16 kHz mono Float32 → compact file

    /// Wrap a 16 kHz mono Float32 `[Float]` as an AVAudioPCMBuffer in the canonical capture format.
    public static func makeBuffer16kMono(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let format = Resampler16k.outputFormat
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in channel[0].update(from: src.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Write samples to a compact AAC `.m4a` (falls back to LPCM `.caf` if AAC encode is unavailable).
    /// Returns the URL actually written (extension may differ on fallback).
    @discardableResult
    public static func writeCompactAudio(_ samples: [Float], to url: URL) throws -> URL {
        guard let buffer = makeBuffer16kMono(samples) else { throw AudioIOError.emptyBuffer }
        let m4aURL = url.pathExtension.lowercased() == "m4a" ? url
            : url.deletingPathExtension().appendingPathExtension("m4a")
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let file = try AVAudioFile(forWriting: m4aURL, settings: aacSettings)
            try file.write(from: buffer)
            return m4aURL
        } catch {
            let cafURL = url.deletingPathExtension().appendingPathExtension("caf")
            let lpcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: cafURL, settings: lpcm)
            try file.write(from: buffer)
            return cafURL
        }
    }

}

// MARK: - Mic + System mixer

/// Sums two 16 kHz mono streams (mic + system) into one shared `SampleSink` for the `.micPlusSystem`
/// source. Each capture pushes into its `Port` (a `SampleReceiver`); the mixer aligns by sample index
/// (both streams start ~T0), sums with headroom + a hard limiter, and forwards mixed audio to the sink
/// so the existing single `StreamingTranscriber`/`finalPass` run unchanged downstream.
public final class AudioMixer: @unchecked Sendable {
    /// A `SampleReceiver` endpoint handed to one capture source.
    public final class Port: SampleReceiver, @unchecked Sendable {
        fileprivate weak var mixer: AudioMixer?
        fileprivate let isMic: Bool
        init(mixer: AudioMixer, isMic: Bool) { self.mixer = mixer; self.isMic = isMic }
        public func append(_ samples: [Float]) { mixer?.ingest(samples, isMic: isMic) }
    }

    private let out: any SampleReceiver
    private let lock = NSLock()
    private var micBuf: [Float] = []
    private var sysBuf: [Float] = []
    private let gain: Float = 0.85   // headroom so the sum of two speech streams rarely needs limiting

    public private(set) lazy var micPort = Port(mixer: self, isMic: true)
    public private(set) lazy var systemPort = Port(mixer: self, isMic: false)

    public init(out: any SampleReceiver) { self.out = out }

    private func ingest(_ samples: [Float], isMic: Bool) {
        // The mic tap thread and the SCStream audio queue both call this concurrently. The append to
        // `out` must happen INSIDE the lock so the sink's append order matches the consume order —
        // otherwise two ingests can consume ranges A then B but append B before A, scrambling the PCM
        // at chunk boundaries. SampleSink.append takes its own separate lock (no reverse acquisition),
        // so this nesting can't deadlock.
        lock.lock()
        defer { lock.unlock() }
        if isMic { micBuf.append(contentsOf: samples) } else { sysBuf.append(contentsOf: samples) }
        let n = min(micBuf.count, sysBuf.count)
        guard n > 0 else { return }
        var mixed = [Float](); mixed.reserveCapacity(n)
        for i in 0..<n { mixed.append(limit((micBuf[i] + sysBuf[i]) * gain)) }
        micBuf.removeFirst(n); sysBuf.removeFirst(n)
        out.append(mixed)
    }

    /// On stop: emit the un-mixed tail of whichever stream got ahead (the other has ended) so no
    /// audio is dropped. Safe to call once after both captures stopped.
    public func flush() {
        lock.lock()
        let n = min(micBuf.count, sysBuf.count)
        var result: [Float] = []
        if n > 0 { for i in 0..<n { result.append(limit((micBuf[i] + sysBuf[i]) * gain)) } }
        let surplus = micBuf.count > sysBuf.count ? Array(micBuf[n...]) : Array(sysBuf[n...])
        for s in surplus { result.append(limit(s * gain)) }
        micBuf.removeAll(); sysBuf.removeAll()
        lock.unlock()
        if !result.isEmpty { out.append(result) }
    }

    private func limit(_ x: Float) -> Float { max(-1, min(1, x)) }
}
