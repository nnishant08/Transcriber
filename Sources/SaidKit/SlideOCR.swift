import Foundation
import Vision
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Reading text off a slide
//
// **This is not the old `SlideOCR`.** The file of that name was deleted with the Visual Capture
// feature and this one was written fresh, deliberately smaller. The old one served a Mac feature
// that decided for itself when to grab the screen; this one is a thin, stateless Vision wrapper
// that Phase 3's camera capture composes. Nothing here captures anything, and nothing here decides
// when a frame should be taken.
//
// Cross-platform by construction: Vision, CoreImage and CoreGraphics all exist on iOS, and the
// currency is `CGImage` / `Data` throughout — never `NSImage` (Phase 1, §C3).
//
// On-device. `VNImageRequestHandler` performs locally; nothing is uploaded.

public enum SlideOCR {

    /// How recognized lines are joined into `FrameEvent.text`. Matches the form the removed feature
    /// used and the user guide documents, so an OCR'd frame reads the same wherever it came from.
    public static let lineSeparator = " · "

    /// Recognize text in an image.
    ///
    /// - Parameter fast: `.fast` for a live camera read-out (Phase 3 shows this before the shutter);
    ///   `.accurate` — the default — for the frame that actually lands on the timeline.
    /// - Returns: the recognized lines joined by `lineSeparator`, or **`nil`** when nothing was
    ///   found. Never an empty string, so `FrameEvent.text` stays honestly absent.
    public static func recognize(cgImage: CGImage, fast: Bool = false) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    NSLog("[SlideOCR] recognition failed: \(error)")
                    cont.resume(returning: nil)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                cont.resume(returning: lines.isEmpty ? nil : lines.joined(separator: lineSeparator))
            }
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = true
            // No custom words: a slide's vocabulary is arbitrary, and the session's own custom
            // vocabulary biases SPEECH decoding, which is a different problem.

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                NSLog("[SlideOCR] handler failed: \(error)")
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Perspective correction
    //
    // A phone photographs a slide from a seat, at an angle. Flattening the quad before OCR is what
    // makes the text readable. Phase 3 composes this; it is here because it is pure image work with
    // no UI and Phase 3 should not have to reimplement it.

    /// Find the slide's quad and flatten it.
    ///
    /// Returns the corrected image, or **the original unchanged** when no plausible quad is found.
    /// A capture is never lost to a failed correction — a slightly skewed slide still OCRs, whereas
    /// a bad crop loses the content entirely.
    public static func correctingPerspective(of cgImage: CGImage) async -> CGImage {
        guard let quad = await detectSlideQuad(in: cgImage) else { return cgImage }

        let ciImage = CIImage(cgImage: cgImage)
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        // Vision's normalized origin is bottom-left, which matches CoreImage's, so the corners map
        // across without a flip.
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return cgImage }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")

        guard let output = filter.outputImage,
              let corrected = CIContext().createCGImage(output, from: output.extent),
              corrected.width > 0, corrected.height > 0
        else { return cgImage }
        return corrected
    }

    /// The most plausible slide-shaped quad in the image, or nil.
    ///
    /// Tuned for "a rectangular slide filling a decent part of the frame": at least a fifth of the
    /// image, roughly landscape-to-square, and not wildly non-rectangular. A quad that fails these
    /// is more likely a table edge or a door frame than a slide, and cropping to it would be worse
    /// than doing nothing.
    public static func detectSlideQuad(in cgImage: CGImage) async -> VNRectangleObservation? {
        await withCheckedContinuation { (cont: CheckedContinuation<VNRectangleObservation?, Never>) in
            let request = VNDetectRectanglesRequest { request, error in
                if let error {
                    NSLog("[SlideOCR] rectangle detection failed: \(error)")
                    cont.resume(returning: nil)
                    return
                }
                let best = (request.results as? [VNRectangleObservation] ?? [])
                    .max { $0.confidence < $1.confidence }
                cont.resume(returning: best)
            }
            request.minimumAspectRatio = 0.4      // down to a tallish slide
            request.maximumAspectRatio = 1.0      // VNAspectRatio is height/width; 1.0 = square
            request.minimumSize = 0.2             // at least a fifth of the frame
            request.minimumConfidence = 0.6
            request.quadratureTolerance = 30      // degrees off-square, i.e. photographed at an angle
            request.maximumObservations = 8

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                NSLog("[SlideOCR] rectangle handler failed: \(error)")
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Encoding

    /// PNG bytes for a `CGImage`. PNG rather than JPEG because slides are flat colour and text —
    /// lossless keeps the OCR honest and compresses well on exactly this kind of content.
    public static func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The conventional filename for the `n`th frame in a session: `slide-0001.png`, zero-padded so
    /// the folder sorts correctly, monotonic within a session.
    public static func frameFilename(index: Int) -> String {
        String(format: "slide-%04d.png", max(1, index))
    }

    /// Relative path recorded in `FrameEvent.imagePath`.
    public static func frameRelativePath(index: Int) -> String {
        "images/" + frameFilename(index: index)
    }
}
