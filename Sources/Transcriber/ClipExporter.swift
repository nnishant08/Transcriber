import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Feature A creator export — on-device audio clips + audiograms. Fully local (AVFoundation +
/// Core Graphics); nothing leaves the Mac. Reuses the tested `AudioFileIO` decode/write path for the
/// audio clip, then renders a static waveform image and muxes it with the clip audio into an `.mp4`.
///
/// OUT OF SCOPE (hook only): full video-clip compositing (screen/slide video). Audiograms are a
/// still waveform + audio — the simple, robust on-device form.
enum ClipExportError: LocalizedError {
    case emptyRange, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .emptyRange: return "The selected range has no audio."
        case .writeFailed(let m): return "Clip export failed: \(m)"
        }
    }
}

struct ClipResult: Sendable { var url: URL; var duration: Double }

enum ClipExporter {

    // MARK: Audio clip

    /// Extract `[start, end)` seconds of `audioURL` into a compact `.m4a` at `output`. Decodes to the
    /// canonical 16 kHz mono buffer (same path live capture uses), slices, and writes via `AudioFileIO`.
    @discardableResult
    static func exportClip(audioURL: URL, start: Double, end: Double, to output: URL) async throws -> ClipResult {
        let samples = try await AudioFileIO.decodeTo16kMono(url: audioURL)
        let sliced = slice(samples, start: start, end: end)
        guard !sliced.isEmpty else { throw ClipExportError.emptyRange }
        let written = try AudioFileIO.writeCompactAudio(sliced, to: output)
        return ClipResult(url: written, duration: Double(sliced.count) / 16_000.0)
    }

    private static func slice(_ samples: [Float], start: Double, end: Double) -> [Float] {
        let sr = 16_000.0
        let lo = max(0, min(samples.count, Int(start * sr)))
        let hi = max(lo, min(samples.count, Int(max(start, end) * sr)))
        return Array(samples[lo..<hi])
    }

    // MARK: Waveform image

    /// Render a static waveform (RMS bars) of `samples` into a CGImage, with an optional burned-in
    /// caption. On-device Core Graphics; no network, no fonts beyond the system font.
    static func renderWaveform(samples: [Float], size: CGSize = CGSize(width: 1280, height: 720),
                               caption: String? = nil) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Background (dark, on-brand indigo wash).
        ctx.setFillColor(CGColor(red: 0.114, green: 0.118, blue: 0.125, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // RMS bins.
        let barCount = max(16, min(w / 6, 220))
        let bins = rmsBins(samples, count: barCount)
        let mid = CGFloat(h) * 0.5
        let usableH = CGFloat(h) * 0.62
        let gap: CGFloat = 2
        let barW = (CGFloat(w) - gap * CGFloat(barCount)) / CGFloat(barCount)
        ctx.setFillColor(CGColor(red: 0.494, green: 0.463, blue: 0.925, alpha: 1))   // accent indigo
        for (i, level) in bins.enumerated() {
            let barH = max(2, CGFloat(level) * usableH)
            let x = CGFloat(i) * (barW + gap)
            let rect = CGRect(x: x, y: mid - barH / 2, width: max(1, barW), height: barH)
            ctx.fill(rect)
        }

        // Caption (burned-in), bottom area.
        if let caption, !caption.trimmingCharacters(in: .whitespaces).isEmpty {
            drawCaption(caption, in: ctx, size: size)
        }
        return ctx.makeImage()
    }

    private static func rmsBins(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return Array(repeating: 0, count: count) }
        let per = max(1, samples.count / count)
        var bins: [Float] = []
        var i = 0
        while i < samples.count && bins.count < count {
            let end = min(samples.count, i + per)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            bins.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        while bins.count < count { bins.append(0) }
        let peak = max(bins.max() ?? 1, 0.0001)
        return bins.map { min(1, $0 / peak) }
    }

    private static func drawCaption(_ text: String, in ctx: CGContext, size: CGSize) {
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.height * 0.045, weight: .medium),
            .foregroundColor: NSColor(white: 0.95, alpha: 1),
            .paragraphStyle: para,
        ]
        let inset: CGFloat = size.width * 0.06
        let rect = CGRect(x: inset, y: size.height * 0.06, width: size.width - inset * 2, height: size.height * 0.26)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        NSAttributedString(string: String(text.prefix(240)), attributes: attrs).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Audiogram (.mp4 = still waveform video + clip audio)

    /// Build an `.mp4` audiogram for `[start, end)` of `audioURL`: extract the clip, render a waveform
    /// (with optional caption), make a still-image video of that length, and mux the two. On-device.
    @discardableResult
    static func exportAudiogram(audioURL: URL, start: Double, end: Double,
                                caption: String? = nil, to output: URL) async throws -> URL {
        // 1) Audio clip (temp .m4a).
        let clipURL = output.deletingPathExtension().appendingPathExtension("clip.m4a")
        let clip = try await exportClip(audioURL: audioURL, start: start, end: end, to: clipURL)
        defer { try? FileManager.default.removeItem(at: clip.url) }

        // 2) Waveform image from the same slice.
        let all = try await AudioFileIO.decodeTo16kMono(url: audioURL)
        let slice = slice(all, start: start, end: end)
        guard let image = renderWaveform(samples: slice, caption: caption) else {
            throw ClipExportError.writeFailed("waveform render failed")
        }

        // 3) Still-image video (temp .mov), then compose video + audio → output .mp4.
        let stillURL = output.deletingPathExtension().appendingPathExtension("still.mov")
        defer { try? FileManager.default.removeItem(at: stillURL) }
        try await writeStillVideo(image: image, duration: max(0.5, clip.duration), to: stillURL)
        try await compose(videoURL: stillURL, audioURL: clip.url, to: output)
        return output
    }

    /// Write a video that shows `image` for `duration` seconds (AVAssetWriter, H.264, ~5 fps).
    private static func writeStillVideo(image: CGImage, duration: Double, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = image.width, h = image.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw ClipExportError.writeFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw ClipExportError.writeFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        guard let pb = pixelBuffer(from: image, w: w, h: h) else { throw ClipExportError.writeFailed("pixel buffer") }
        let fps: Int32 = 5
        let frames = max(1, Int(duration * Double(fps)))
        for i in 0...frames {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status == .failed { throw ClipExportError.writeFailed(writer.error?.localizedDescription ?? "video write failed") }
    }

    /// Compose a video-only file + an audio-only file into one `.mp4` via AVMutableComposition.
    private static func compose(videoURL: URL, audioURL: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        let aAsset = AVURLAsset(url: audioURL)
        let vTracks = try await vAsset.loadTracks(withMediaType: .video)
        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
        guard let vSrc = vTracks.first else { throw ClipExportError.writeFailed("no video track") }
        let vDur = try await vAsset.load(.duration)

        if let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        }
        if let aSrc = aTracks.first,
           let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = try await aAsset.load(.duration)
            let dur = CMTimeMinimum(aDur, vDur)
            try aDst.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aSrc, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipExportError.writeFailed("no export session")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        if export.status != .completed {
            throw ClipExportError.writeFailed(export.error?.localizedDescription ?? "composition export failed")
        }
    }

    private static func pixelBuffer(from image: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32ARGB,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
