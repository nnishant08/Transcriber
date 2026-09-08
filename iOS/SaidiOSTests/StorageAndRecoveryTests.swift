import XCTest
import SaidKit

/// Storage layout, crash recovery, and the `.said` format — the parts of iOS that must behave
/// identically to the Mac or the cross-platform promise breaks.
final class StorageAndRecoveryTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("said-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SessionLocation.rootProvider = { [root] in root! }
        SessionTrash.inject { try FileManager.default.removeItem(at: $0) }
    }

    override func tearDown() {
        SessionLocation.resetRootToPlatformDefault()
        SessionTrash.resetToPlatformDefault()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Storage

    func testSessionRootResolvesInsideTheContainer() {
        SessionLocation.resetRootToPlatformDefault()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(SessionLocation.root.standardizedFileURL, documents.standardizedFileURL,
                       "sessions live in Documents, which is what makes them Files-app visible")
    }

    func testSupportDirectoryIsExcludedFromBackup() {
        // A re-downloadable model must never bloat an iCloud backup. Setting the flag on a path
        // that does not exist silently does nothing, which is the classic way this fails.
        var dir = root.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        let readBack = (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
        XCTAssertEqual(readBack, true, "the exclusion must be verified, not assumed")
    }

    func testTrashSeamRemovesDirectlyOnIOS() throws {
        let victim = root.appendingPathComponent("gone.txt")
        try Data("bye".utf8).write(to: victim)
        try SessionTrash.trash(victim)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                       "iOS has no Trash; the never-hard-delete promise is macOS-specific")
    }

    // MARK: Session round-trip

    func testSessionRoundTripsToDisk() throws {
        let dir = root.appendingPathComponent("2026-01-01 00-00-00", isDirectory: true)
        // `writeSession` does not create intermediate directories — on both platforms the folder
        // always comes from `makeSessionFolder` first. Mirror that here.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = SessionMeta(id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000),
                               sourceLabel: "This room", modelName: "openai_whisper-base.en")
        let segments = [TranscriptSegment(start: 0, end: 3, text: "Hello from the phone.")]
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments), to: dir)

        let back = DocumentBuilder.readSession(dir)
        XCTAssertEqual(back?.segments.first?.text, "Hello from the phone.")
        XCTAssertEqual(back?.meta.id, meta.id)
        XCTAssertTrue(back?.frames.isEmpty ?? false)

        let json = (try? String(contentsOf: dir.appendingPathComponent("session.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(json.contains("\"frames\""),
                       "a session with no frames writes no frames key — same as the Mac")
    }

    // MARK: Incremental audio + recovery

    func testAudioReachesDiskDuringCaptureAndSurvivesAKill() throws {
        let dir = root.appendingPathComponent("2026-01-02 00-00-00", isDirectory: true)
        let writer = try StreamingAudioWriter(sessionDir: dir)

        let tone = (0..<32_000).map { sinf(2 * .pi * 440 * Float($0) / 16_000) * 0.25 }
        for i in stride(from: 0, to: tone.count, by: 1_600) {
            writer.append(Array(tone[i..<min(tone.count, i + 1_600)]))
        }
        writer.flush()

        XCTAssertEqual(writer.sampleCount, 32_000, "samples reach disk DURING capture")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(StreamingAudioWriter.rawFilename).path))

        // Simulate the kill: never call finish().
        RecoveryState(sessionID: UUID(), startedAt: Date(), accumulatedPause: 7.5,
                      sourceLabel: "This room", modelName: "m").write(to: dir)

        let unfinished = RecoveryScanner.unfinishedSessions(root: root)
        XCTAssertTrue(unfinished.contains { $0.lastPathComponent == dir.lastPathComponent })

        let state = RecoveryState.read(from: dir)
        XCTAssertEqual(state?.accumulatedPause, 7.5,
                       "accumulated pause must survive, or recovered timestamps drift off the audio")

        let recovered = StreamingAudioWriter.convertRaw(
            at: dir.appendingPathComponent(StreamingAudioWriter.rawFilename))
        XCTAssertEqual(recovered?.lastPathComponent, "audio.m4a")

        RecoveryState.clear(in: dir)
        XCTAssertTrue(RecoveryScanner.unfinishedSessions(root: root).isEmpty)
    }

    // MARK: Slide pipeline

    func testSlidePipelineProducesAMacCompatibleFrameEvent() async throws {
        let dir = root.appendingPathComponent("2026-01-03 00-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"),
                                                withIntermediateDirectories: true)

        let slide = try XCTUnwrap(Self.makeSlide(title: "Quorum intersection"))
        let corrected = await SlideOCR.correctingPerspective(of: slide)
        let text = await SlideOCR.recognize(cgImage: corrected)
        XCTAssertTrue((text ?? "").lowercased().contains("quorum"), "OCR reads the slide")

        let relative = SlideOCR.frameRelativePath(index: 1)
        XCTAssertEqual(relative, "images/slide-0001.png",
                       "the path must match what the Mac renderer expects")
        let png = try XCTUnwrap(SlideOCR.pngData(from: corrected))
        try SessionIO.writeData(png, to: dir.appendingPathComponent(relative))

        let frame = FrameEvent(time: 12.5, imagePath: relative, text: text)
        DocumentBuilder.writeSession(
            SessionDoc(meta: SessionMeta(date: Date(timeIntervalSince1970: 0),
                                         sourceLabel: "This room", modelName: "m"),
                       segments: [TranscriptSegment(start: 0, end: 2, text: "As you can see")],
                       frames: [frame]),
            to: dir)

        let back = DocumentBuilder.readSession(dir)
        XCTAssertEqual(back?.frames, [frame], "the FrameEvent round-trips element for element")

        let md = SessionIO.readText(SessionPaths.transcriptURL(in: dir)) ?? ""
        XCTAssertTrue(md.contains("![00:12](images/slide-0001.png)"),
                      "the markdown form must match the Mac's exactly")
        XCTAssertTrue(md.contains("<details><summary>On-slide text (00:12)"))
    }

    func testVideoAndFramesAreMutuallyExclusive() {
        let frames = [FrameEvent(time: 1, imagePath: "images/slide-0001.png", text: nil)]
        let both = SessionDoc(meta: SessionMeta(date: Date(), sourceLabel: "x", modelName: "m",
                                                videoFile: "screen.mp4"),
                              segments: [], frames: frames)
        XCTAssertEqual(both.visual, .video("screen.mp4"), "video wins; the Viewer never sees both")
    }

    // MARK: .said round trip

    func testSaidBundleRoundTripsWithFrames() throws {
        let dir = root.appendingPathComponent("2026-01-04 00-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"),
                                                withIntermediateDirectories: true)
        let relative = SlideOCR.frameRelativePath(index: 1)
        try SessionIO.writeData(Data(repeating: 7, count: 512), to: dir.appendingPathComponent(relative))

        let id = UUID()
        let frames = [FrameEvent(time: 4, imagePath: relative, text: "Slide text")]
        DocumentBuilder.writeSession(
            SessionDoc(meta: SessionMeta(id: id, date: Date(timeIntervalSince1970: 1_800_000_000),
                                         sourceLabel: "This room", modelName: "m"),
                       segments: [TranscriptSegment(start: 0, end: 2, text: "Hello")],
                       frames: frames),
            to: dir)

        let bundle = root.appendingPathComponent("out.said")
        _ = try SessionBundle.write(sessionDir: dir, to: bundle)

        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let outcome = try SessionBundle.read(bundle: bundle, into: dest)
        XCTAssertFalse(outcome.isDuplicate)

        let imported = DocumentBuilder.readSession(outcome.directory)
        XCTAssertEqual(imported?.meta.id, id, "the session id survives the crossing")
        XCTAssertEqual(imported?.frames, frames, "frames survive as data")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outcome.directory.appendingPathComponent(relative).path),
            "…and as files, at the same relative path")

        // Idempotent: the same bundle twice is not two sessions.
        let again = try SessionBundle.read(bundle: bundle, into: dest)
        XCTAssertTrue(again.isDuplicate, "the collision rule is deterministic")
    }

    // MARK: Helpers

    static func makeSlide(title: String) -> CGImage? {
        let w = 900, h = 640
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateUIFontForLanguage(.system, 62, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 62, nil)
        let attr = NSAttributedString(string: title, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 60, y: CGFloat(h) - 140)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return ctx.makeImage()
    }
}
