import Foundation
import CoreGraphics

// MARK: - Visual-capture tunables
// Named here at the top so they're easy to find; surfaced in Settings where it makes sense.
enum VisualConstants {
    static let changeThreshold = 12          // /64 bits — "something changed" vs last saved frame
    static let stableThreshold = 3           // /64 bits — consecutive frames "settled"
    static let stableWindow: TimeInterval = 1.0   // sustained stability before capturing
    static let minInterval: TimeInterval = 2.0    // anti-burst between auto-captures
    static let frameRateFPS: Int32 = 2       // SCStreamConfiguration.minimumFrameInterval
    static let maxImages = 500               // per-session disk cap
    static let intervalDefault: TimeInterval = 15 // "Every N seconds" mode default
    static let thumbnailMaxDim: CGFloat = 240
}

// MARK: - Perceptual hash (dHash)

/// Difference hash: downscale to 9×8 grayscale, compare each pixel to its right neighbour →
/// 64-bit hash. Robust to small noise; sensitive to layout/content changes.
func dHash(_ image: CGImage) -> UInt64 {
    let w = 9, h = 8
    var pixels = [UInt8](repeating: 0, count: w * h)
    let gray = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: gray,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var hash: UInt64 = 0
    var bit: UInt64 = 0
    for row in 0..<h {
        for col in 0..<(w - 1) {
            if pixels[row * w + col] > pixels[row * w + col + 1] {
                hash |= (UInt64(1) << bit)
            }
            bit += 1
        }
    }
    return hash
}

/// Hamming distance = number of differing bits.
func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

// MARK: - Change detector (for "On change" mode)

/// Per-slide settle state machine: capture each slide once, after it has finished transitioning.
/// Not thread-safe by design — driven from a single capture queue.
final class FrameChangeDetector {
    private var lastSavedHash: UInt64?
    private var lastSaveTime: TimeInterval = -.greatestFiniteMagnitude
    private var settling = false
    private var prevHash: UInt64?
    private var stableSince: TimeInterval?

    /// Feed a frame's hash + timestamp (session-relative seconds). Returns true if this frame
    /// should be saved now.
    func shouldCapture(hash: UInt64, now: TimeInterval) -> Bool {
        defer { prevHash = hash }

        // Establish a baseline by capturing the first frame we ever see.
        guard let saved = lastSavedHash else {
            commit(hash, now)
            return true
        }

        if !settling {
            if hamming(hash, saved) > VisualConstants.changeThreshold {
                settling = true
                stableSince = nil
            }
            return false
        }

        // Settling: wait for consecutive frames to be stable for `stableWindow`.
        if let p = prevHash, hamming(hash, p) <= VisualConstants.stableThreshold {
            if stableSince == nil { stableSince = now }
            if let s = stableSince,
               now - s >= VisualConstants.stableWindow,
               now - lastSaveTime >= VisualConstants.minInterval {
                commit(hash, now)
                settling = false
                stableSince = nil
                return true
            }
        } else {
            stableSince = nil   // movement resumed — reset the stability timer
        }
        return false
    }

    private func commit(_ hash: UInt64, _ now: TimeInterval) {
        lastSavedHash = hash
        lastSaveTime = now
    }

    func reset() {
        lastSavedHash = nil
        lastSaveTime = -.greatestFiniteMagnitude
        settling = false
        prevHash = nil
        stableSince = nil
    }
}
