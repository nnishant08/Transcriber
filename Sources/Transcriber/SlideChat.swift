import Foundation

/// Feature D — slide-image selection for multimodal chat. The PURE, headlessly-testable half of the
/// feature: given a session's frames + a question, pick the slide images most relevant to the turn
/// (the frames nearest a referenced time window, else an even sample across the session, capped).
///
/// The actual image-input model call lives behind `#if TRANSCRIBER_MACOS27` + `#available(macOS 27)`
/// in `Intelligence` (image symbols exist only in the macOS 27 SDK). On macOS 26 the text+OCR chat is
/// the fallback and remains the default experience — this selection logic just goes unused there.
enum SlideChat {

    /// Conservative per-prompt image cap (verify the exact limit against the macOS 27 SDK).
    static let maxImages = 4
    /// Frames within ±this many seconds of a referenced time are considered "near" it.
    static let windowSeconds: TimeInterval = 60

    /// True when the build + runtime can actually attach images (macOS 27 SDK flag + OS). On a macOS
    /// 26 build this is always false → callers use the text+OCR fallback.
    static var imageInputAvailable: Bool {
        #if TRANSCRIBER_MACOS27
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    /// Parse a time reference from a chat question — `[mm:ss]`, `mm:ss`, or "at 12:30" — to seconds.
    static func referencedTime(in question: String) -> TimeInterval? {
        guard let ts = SessionStore.firstTimestamp(in: question) else { return nil }
        return SessionStore.secondsFrom(ts)
    }

    /// Select up to `cap` slide frames relevant to `question`. If the question references a time, pick
    /// the frames nearest it (within the window, then by proximity); otherwise pick an even sample
    /// across the whole session so the model sees representative slides. Returns [] when no frames.
    static func selectSlides(frames: [FrameEvent], question: String, cap: Int = SlideChat.maxImages) -> [FrameEvent] {
        let usable = frames.filter { !$0.imagePath.isEmpty }
        guard !usable.isEmpty, cap > 0 else { return [] }

        if let t = referencedTime(in: question) {
            let near = usable.filter { abs($0.sessionTime - t) <= windowSeconds }
            let pool = near.isEmpty ? usable : near                       // fall back to all if none in-window
            return Array(pool.sorted { abs($0.sessionTime - t) < abs($1.sessionTime - t) }.prefix(cap))
        }
        // No time reference → an even sample across the timeline (keeps chronological order).
        return evenSample(usable.sorted { $0.sessionTime < $1.sessionTime }, cap: cap)
    }

    /// Down-sample `items` to at most `cap`, evenly spaced (keeps first…last representative coverage).
    static func evenSample<T>(_ items: [T], cap: Int) -> [T] {
        guard items.count > cap else { return items }
        let step = Double(items.count) / Double(cap)
        return (0..<cap).map { items[min(items.count - 1, Int((Double($0) + 0.5) * step))] }
    }
}
