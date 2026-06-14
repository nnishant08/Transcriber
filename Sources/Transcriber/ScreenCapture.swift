import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AppKit

// MARK: - Capture target & mode (per-session, persisted)

enum CaptureTarget: Hashable, Codable {
    case mainDisplay
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case app(String)             // bundle identifier

    /// Compact persistable string.
    var persisted: String {
        switch self {
        case .mainDisplay: return "main"
        case .display(let id): return "display:\(id)"
        case .window(let id): return "window:\(id)"
        case .app(let b): return "app:\(b)"
        }
    }
    init(persisted: String) {
        if persisted == "main" { self = .mainDisplay; return }
        let parts = persisted.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "display": self = .display(CGDirectDisplayID(parts.last.flatMap { UInt32($0) } ?? CGMainDisplayID()))
        case "window": self = .window(CGWindowID(parts.last.flatMap { UInt32($0) } ?? 0))
        case "app": self = .app(parts.count > 1 ? parts[1] : "")
        default: self = .mainDisplay
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case onChange
    case interval
    case manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .onChange: return "On change"
        case .interval: return "Every N sec"
        case .manual: return "Manual only"
        }
    }
}

/// A selectable target for the Settings picker, populated live from `SCShareableContent`.
struct CaptureTargetOption: Identifiable, Hashable {
    let id: String
    let label: String
    let target: CaptureTarget
    static func == (a: CaptureTargetOption, b: CaptureTargetOption) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - VisualCapture

/// Owns the visual-capture pipeline: builds the SCContentFilter from the chosen target, runs the
/// change detector / interval timer / manual grab, writes PNGs into the session's images/ folder,
/// and emits FrameEvents. For the MIC source it owns its own video-only SCStream; for the
/// SYSTEM-AUDIO source it receives frames via `ingest(_:)` from the shared AudioCaptureSystem stream.
/// All mutable state is confined to `queue`.
final class VisualCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let target: CaptureTarget
    let mode: CaptureMode
    let interval: TimeInterval
    private let sessionDir: URL
    private let queue = DispatchQueue(label: "com.nikhil.transcriber.visual")

    private let detector = FrameChangeDetector()
    private var ownStream: SCStream?
    private var intervalTimer: DispatchSourceTimer?
    private var t0: TimeInterval = 0
    private var latestFrame: CGImage?
    private var latestTime: TimeInterval = 0
    private var savedCount = 0
    private var stopped = false

    /// Called (off the main thread) when a frame is saved. `thumb` is a small UI copy.
    var onFrame: ((FrameEvent, CGImage) -> Void)?
    /// Called if the visual stream stops on its own (e.g. captured window closed).
    var onStopped: ((String) -> Void)?

    init(target: CaptureTarget, mode: CaptureMode, interval: TimeInterval, sessionDir: URL) {
        self.target = target
        self.mode = mode
        self.interval = max(2, interval)
        self.sessionDir = sessionDir
    }

    // MARK: Lifecycle

    /// Set the shared session clock and arm timers. Call before frames start arriving.
    func begin(t0: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.t0 = t0            // confined to `queue` — only read in process() on this queue
            self.stopped = false
            self.savedCount = 0
            self.detector.reset()
            self.latestFrame = nil
            if self.mode == .interval { self.startIntervalTimer() }
        }
    }

    /// MIC source: own a standalone video-only stream.
    func startOwnVideoStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try makeFilter(content: content)
        let config = makeVideoConfig(content: content, withAudio: false)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        ownStream = stream
        try await stream.startCapture()
        NSLog("[Visual] own video stream started (target=\(target.persisted))")
    }

    func stop() async {
        // Drain the queue (so any in-flight save() finishes and no late frames append) without
        // blocking the MainActor caller — await a continuation instead of queue.sync.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.stopped = true
                self?.intervalTimer?.cancel()
                self?.intervalTimer = nil
                cont.resume()
            }
        }
        if let s = ownStream {
            ownStream = nil
            try? s.removeStreamOutput(self, type: .screen)
            try? await s.stopCapture()
        }
        NSLog("[Visual] stopped")
    }

    /// Force-capture the current frame (the always-live ⌥⌘S grab).
    func manualGrab() {
        queue.async { [weak self] in
            guard let self, let img = self.latestFrame else { return }
            self.save(img, at: self.latestTime)
        }
    }

    /// SYSTEM-AUDIO source: AudioCaptureSystem forwards its `.screen` sample buffers here.
    /// Must be called on `queue` (AudioCaptureSystem adds the screen output with this queue).
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        process(sampleBuffer)
    }

    var sampleHandlerQueue: DispatchQueue { queue }

    // MARK: SCStreamOutput (own stream / mic case)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        process(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Visual] own stream stopped with error: \(error)")
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onStopped?(message) }
    }

    // MARK: Frame processing (always on `queue`)

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard !stopped, isComplete(sampleBuffer), let cg = sampleBuffer.videoCGImage else { return }
        // Detach so the frame is safe to retain past the IOSurface's recycle.
        let frame = cg.detachedCopy() ?? cg
        latestFrame = frame
        latestTime = CACurrentMediaTime() - t0

        if mode == .onChange {
            let hash = dHash(frame)
            if detector.shouldCapture(hash: hash, now: latestTime) {
                save(frame, at: latestTime)
            }
        }
    }

    private func save(_ image: CGImage, at time: TimeInterval) {
        guard savedCount < VisualConstants.maxImages else {
            if savedCount == VisualConstants.maxImages {
                NSLog("[Visual] reached MAX_IMAGES (\(VisualConstants.maxImages)); dropping further captures")
                savedCount += 1   // log once
            }
            return
        }
        guard let png = image.pngData() else { return }
        let idx = savedCount + 1
        let total = Int(max(0, time).rounded())
        let name = String(format: "%04d-%02d%02d.png", idx, total / 60, total % 60)
        let rel = "images/\(name)"
        do {
            try png.write(to: sessionDir.appendingPathComponent(rel))
        } catch {
            NSLog("[Visual] write failed: \(error)")
            return
        }
        savedCount = idx
        let thumb = image.thumbnail(maxDim: VisualConstants.thumbnailMaxDim) ?? image
        let event = FrameEvent(sessionTime: time, imagePath: rel, ocrText: nil)
        // Read + invoke the callback on the main actor (where it's assigned) to avoid a
        // cross-thread read of the closure from this capture queue.
        DispatchQueue.main.async { [weak self] in self?.onFrame?(event, thumb) }
    }

    private func startIntervalTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let img = self.latestFrame else { return }
            self.save(img, at: self.latestTime)
        }
        timer.resume()
        intervalTimer = timer
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    // MARK: Filter + config builders (also used by AudioCaptureSystem for the shared stream)

    func makeFilter(content: SCShareableContent) throws -> SCContentFilter {
        guard let anyDisplay = content.displays.first else { throw CaptureError.noDisplay }
        let ownBundle = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle }

        func displayFilter(_ display: SCDisplay) -> SCContentFilter {
            SCContentFilter(display: display, excludingWindows: ownWindows)
        }
        func mainDisplay() -> SCDisplay {
            content.displays.first { $0.displayID == CGMainDisplayID() } ?? anyDisplay
        }

        switch target {
        case .mainDisplay:
            return displayFilter(mainDisplay())
        case .display(let id):
            return displayFilter(content.displays.first { $0.displayID == id } ?? mainDisplay())
        case .window(let id):
            if let win = content.windows.first(where: { $0.windowID == id }) {
                return SCContentFilter(desktopIndependentWindow: win)
            }
            NSLog("[Visual] target window \(id) not found — falling back to main display")
            return displayFilter(mainDisplay())
        case .app(let bundle):
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundle }) {
                return SCContentFilter(display: mainDisplay(), including: [app], exceptingWindows: [])
            }
            NSLog("[Visual] target app \(bundle) not found — falling back to main display")
            return displayFilter(mainDisplay())
        }
    }

    func makeVideoConfig(content: SCShareableContent, withAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let (w, h) = videoDimensions(content: content)
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: VisualConstants.frameRateFPS)
        config.showsCursor = false
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        if withAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        return config
    }

    private func videoDimensions(content: SCShareableContent) -> (Int, Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func even(_ v: CGFloat) -> Int { let i = min(max(2, Int(v.rounded())), 5120); return i - i % 2 }

        if case .window(let id) = target, let win = content.windows.first(where: { $0.windowID == id }) {
            return (even(win.frame.width * scale), even(win.frame.height * scale))
        }
        let displayID: CGDirectDisplayID = { if case .display(let id) = target { return id }; return CGMainDisplayID() }()
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return (even(CGFloat(mode.pixelWidth)), even(CGFloat(mode.pixelHeight)))
        }
        return (1920, 1080)
    }

    // MARK: Target listing for the Settings picker

    static func availableTargets() async -> [CaptureTargetOption] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return [CaptureTargetOption(id: "main", label: "Main Display", target: .mainDisplay)]
        }
        let ownBundle = Bundle.main.bundleIdentifier
        var options: [CaptureTargetOption] = [
            CaptureTargetOption(id: "main", label: "Main Display", target: .mainDisplay)
        ]
        for (i, d) in content.displays.enumerated() {
            options.append(CaptureTargetOption(
                id: "display:\(d.displayID)",
                label: "Display \(i + 1) — \(Int(d.frame.width))×\(Int(d.frame.height))",
                target: .display(d.displayID)))
        }
        for w in content.windows where (w.title?.isEmpty == false) && w.frame.width > 120 && w.frame.height > 80 {
            guard w.owningApplication?.bundleIdentifier != ownBundle else { continue }
            let app = w.owningApplication?.applicationName ?? "App"
            options.append(CaptureTargetOption(
                id: "window:\(w.windowID)",
                label: "🪟 \(app) — \(w.title ?? "")",
                target: .window(w.windowID)))
        }
        let appsWithWindows = Set(content.windows.compactMap { $0.owningApplication?.bundleIdentifier })
        for a in content.applications
        where appsWithWindows.contains(a.bundleIdentifier) && a.bundleIdentifier != ownBundle {
            options.append(CaptureTargetOption(
                id: "app:\(a.bundleIdentifier)",
                label: "📱 \(a.applicationName) — all windows",
                target: .app(a.bundleIdentifier)))
        }
        return options
    }
}
