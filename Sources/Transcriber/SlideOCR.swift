import Foundation
import Vision
import CoreGraphics
import ImageIO

/// On-device OCR of captured frames via Apple's Vision framework. Runs locally — no network.
/// Recommended usage: batch over saved images during the final pass (off the live capture path).
enum SlideOCR {

    /// Recognize text in a CGImage. Returns the joined recognized lines (empty if none).
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[OCR] perform failed: \(error)")
            return ""
        }
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Recognize text in an image file on disk.
    static func recognize(fileURL: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            NSLog("[OCR] could not load image at \(fileURL.path)")
            return ""
        }
        return recognize(image)
    }

    /// Batch OCR a set of frame events (resolving each relative `imagePath` against `sessionDir`),
    /// returning copies with `ocrText` attached. Runs sequentially off the main thread.
    static func annotate(_ frames: [FrameEvent], sessionDir: URL) -> [FrameEvent] {
        frames.map { frame in
            var f = frame
            let url = sessionDir.appendingPathComponent(frame.imagePath)
            let text = recognize(fileURL: url)
            f.ocrText = text.isEmpty ? nil : text
            return f
        }
    }
}
