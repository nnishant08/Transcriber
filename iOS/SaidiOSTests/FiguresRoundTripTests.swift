import XCTest
import SaidKit

/// The figures wave's cross-platform proof (§9): a session extracted on the Mac opens on the phone
/// with identical figures and no re-extraction — and the phone's own detector, run over the same
/// transcript, produces the identical list, which is what makes the reverse direction true too.
///
/// The fixture is `Fixtures/figures/session`, written by the Mac's
/// `--selftest-figures-bundle --write-fixture` and committed. It is bundled into this test target
/// as a resource (see `project.yml`), so the test reads the very bytes the Mac produced.
final class FiguresRoundTripTests: XCTestCase {

    private var fixture: URL!
    private var wasEnabled = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        wasEnabled = FigureStore.isEnabled
        let bundle = Bundle(for: Self.self)
        guard let src = bundle.url(forResource: "session", withExtension: nil, subdirectory: "figures")
                ?? bundle.url(forResource: "session", withExtension: nil) else {
            throw XCTSkip("fixture Fixtures/figures/session is not bundled into the test target")
        }
        // Copy out: the fixture must stay untouched, and the pass writes beside the transcript.
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("said-figfixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: src, to: fixture)
        FigureStore.isEnabled = true
    }

    override func tearDown() {
        FigureStore.isEnabled = wasEnabled
        try? FileManager.default.removeItem(at: fixture)
        super.tearDown()
    }

    func testMacExtractedFiguresOpenOnThePhoneWithoutReextraction() throws {
        let doc = try XCTUnwrap(DocumentBuilder.readSession(fixture))
        guard case .ready(let sidecar) = FigureStore.read(dir: fixture, doc: doc) else {
            return XCTFail("the Mac's sidecar must read as ready here — fingerprint mismatch means the two platforms hash differently")
        }
        XCTAssertFalse(sidecar.figures.isEmpty)
        XCTAssertFalse(FigurePass.needsExtraction(dir: fixture, doc: doc), "no re-extraction on open")

        // Every figure still anchors on this platform's read of the same text.
        let displayed = EditStore.editedSegments(dir: fixture, segments: doc.segments)
        let resolved = FigureOverlay.resolve(sidecar.figures, in: displayed)
        XCTAssertEqual(resolved.dropped, 0, "an anchor that holds on the Mac holds on the phone")
        XCTAssertEqual(resolved.resolved.count, sidecar.figures.count)
        XCTAssertTrue(sidecar.figures.contains { $0.label == "customer acquisition cost" }, "labels travel with the sidecar")
    }

    func testThePhoneDetectorReproducesTheMacExtractionExactly() throws {
        let doc = try XCTUnwrap(DocumentBuilder.readSession(fixture))
        let sidecar = try XCTUnwrap(FigureStore.read(dir: fixture, doc: doc).sidecar)
        let here = FigureDetector.detect(segments: EditStore.editedSegments(dir: fixture, segments: doc.segments))
        let mac = sidecar.figures.map { f -> Figure in var g = f; g.label = nil; g.confidence = nil; return g }
        XCTAssertEqual(here, mac, "the detector is deterministic across platforms — same ranges, same words, same times, same classes")
    }

    func testAPhoneExtractionReadsBackOnTheMacSideByTheSameRules() async throws {
        // The reverse direction: extract here (detector only — no model in a simulator), then
        // check the written sidecar against the Mac's reading rules: right schema, fingerprint
        // bound to the transcript, labels reused from the Mac's sidecar for identical candidates.
        let before = try XCTUnwrap(FigureStore.read(dir: fixture).sidecar)
        let ran = await FigurePass.run(dir: fixture, mode: .detectOnly)
        let result = try XCTUnwrap(ran)
        let after = try XCTUnwrap(FigureStore.read(dir: fixture).sidecar)
        XCTAssertEqual(after.schemaVersion, FigureSidecar.currentSchemaVersion)
        XCTAssertEqual(after.transcriptFingerprint, before.transcriptFingerprint)
        XCTAssertEqual(result.figures.map(\.raw), before.figures.map(\.raw))
        XCTAssertEqual(after.figures.compactMap(\.label), before.figures.compactMap(\.label), "labels the Mac gave are kept, not discarded")
        // The transcript was never touched.
        let md = try Data(contentsOf: SessionPaths.transcriptURL(in: fixture))
        XCTAssertTrue(String(decoding: md, as: UTF8.self).contains("$2.4 million"))
    }

    func testOffSwitchIsInertOnThePhone() {
        FigureStore.isEnabled = false
        XCTAssertTrue(FigureStore.figures(dir: fixture).isEmpty, "a sidecar on disk is inert with the flag off")
        XCTAssertFalse(FigurePass.needsExtraction(dir: fixture))
    }

    func testDensityCeilingsAreStatedAndOrdered() {
        XCTAssertLessThan(FigureDensity.phoneCeilingPerHundredWords, FigureDensity.macCeilingPerHundredWords)
        XCTAssertTrue(FigureDensity.washAllowed(figureCount: 1, wordCount: 3, ceilingPerHundredWords: FigureDensity.phoneCeilingPerHundredWords),
                      "a single figure is always washed")
        XCTAssertFalse(FigureDensity.washAllowed(figureCount: 4, wordCount: 20, ceilingPerHundredWords: FigureDensity.phoneCeilingPerHundredWords),
                       "a table being read out loses the wash on the phone")
    }
}
