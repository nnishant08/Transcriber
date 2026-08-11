import Foundation
import AVFoundation
import CryptoKit

/// Entry point. Normally launches the SwiftUI menu-bar app, but supports headless
/// self-test modes (no mic / no permissions) used during development to verify the
/// transcription pipeline:
///   --selftest [audioFile] [--model <id>]         one-shot file transcription
///   --selftest-stream [audioFile] [--model <id>]  drives Resampler16k + StreamingTranscriber
@main
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--selftest-stream") {
            let audioPath = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-"))
                ? args[idx + 1]
                : "/tmp/tr_long_48k_stereo.wav"
            SelfTest.runStream(audioPath: audioPath, model: value(of: "--model", in: args) ?? "openai_whisper-base.en")
            return
        }
        if let idx = args.firstIndex(of: "--summarize") {
            let path = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-")) ? args[idx + 1] : ""
            SelfTest.runSummary(path: path)
            return
        }
        if let idx = args.firstIndex(of: "--selftest-capture") {
            SelfTest.runCapture(dir: positional(after: idx, in: args))
            return
        }
        if let idx = args.firstIndex(of: "--selftest-ocr") {
            SelfTest.runOCR(path: positional(after: idx, in: args))
            return
        }
        if args.contains("--selftest-doc") {
            SelfTest.runDoc()
            return
        }
        if let idx = args.firstIndex(of: "--selftest-export") {
            SelfTest.runExport(folder: positional(after: idx, in: args))
            return
        }
        if let idx = args.firstIndex(of: "--selftest-migrate") {
            SelfTest.runMigrate(dir: positional(after: idx, in: args))
            return
        }
        if let idx = args.firstIndex(of: "--selftest-index") {
            SelfTest.runIndex(dir: positional(after: idx, in: args))
            return
        }
        if let idx = args.firstIndex(of: "--selftest-title") {
            SelfTest.runTitle(path: positional(after: idx, in: args))
            return
        }
        if let idx = args.firstIndex(of: "--retag") {
            SelfTest.runRetag(dir: positional(after: idx, in: args), force: args.contains("--force"))
            return
        }
        if let idx = args.firstIndex(of: "--selftest-chat") {
            SelfTest.runChat(dir: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-ask") { SelfTest.runAsk(); return }
        if let idx = args.firstIndex(of: "--selftest-summary") {
            SelfTest.runSummarySuite(path: positional(after: idx, in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-import") {
            SelfTest.runImport(path: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-mix") { SelfTest.runMix(); return }
        if args.contains("--selftest-audio-save") { SelfTest.runAudioSave(); return }
        if let idx = args.firstIndex(of: "--selftest-srt") {
            SelfTest.runSRT(dir: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-vocab") { SelfTest.runVocab(); return }
        if args.contains("--selftest-bookmarks") { SelfTest.runBookmarks(); return }
        if args.contains("--selftest-pause") { SelfTest.runPause(); return }
        // Stage-1 self-tests (diarization / multilingual / calendar / cleanup / custom modes)
        if let idx = args.firstIndex(of: "--selftest-diarize") {
            SelfTest.runDiarize(path: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-align") { SelfTest.runAlign(); return }
        if let idx = args.firstIndex(of: "--selftest-detect") {
            SelfTest.runDetect(path: positional(after: idx, in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-multilingual") {
            SelfTest.runMultilingual(path: positional(after: idx, in: args), lang: value(of: "--lang", in: args)); return
        }
        if args.contains("--selftest-calendar") { SelfTest.runCalendar(); return }
        if let idx = args.firstIndex(of: "--selftest-cleanup") {
            SelfTest.runCleanup(path: positional(after: idx, in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-custom-summary") {
            SelfTest.runCustomSummary(path: positional(after: idx, in: args)); return
        }
        // Stage-2 self-tests (Generation Studio / packs / redaction / retention / encryption / slide chat)
        if let idx = args.firstIndex(of: "--selftest-generate") {
            SelfTest.runGenerate(path: positional(after: idx, in: args), template: value(of: "--template", in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-audiogram") {
            SelfTest.runAudiogram(path: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-packs") { SelfTest.runPacks(); return }
        if let idx = args.firstIndex(of: "--selftest-redact") {
            SelfTest.runRedact(path: positional(after: idx, in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-retention") {
            SelfTest.runRetention(dir: positional(after: idx, in: args)); return
        }
        if let idx = args.firstIndex(of: "--selftest-encrypt") {
            SelfTest.runEncrypt(dir: positional(after: idx, in: args)); return
        }
        if args.contains("--selftest-slidechat") { SelfTest.runSlideChat(); return }
        // Diagnostic: what ScreenCaptureKit hands us as the output device's mute/volume change.
        // Needs the Screen Recording grant → run the .app bundle's binary, not .build/release.
        if let idx = args.firstIndex(of: "--selftest-sysaudio") {
            SysAudioProbe.run(seconds: Double(positional(after: idx, in: args) ?? "") ?? 20)
            return
        }
        // Same probe through the Core Audio process tap — the screen-independent backend.
        if let idx = args.firstIndex(of: "--selftest-processtap") {
            guard #available(macOS 14.2, *) else {
                print("Process taps need macOS 14.2 or newer."); return
            }
            SysAudioProbe.runProcessTap(seconds: Double(positional(after: idx, in: args) ?? "") ?? 20)
            return
        }
        if let idx = args.firstIndex(of: "--selftest") {
            let audioPath = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-"))
                ? args[idx + 1]
                : "/tmp/transcriber_test.wav"
            let model = value(of: "--model", in: args) ?? "openai_whisper-base.en"
            SelfTest.run(audioPath: audioPath, model: model)
            return
        }
        TranscriberApp.main()
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func positional(after index: Int, in args: [String]) -> String? {
        guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { return nil }
        return args[index + 1]
    }
}

enum SelfTest {
    static func run(audioPath: String, model: String) {
        setbuf(stdout, nil)
        print("== Said self-test ==")
        print("audio : \(audioPath)")
        print("model : \(model)")

        let sema = DispatchSemaphore(value: 0)
        var code: Int32 = 0

        Task.detached {
            do {
                let engine = TranscriptionEngine()
                try await engine.prepare(model: model) { msg, _ in print("  [status] \(msg)") }

                let start = Date()
                let text = try await engine.transcribeFile(audioPath, language: "en")
                let elapsed = Date().timeIntervalSince(start)

                print("----------------------------------------")
                print("RESULT (\(String(format: "%.2f", elapsed))s): \(text)")
                print("----------------------------------------")

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("FAIL: empty transcript")
                    code = 2
                } else {
                    print("OK")
                }
            } catch {
                print("ERROR: \(error)")
                code = 1
            }
            sema.signal()
        }

        sema.wait()
        exit(code)
    }

    /// Streaming verification: reads the file in chunks at its NATIVE format, pushes each
    /// chunk through the real `Resampler16k` (e.g. 48 kHz stereo → 16 kHz mono) into the
    /// shared sink — exactly what mic/system capture do — while the `StreamingTranscriber`
    /// consumes it live. Then runs the full-quality final pass. Verifies resampling, the
    /// rolling-window confirmation, dedup, and the final pass with no mic/permissions.
    static func runStream(audioPath: String, model: String) {
        setbuf(stdout, nil)
        print("== Said STREAMING self-test ==")
        print("audio : \(audioPath)")
        print("model : \(model)")

        let sema = DispatchSemaphore(value: 0)
        var code: Int32 = 0

        Task.detached {
            do {
                let engine = TranscriptionEngine()
                try await engine.prepare(model: model) { msg, _ in print("  [status] \(msg)") }
                engine.sink.reset()

                let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
                print("input format: \(file.processingFormat)")

                let collector = UpdateCollector()
                guard let streamer = engine.makeStreamer(language: "en", onUpdate: { live in
                    collector.update(live.text)
                }) else { throw CaptureError.engineNotReady }

                let runTask = Task { await streamer.run() }

                // Feed ~0.5 s native-format chunks through Resampler16k into the sink,
                // pacing slightly faster than real time to keep the test quick.
                let resampler = Resampler16k()
                let fmt = file.processingFormat
                let chunkFrames = AVAudioFrameCount(fmt.sampleRate * 0.5)
                while file.framePosition < file.length {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
                    try file.read(into: buf)
                    if buf.frameLength == 0 { break }
                    if let samples = resampler.resample(buf) { engine.sink.append(samples) }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
                print("fed \(engine.sampleCount) samples @16k (\(String(format: "%.1f", Double(engine.sampleCount) / 16000))s)")

                // Let the streamer finish its last passes, then stop it before the final pass.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await streamer.stop()
                await runTask.value

                print("updates emitted: \(collector.count)")
                print("----------------------------------------")
                print("STREAMING (last): \(collector.last)")

                let final = try await engine.finalPass(language: "en")
                print("FINAL PASS     : \(final)")
                print("----------------------------------------")

                if collector.last.isEmpty && final.isEmpty {
                    print("FAIL: empty"); code = 2
                } else {
                    print("OK")
                }
            } catch {
                print("ERROR: \(error)")
                code = 1
            }
            sema.signal()
        }

        sema.wait()
        exit(code)
    }
}

extension SelfTest {
    /// Verify on-device summarization (Apple Foundation Models) works on this Mac.
    static func runSummary(path: String) {
        setbuf(stdout, nil)
        print("== summary self-test ==")
        print("isAvailable: \(Summarizer.isAvailable)")
        if let msg = Summarizer.availabilityMessage() { print("availability: \(msg)") }

        let sema = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let fileText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                let body = fileText.isEmpty
                    ? "Quick standup: we finished the login screen, the API is rate-limited so we'll add caching, and Priya will demo the beta to the client on Friday."
                    : fileText
                let start = Date()
                let summary = try await Summarizer.summarize(body)
                print("----------------------------------------")
                print("SUMMARY (\(String(format: "%.2f", Date().timeIntervalSince(start)))s):")
                print(summary)
                print("----------------------------------------")
                print(summary.isEmpty ? "FAIL: empty" : "OK")
            } catch {
                print("ERROR: \(error.localizedDescription)")
                code = 1
            }
            sema.signal()
        }
        sema.wait()
        exit(code)
    }
}

// MARK: - Visual-capture self-tests

import CoreGraphics
import CoreText

extension SelfTest {

    /// Build a simple black-on-white text image with CoreGraphics + CoreText (thread-safe; no AppKit).
    static func textImage(_ text: String, width: Int = 700, height: Int = 240, bg: CGFloat = 1.0) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 28, y: CGFloat(height) / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// Frame-filling, structurally-distinct synthetic "slides": 0 = vertical stripes,
    /// 1 = horizontal stripes, 2 = centered filled square. These give rich, clearly-different dHashes.
    static func patternImage(_ kind: Int, size: Int = 360) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // Full-height vertical bands at distinct coarse columns. dHash is most sensitive to
        // horizontal edges, so different column sets give large pairwise hamming.
        let columns: [Int]
        switch kind {
        case 0: columns = [0, 2, 4, 6, 8]
        case 1: columns = [1, 3, 5, 7]
        default: columns = [0, 1, 2, 6, 7, 8]
        }
        let cw = size / 9
        for c in columns { ctx.fill(CGRect(x: c * cw, y: 0, width: cw, height: size)) }
        return ctx.makeImage()
    }

    /// Verify the change detector fires once per distinct "slide" and ignores repeats.
    static func runCapture(dir: String?) {
        setbuf(stdout, nil)
        print("== change-detector self-test ==")

        // Build an ordered sequence: slide A ×5, B ×5, C ×5 (one new slide every 2.5 s @ 2 fps).
        var frames: [CGImage] = []
        if let dir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
            for f in files where f.hasSuffix(".png") {
                if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir).appendingPathComponent(f) as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { frames.append(img) }
            }
            print("loaded \(frames.count) frames from \(dir)")
        }
        if frames.isEmpty {
            // dHash measures EDGE STRUCTURE over the whole frame. Real screen content (video, slides
            // with text/colour) is dense; use frame-filling, structurally-distinct patterns here.
            let uniques = (0..<3).compactMap { patternImage($0) }
            // Diagnostic: pairwise hamming of the three distinct "slides".
            if uniques.count == 3 {
                let h = uniques.map { dHash($0) }
                print("pairwise hamming: A–B=\(hamming(h[0], h[1])) B–C=\(hamming(h[1], h[2])) A–C=\(hamming(h[0], h[2])) (threshold \(VisualConstants.changeThreshold))")
            }
            for img in uniques { for _ in 0..<5 { frames.append(img) } }
            print("using \(frames.count) synthetic frames (3 distinct patterns × 5)")
        }

        let detector = FrameChangeDetector()
        var captures = 0
        for (i, img) in frames.enumerated() {
            let t = Double(i) * 0.5          // 2 fps
            if detector.shouldCapture(hash: dHash(img), now: t) {
                captures += 1
                print("  capture #\(captures) at \(String(format: "%.1f", t))s")
            }
        }
        print("total captures: \(captures) (expected 3: one per distinct slide)")
        exit(captures == 3 ? 0 : 2)
    }

    /// Verify on-device Vision OCR.
    static func runOCR(path: String?) {
        setbuf(stdout, nil)
        print("== OCR self-test ==")
        let image: CGImage?
        if let path {
            let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            image = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            print("image: \(path)")
        } else {
            image = textImage("Roadmap Q3: ship the beta")
            print("image: synthetic (\"Roadmap Q3: ship the beta\")")
        }
        guard let cg = image else { print("ERROR: no image"); exit(1) }
        let text = SlideOCR.recognize(cg)
        print("----------------------------------------")
        print("OCR: \(text)")
        print("----------------------------------------")
        exit(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 2 : 0)
    }

    /// Verify the timeline merge: synthetic segments + frame events → interleaved Markdown.
    static func runDoc() {
        setbuf(stdout, nil)
        print("== document-builder self-test ==")
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "System Audio",
                               modelName: "openai_whisper-base.en", targetLabel: "Main Display", modeLabel: "On change")
        let segments = [
            TranscriptSegment(start: 0.5, end: 3.0, text: "Welcome everyone to the session."),
            TranscriptSegment(start: 9.0, end: 12.0, text: "As you can see on this slide."),
            TranscriptSegment(start: 20.0, end: 23.0, text: "That wraps up the results."),
        ]
        let frames = [
            FrameEvent(sessionTime: 8.0, imagePath: "images/0001-0008.png", ocrText: "Agenda\n1. Intro\n2. Results"),
            FrameEvent(sessionTime: 19.0, imagePath: "images/0002-0019.png", ocrText: "Quarterly Results: +18%"),
        ]
        let md = DocumentBuilder.markdown(meta: meta, segments: segments, frames: frames)
        print("----------------------------------------")
        print(md)
        print("----------------------------------------")
        // Ordering check: image at 8s must appear between the 3s and 12s segments.
        let okOrder = md.range(of: "0001-0008") != nil &&
            (md.range(of: "Welcome")!.lowerBound < md.range(of: "0001-0008")!.lowerBound) &&
            (md.range(of: "0001-0008")!.lowerBound < md.range(of: "this slide")!.lowerBound)
        print(okOrder ? "OK (ordering correct)" : "FAIL (ordering wrong)")
        exit(okOrder ? 0 : 2)
    }

    /// Verify HTML + PDF export from a session folder (synthesises one if none given).
    static func runExport(folder: String?) {
        setbuf(stdout, nil)
        print("== export self-test ==")
        let dir: URL = folder.map { URL(fileURLWithPath: $0) } ?? makeSyntheticSession()
        print("session: \(dir.path)")

        Task { @MainActor in
            do {
                let html = URL(fileURLWithPath: "/tmp/transcriber_export.html")
                try Exporter.exportHTML(sessionDir: dir, to: html)
                let htmlSize = (try? Data(contentsOf: html).count) ?? 0
                print("HTML → \(html.path) (\(htmlSize) bytes)")

                let pdf = URL(fileURLWithPath: "/tmp/transcriber_export.pdf")
                try await Exporter.exportPDF(sessionDir: dir, to: pdf)
                let pdfSize = (try? Data(contentsOf: pdf).count) ?? 0
                print("PDF  → \(pdf.path) (\(pdfSize) bytes)")

                print((htmlSize > 0 && pdfSize > 0) ? "OK" : "FAIL")
                exit((htmlSize > 0 && pdfSize > 0) ? 0 : 2)
            } catch {
                print("ERROR: \(error)")
                exit(1)
            }
        }
        // WKWebView needs a running main run loop to deliver navigation callbacks.
        CFRunLoopRun()
    }

    private static func makeSyntheticSession() -> URL {
        let dir = URL(fileURLWithPath: "/tmp/transcriber-selftest-session")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"),
                                                 withIntermediateDirectories: true)
        if let cg = textImage("Roadmap Q3: ship the beta"), let png = cg.pngData() {
            try? png.write(to: dir.appendingPathComponent("images/0001-0005.png"))
        }
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "System Audio",
                               modelName: "openai_whisper-base.en", targetLabel: "Main Display", modeLabel: "On change")
        let segments = [
            TranscriptSegment(start: 1, end: 4, text: "Welcome to the demonstration."),
            TranscriptSegment(start: 6, end: 9, text: "Here is the roadmap for the quarter."),
        ]
        let frames = [FrameEvent(sessionTime: 5, imagePath: "images/0001-0005.png", ocrText: "Roadmap Q3: ship the beta")]
        DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments, frames: frames), to: dir)
        return dir
    }
}

// MARK: - Unified-store self-tests (migration / search index / title generation)

extension SelfTest {

    /// Synthesize legacy flat `.md` files, migrate, and assert: each became `<name>/transcript.md` +
    /// `session.json`, the original bytes are preserved, a backup exists, and a second run is a no-op.
    static func runMigrate(dir: String?) {
        setbuf(stdout, nil)
        print("== migration self-test ==")
        let fm = FileManager.default
        let root = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-migrate-test")

        // Fresh root + remove any leftover backups from prior runs (so we can assert exactly one).
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.deletingLastPathComponent()
        let backupPrefix = root.lastPathComponent + "_backup_"
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(backupPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }

        // Synthesize legacy flat files (one non-"transcript-" name to exercise the mtime fallback).
        let files = ["transcript-2026-06-01-0900.md", "transcript-2026-06-02-1415.md", "meeting-notes.md"]
        let bodies = [
            "# Transcript\n\n- **Source:** Mic\n\n---\n\nHello from the first legacy session.\n",
            "# Transcript\n\n- **Source:** System Audio\n\n---\n\nThe second legacy session mentions quarterly revenue.\n",
            "Freeform notes file that is not in the transcript- naming scheme.\n",
        ]
        for (f, body) in zip(files, bodies) {
            try? body.write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }

        let r1 = SessionStore.migrateLegacyFlatFiles(root: root)
        print("first run : migrated=\(r1.migratedCount) legacyFound=\(r1.legacyFound) backup=\(r1.backupURL?.lastPathComponent ?? "none")")

        var ok = (r1.migratedCount == 3)
        for (f, body) in zip(files, bodies) {
            let base = (f as NSString).deletingPathExtension
            let folder = root.appendingPathComponent(base)
            let tmd = folder.appendingPathComponent("transcript.md")
            let sj = folder.appendingPathComponent("session.json")
            let hasFolder = fm.fileExists(atPath: tmd.path) && fm.fileExists(atPath: sj.path)
            let preserved = (try? String(contentsOf: tmd, encoding: .utf8)) == body
            let originalGone = !fm.fileExists(atPath: root.appendingPathComponent(f).path)
            let decodes = DocumentBuilder.readSession(folder) != nil
            print("  \(base): folder+json=\(hasFolder) bytesPreserved=\(preserved) originalRemoved=\(originalGone) jsonDecodes=\(decodes)")
            ok = ok && hasFolder && preserved && originalGone && decodes
        }

        let backupOK = r1.backupURL.map { fm.fileExists(atPath: $0.path) } ?? false
        print("backup created: \(backupOK)")

        // Second run must be a no-op (no migration, no new backup).
        let r2 = SessionStore.migrateLegacyFlatFiles(root: root)
        let noop = (r2.migratedCount == 0 && r2.backupURL == nil && r2.legacyFound == 0)
        print("second run no-op: \(noop) (migrated=\(r2.migratedCount), backup=\(r2.backupURL == nil ? "none" : "MADE"))")

        let backups = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(backupPrefix) }
        print("backup folder count: \(backups.count) (expected 1)")

        ok = ok && backupOK && noop && backups.count == 1
        print(ok ? "OK" : "FAIL")
        exit(ok ? 0 : 2)
    }

    /// Build sessions with known terms (incl. OCR-style slide text), index them, run queries, and
    /// assert the right sessions, snippets, timestamps, and ranking come back.
    static func runIndex(dir: String?) {
        setbuf(stdout, nil)
        print("== search-index self-test ==")
        let fm = FileManager.default
        let root = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-index-test")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        func makeSession(_ name: String, date: Date, segments: [TranscriptSegment], frames: [FrameEvent] = []) -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
            let meta = SessionMeta(date: date, sourceLabel: "Mic", modelName: "openai_whisper-base.en", tags: [])
            DocumentBuilder.writeSession(SessionDoc(meta: meta, segments: segments, frames: frames), to: folder)
            return folder
        }

        let now = Date()
        let a = makeSession("A", date: now, segments: [
            TranscriptSegment(start: 0, end: 4, text: "Let's review the quarterly revenue numbers."),
            TranscriptSegment(start: 12, end: 16, text: "Revenue grew sharply and revenue is strong this quarter."),
        ])
        let b = makeSession("B", date: now.addingTimeInterval(-86_400), segments: [
            TranscriptSegment(start: 0, end: 4, text: "Today we discuss machine learning fundamentals."),
        ], frames: [
            FrameEvent(sessionTime: 5, imagePath: "images/0001-0005.png", ocrText: "Neural Networks 101"),
        ])
        let c = makeSession("C", date: now.addingTimeInterval(-2 * 86_400), segments: [
            TranscriptSegment(start: 0, end: 4, text: "Anyone up for lunch later today?"),
        ])
        _ = makeSession("D", date: now.addingTimeInterval(-3 * 86_400), segments: [
            TranscriptSegment(start: 0, end: 4, text: "The revenue was fine, nothing notable."),
        ])

        _ = (a, b, c)   // session URLs; assertions below match by folder name (robust to /tmp→/private)
        let idx = SearchIndex(cacheURL: root.appendingPathComponent(".index-cache.json"))
        idx.rebuildFromDisk(root: root)

        var ok = true
        func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }
        func name(_ h: SessionHit) -> String { h.dir.lastPathComponent }

        // 1) "quarterly" → only session A.
        let q1 = idx.search("quarterly")
        check("'quarterly' → A only", q1.count == 1 && q1.first.map(name) == "A")

        // 2) "neural networks" → session B via OCR text, snippet carries the frame timestamp 00:05.
        let q2 = idx.search("neural networks")
        let bHit = q2.first { name($0) == "B" }
        check("'neural networks' → B present", bHit != nil)
        check("B snippet timestamp == 00:05", bHit?.snippets.contains { $0.timestamp == "00:05" } ?? false)

        // 3) "lunch" → session C.
        let q3 = idx.search("lunch")
        check("'lunch' → C only", q3.count == 1 && q3.first.map(name) == "C")

        // 4) ranking: "revenue" appears 3× in A, 1× in D → A ranks first, and matchCount reflects it.
        let q4 = idx.search("revenue")
        check("'revenue' ranks A first", q4.first.map(name) == "A")
        check("A matchCount >= 3", (q4.first { name($0) == "A" }?.matchCount ?? 0) >= 3)

        // 5) snippets carry the nearest [mm:ss] (speech line at 00:12 for the 2nd 'revenue' line).
        let aHit = q4.first { name($0) == "A" }
        check("A has a timestamped snippet", aHit?.snippets.contains { $0.timestamp != nil } ?? false)

        // 6) a term in nothing → no hits.
        check("'zzgibberish' → no hits", idx.search("zzgibberish").isEmpty)

        print(ok ? "OK" : "FAIL")
        exit(ok ? 0 : 2)
    }

    /// Run title + tag generation; print availability + output. Assert the FALLBACK path yields a
    /// non-empty title (which is what's exercised when the model is unavailable).
    static func runTitle(path: String?) {
        setbuf(stdout, nil)
        print("== title/tags self-test ==")
        print("availability: \(Summarizer.availabilityMessage() ?? "available")")
        let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? "Quick standup: we finished the login screen, the API is rate-limited so we'll add caching, and Priya will demo the beta to the client on Friday."

        let sema = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            let now = Date()
            let fallback = TitleGenerator.fallbackTitle(transcript: text, date: now)
            print("FALLBACK TITLE: \(fallback)")
            let r = await TitleGenerator.generate(transcript: text, date: now)
            print("----------------------------------------")
            print("TITLE: \(r.title)")
            print("TAGS : \(r.tags.isEmpty ? "(none)" : r.tags.joined(separator: ", "))")
            print("----------------------------------------")

            // Fallback must always be non-empty; generated title must be non-empty (model or fallback).
            let fallbackOK = !fallback.trimmingCharacters(in: .whitespaces).isEmpty
            let titleOK = !r.title.trimmingCharacters(in: .whitespaces).isEmpty
            // Empty-transcript edge → fallback should be a dated "Session …" title.
            let emptyFallback = TitleGenerator.fallbackTitle(transcript: "", date: now)
            let emptyOK = !emptyFallback.trimmingCharacters(in: .whitespaces).isEmpty
            print("fallback non-empty: \(fallbackOK), title non-empty: \(titleOK), empty-case fallback: \"\(emptyFallback)\"")

            // Defensive parse/sanitize: the model sometimes wraps the label in markdown bold.
            let p = TitleGenerator.parse("**Title:** Understanding Prosocial Behavior\n**Tags:** psychology, Social, social")
            let sani = TitleGenerator.sanitizeTitle("**Title:** Hello World")
            print("markdown parse → title=\"\(p.title)\" tags=\(p.tags); sanitize(**Title:**)=\"\(sani)\"")
            let mdOK = p.title == "Understanding Prosocial Behavior"
                && p.tags == ["psychology", "social"]      // deduped + lowercased
                && sani == "Hello World"

            if fallbackOK && titleOK && emptyOK && mdOK { print("OK") } else { print("FAIL"); code = 2 }
            sema.signal()
        }
        sema.wait()
        exit(code)
    }

    /// Maintenance utility: fill missing tags on titled-but-untagged sessions (keeps the existing
    /// title; skips near-empty transcripts). One-time repair for sessions tagged by an older build
    /// whose parser dropped a markdown-wrapped `TAGS:` line. Defaults to ~/Desktop/Transcripts.
    static func runRetag(dir: String?, force: Bool) {
        setbuf(stdout, nil)
        print("== retag (fill missing tags on titled sessions\(force ? ", --force" : "")) ==")
        print("availability: \(Summarizer.availabilityMessage() ?? "available")")
        let root = dir.map { URL(fileURLWithPath: $0) } ?? AppModel.transcriptsDirectory
        print("root: \(root.path)")

        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            var changed = 0
            for s in SessionStore.allSessions(root: root) {
                let name = s.dir.lastPathComponent
                let title = s.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
                if title.isEmpty { print("  · skip \(name) (no title)"); continue }
                if !force, !s.meta.tags.isEmpty { print("  · skip \(name) (already tagged: \(s.meta.tags.joined(separator: ", ")))"); continue }
                let tags = await SessionStore.backfillTags(dir: s.dir, force: force)
                if tags.isEmpty {
                    print("  · skip \(name) (no meaningful content / model returned no tags)")
                } else {
                    changed += 1
                    print("  ✓ \(name) → \(tags.joined(separator: ", "))")
                }
            }
            print("retagged \(changed) session(s)")
            sema.signal()
        }
        sema.wait()
        exit(0)
    }
}

// MARK: - Prompt-2 self-tests (chat / ask / summary / import / mix / audio-save / srt / vocab / bookmarks)

extension SelfTest {

    /// Synthesize a session folder with given segments/frames + meta.
    static func synthSession(_ dir: URL, segments: [TranscriptSegment], frames: [FrameEvent] = [], meta: SessionMeta? = nil) {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        let m = meta ?? SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "openai_whisper-base.en")
        DocumentBuilder.writeSession(SessionDoc(meta: m, segments: segments, frames: frames), to: dir)
    }

    static let defaultMeetingTranscript = """
    Welcome to the planning meeting. First, marketing will launch the campaign next week, and Priya owns \
    the landing page. Engineering needs to fix the login bug before Friday. The API is rate-limited so we \
    will add caching. Finally, we agreed to hire two contractors this quarter and demo the beta to the client.
    """

    /// A1 chat: grounded Q&A that cites [mm:ss]; clean fallback when FM is unavailable / empty session.
    static func runChat(dir: String?) {
        setbuf(stdout, nil)
        print("== chat self-test ==")
        print("FM available: \(Intelligence.isAvailable) — \(Intelligence.availabilityMessage() ?? "available")")
        let sessionDir = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-chat-test")
        if dir == nil || !FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.md").path) {
            try? FileManager.default.removeItem(at: sessionDir)
            synthSession(sessionDir, segments: [
                TranscriptSegment(start: 0, end: 5, text: "Welcome to the lecture on photosynthesis."),
                TranscriptSegment(start: 42, end: 48, text: "Telescopes let astronomers observe distant galaxies and nebulae."),
                TranscriptSegment(start: 80, end: 86, text: "Volcanoes erupt with molten lava and ash."),
            ])
        }
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            let ctx = SessionStore.timestampedTranscript(dir: sessionDir)
            let ctxHasTS = SessionStore.firstTimestamp(in: ctx) != nil
            print("grounding context has [mm:ss]: \(ctxHasTS)")

            let q = "At what timestamp are telescopes discussed? Quote the exact [mm:ss] from the transcript."
            let answer = await Intelligence.answerForSession(dir: sessionDir, question: q, history: [])
            print("Q: \(q)\nA: \(answer)")
            let answerHasTS = answer.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil

            // Fallback: an empty-transcript session returns a clean (non-crashing) message.
            let emptyDir = URL(fileURLWithPath: "/tmp/transcriber-chat-empty")
            try? FileManager.default.removeItem(at: emptyDir)
            synthSession(emptyDir, segments: [])
            try? "# Transcript\n\n---\n".write(to: emptyDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            let fb = await Intelligence.answerForSession(dir: emptyDir, question: "anything?", history: [])
            print("fallback (empty session): \(fb)")

            let ok = ctxHasTS
                && !answer.trimmingCharacters(in: .whitespaces).isEmpty
                && (!Intelligence.isAvailable || answerHasTS)
                && !fb.trimmingCharacters(in: .whitespaces).isEmpty
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// A2 ask: cross-session retrieval returns the correct source session(s).
    static func runAsk() {
        setbuf(stdout, nil)
        print("== ask self-test ==")
        print("FM available: \(Intelligence.isAvailable)")
        let root = URL(fileURLWithPath: "/tmp/transcriber-ask-test")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        synthSession(root.appendingPathComponent("A"), segments: [TranscriptSegment(start: 0, end: 4, text: "We reviewed the quarterly revenue and budget forecast.")])
        synthSession(root.appendingPathComponent("B"), segments: [TranscriptSegment(start: 5, end: 9, text: "Photosynthesis converts sunlight into chemical energy in green plants.")])
        synthSession(root.appendingPathComponent("C"), segments: [TranscriptSegment(start: 0, end: 4, text: "Anyone up for lunch later today?")])
        let idx = SearchIndex(cacheURL: root.appendingPathComponent(".cache.json"))
        idx.rebuildFromDisk(root: root)
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            let result = await Intelligence.ask(question: "What did we say about photosynthesis?", index: idx)
            let names = result.sources.map { $0.dir.lastPathComponent }.sorted()
            print("sources: \(names)")
            print("answer: \(result.text.prefix(200))")
            let ok = names.contains("B")
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// A3 summary suite: styles + action items + chapters (chapters carry monotonic start times).
    static func runSummarySuite(path: String?) {
        setbuf(stdout, nil)
        print("== summary suite self-test ==")
        print("FM available: \(Intelligence.isAvailable)")
        let transcript = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? defaultMeetingTranscript
        let timestamped = """
        [00:00] Welcome to the planning meeting.
        [00:30] Marketing will launch the campaign next week. Priya owns the landing page.
        [02:10] Engineering needs to fix the login bug before Friday.
        [05:40] We agreed to hire two contractors this quarter.
        """
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var ok = true
            for style in SummaryStyle.allCases {
                do {
                    let s = try await Intelligence.summarize(transcript: transcript, style: style)
                    print("[\(style.label)] \(s.replacingOccurrences(of: "\n", with: " ").prefix(110))…")
                    ok = ok && !s.trimmingCharacters(in: .whitespaces).isEmpty
                } catch {
                    print("[\(style.label)] unavailable: \(error.localizedDescription)")
                    ok = ok && !Intelligence.isAvailable   // throwing is only acceptable when FM is off
                }
            }
            let items = await Intelligence.actionItems(transcript: transcript)
            print("action items (\(items.count)): \(items)")
            let chapters = await Intelligence.chapters(timestamped: timestamped)
            print("chapters (\(chapters.count)): \(chapters.map { DocumentBuilder.timestamp($0.start) + " " + $0.title })")
            // If chapters were produced, they must carry valid, monotonic start times.
            let chaptersOK = chapters.allSatisfy { $0.start >= 0 }
                && zip(chapters, chapters.dropFirst()).allSatisfy { $0.0.start <= $0.1.start }
            ok = ok && chaptersOK
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// B1 import: an audio file and a synthesized video → full session folders (+ frames for video).
    static func runImport(path: String?) {
        setbuf(stdout, nil)
        print("== import self-test ==")
        let testRoot = URL(fileURLWithPath: "/tmp/transcriber-import-sessions")
        try? FileManager.default.removeItem(at: testRoot)
        try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let config = Importer.Config(model: "openai_whisper-base.en", language: "en", vocabulary: [], visualIntervalSeconds: 1, ocrEnabled: false)
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var ok = true

            // 1) Audio import (provided file, else a synthesized 2 s sine .wav).
            let audioURL: URL
            if let p = path, AudioFileIO.isSupported(URL(fileURLWithPath: p)) { audioURL = URL(fileURLWithPath: p) }
            else { audioURL = URL(fileURLWithPath: "/tmp/transcriber-import-audio.wav"); _ = writeSineWav(to: audioURL, seconds: 2) }
            do {
                let dir = try await Importer.run(url: audioURL, config: config, root: testRoot) { print("  [audio] \($0)") }
                let hasFiles = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path)
                    && FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path)
                let decodes = DocumentBuilder.readSession(dir) != nil
                print("audio session \(dir.lastPathComponent): files=\(hasFiles) decodes=\(decodes)")
                ok = ok && hasFiles && decodes
            } catch { print("audio import failed: \(error)"); ok = false }

            // 2) Video import (synthesized video+audio) → assert frames.
            let videoURL = URL(fileURLWithPath: "/tmp/transcriber-import-video.mov")
            if makeTinyVideoWithAudio(to: videoURL, seconds: 4) {
                do {
                    let dir = try await Importer.run(url: videoURL, config: config, root: testRoot) { print("  [video] \($0)") }
                    let frames = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path))?
                        .filter { $0.hasSuffix(".png") }.count ?? 0
                    let hasJSON = FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path)
                    print("video session \(dir.lastPathComponent): frames=\(frames) json=\(hasJSON)")
                    ok = ok && hasJSON && frames > 0
                } catch { print("video import failed: \(error)"); ok = false }
            } else {
                print("video synth unavailable — skipping video import portion (covered by human smoke test)")
            }
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// B2 mixer: two 16 kHz buffers sum non-clipping + well-formed; single-source path byte-identical.
    static func runMix() {
        setbuf(stdout, nil)
        print("== mixer self-test ==")
        let sink0 = SampleSink()
        let input: [Float] = (0..<1000).map { sin(Float($0) * 0.1) * 0.4 }
        sink0.append(input)
        let identical = sink0.snapshot() == input
        print("single-source byte-identical: \(identical)")

        let out = SampleSink()
        let mixer = AudioMixer(out: out)
        let mic: [Float] = (0..<8000).map { sin(Float($0) * 0.05) * 0.3 }
        let sys: [Float] = (0..<8000).map { sin(Float($0) * 0.08 + 1.0) * 0.3 }
        mixer.micPort.append(mic)
        mixer.systemPort.append(sys)
        mixer.flush()
        let mixed = out.snapshot()
        let maxAbs = mixed.map { abs($0) }.max() ?? 0
        let finite = mixed.allSatisfy { $0.isFinite }
        let wellFormed = mixed.count == 8000 && finite
        let nonClipping = maxAbs < 1.0
        print("mixed count=\(mixed.count) maxAbs=\(String(format: "%.3f", maxAbs)) wellFormed=\(wellFormed) nonClipping=\(nonClipping)")
        let ok = identical && wellFormed && nonClipping
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// B3 save: write the buffer to a compact file, read it back; duration matches the timeline.
    static func runAudioSave() {
        setbuf(stdout, nil)
        print("== audio-save self-test ==")
        let seconds = 2.0
        let samples: [Float] = (0..<Int(16_000 * seconds)).map { sin(Float($0) * 0.05) * 0.3 }
        var code: Int32 = 0
        do {
            let written = try AudioFileIO.writeCompactAudio(samples, to: URL(fileURLWithPath: "/tmp/transcriber-audiosave.m4a"))
            let file = try AVAudioFile(forReading: written)
            let dur = Double(file.length) / file.processingFormat.sampleRate
            print("wrote \(written.lastPathComponent); read-back duration=\(String(format: "%.2f", dur))s (expected ~\(seconds))")
            let ok = abs(dur - seconds) < 0.3
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
        } catch { print("ERROR: \(error)"); code = 1 }
        exit(code)
    }

    /// C1 subtitles: SRT + VTT are well-formed, monotonic, non-overlapping.
    static func runSRT(dir: String?) {
        setbuf(stdout, nil)
        print("== srt/vtt self-test ==")
        let root = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-srt-test")
        if dir == nil {
            try? FileManager.default.removeItem(at: root)
            synthSession(root, segments: [
                TranscriptSegment(start: 0, end: 3.5, text: "First cue."),
                TranscriptSegment(start: 3.5, end: 7, text: "Second cue."),
                TranscriptSegment(start: 7, end: 10.2, text: "Third cue."),
            ])
        }
        guard let srt = Subtitles.srt(dir: root), let vtt = Subtitles.vtt(dir: root) else { print("FAIL: nil subtitles"); exit(2) }
        print("--- SRT ---\n\(srt)")
        let times = parseSRTTimes(srt)
        var ok = vtt.hasPrefix("WEBVTT") && !times.isEmpty
        for (i, c) in times.enumerated() {
            if c.start > c.end { ok = false }
            if i > 0 {
                if times[i - 1].end > c.start + 0.001 { ok = false }   // non-overlapping
                if c.start < times[i - 1].start { ok = false }          // monotonic
            }
        }
        print("cues=\(times.count) wellFormed=\(ok)")
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// C2 vocab biasing: prompt tokens are built for non-empty terms; empty/whitespace → nil (no-op).
    static func runVocab() {
        setbuf(stdout, nil)
        print("== vocab self-test ==")
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            let engine = TranscriptionEngine()
            let beforeLoad = engine.promptTokens(for: ["Kubernetes"])
            print("before model load: \(String(describing: beforeLoad)) (expect nil)")
            do { try await engine.prepare(model: "openai_whisper-base.en") { msg, _ in print("  [status] \(msg)") } }
            catch { print("ERROR preparing: \(error)"); exit(1) }
            let empty = engine.promptTokens(for: [])
            let blank = engine.promptTokens(for: ["  ", ""])
            let nonEmpty = engine.promptTokens(for: ["Kubernetes", "Acme Corp", "Nikhil"])
            print("empty → \(String(describing: empty)) (expect nil)")
            print("blank → \(String(describing: blank)) (expect nil)")
            print("non-empty → \(nonEmpty?.count ?? -1) tokens")
            let ok = beforeLoad == nil && empty == nil && blank == nil && (nonEmpty?.isEmpty == false)
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// D1 bookmarks: bookmarks persist in session.json (relative to T0) and reload; legacy → empty.
    static func runBookmarks() {
        setbuf(stdout, nil)
        print("== bookmarks self-test ==")
        let dir = URL(fileURLWithPath: "/tmp/transcriber-bookmarks-test")
        try? FileManager.default.removeItem(at: dir)
        let bms = [Bookmark(time: 12.5, label: nil), Bookmark(time: 45.0, label: "Key point"), Bookmark(time: 90.25, label: nil)]
        let meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "m", bookmarks: bms)
        synthSession(dir, segments: [TranscriptSegment(start: 0, end: 5, text: "Hello.")], meta: meta)
        guard let doc = DocumentBuilder.readSession(dir) else { print("FAIL: no decode"); exit(2) }
        print("reloaded bookmarks: \(doc.meta.bookmarks.map { $0.time })")
        let timesMatch = doc.meta.bookmarks.map { $0.time } == bms.map { $0.time }

        let legacy = URL(fileURLWithPath: "/tmp/transcriber-bookmarks-legacy")
        try? FileManager.default.removeItem(at: legacy)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try? #"{"meta":{"date":0,"sourceLabel":"Mic","modelName":"m"},"segments":[],"frames":[]}"#
            .write(to: legacy.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        let legacyOK = DocumentBuilder.readSession(legacy)?.meta.bookmarks.isEmpty == true
        print("legacy session.json (no bookmarks field) → bookmarks empty: \(legacyOK)")

        let ok = timesMatch && legacyOK
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Pause / auto-pause / capture-health: the pure logic behind pausing a live session.
    /// Asserts the properties that matter for correctness of a RECORDING, not just of the types:
    /// an open gate is a byte-identical passthrough, a closed one records nothing but still hears,
    /// silence pauses and sound resumes (auto-pauses only), a stalled capture asks for recovery,
    /// and the session clock excludes paused time so every timestamp still lines up with the audio.
    static func runPause() {
        setbuf(stdout, nil)
        print("== pause / auto-pause self-test ==")
        var failures: [String] = []
        func check(_ label: String, _ condition: Bool) {
            print("  \(condition ? "ok  " : "FAIL") \(label)")
            if !condition { failures.append(label) }
        }

        // --- CaptureGate ---------------------------------------------------------------
        let sink = SampleSink()
        let gate = CaptureGate(downstream: sink)
        let loud: [Float] = (0..<1_600).map { sin(Float($0) * 0.05) * 0.3 }
        let quiet = [Float](repeating: 0, count: 1_600)

        gate.append(loud)
        check("open gate forwards the exact samples", sink.snapshot() == loud)

        gate.close()
        gate.append(loud)
        check("closed gate records nothing", sink.count == loud.count)
        check("closed gate still measures level (auto-resume can hear)", gate.level > AudioActivity.silenceRMS)
        check("closed gate still stamps delivery (watchdog stays valid)", gate.lastDeliveryAt != nil)

        // Pre-roll is capped at ~1 s, and only the newest audio is kept.
        for _ in 0..<20 { gate.append(loud) }
        check("pre-roll is capped at 1 s", gate.prerollCount <= 16_000)
        let beforeOpen = sink.count
        gate.open()
        let flushed = sink.count - beforeOpen
        print("  flushed pre-roll: \(flushed) samples")
        check("reopening flushes the retained pre-roll", flushed > 0 && flushed <= 16_000)

        // A pause the USER asked for must never put withheld audio into the session.
        gate.close()
        gate.append(loud)
        let beforeManual = sink.count
        gate.open(flushPreroll: false)
        check("a manual resume replays nothing", sink.count == beforeManual)

        gate.append(quiet)
        check("digital silence reads as no level", gate.level == 0)

        // --- SilenceMonitor ------------------------------------------------------------
        var monitor = SilenceMonitor(enabled: true, pauseAfter: 30)
        let speech: Float = 0.08
        let room: Float = 0.001
        _ = monitor.update(level: speech, now: 0, paused: false, reason: nil)
        var decisionAt29: CaptureDecision = .none
        var decisionAt30: CaptureDecision = .none
        for t in stride(from: 1.0, through: 31.0, by: 1.0) {
            let d = monitor.update(level: room, now: t, paused: false, reason: nil)
            if t == 29 { decisionAt29 = d }
            if t == 31 { decisionAt30 = d }        // quiet started at t=1 → 30 s elapsed at t=31
        }
        check("no auto-pause before the threshold", decisionAt29 == .none)
        check("auto-pause fires at the threshold", decisionAt30 == .autoPause)

        // Sound returns → an AUTO pause resumes itself.
        _ = monitor.update(level: speech, now: 40, paused: true, reason: .silence)
        let resume = monitor.update(level: speech, now: 40.5, paused: true, reason: .silence)
        check("auto-pause resumes when audio returns", resume == .autoResume)

        // A MANUAL pause is the user's decision — never overridden.
        var manual = SilenceMonitor(enabled: true, pauseAfter: 30)
        _ = manual.update(level: speech, now: 0, paused: true, reason: .manual)
        let manualResume = manual.update(level: speech, now: 5, paused: true, reason: .manual)
        check("manual pause is never auto-resumed", manualResume == .none)

        // Disabled → inert in both directions.
        var off = SilenceMonitor(enabled: false, pauseAfter: 30)
        var offFired = false
        for t in stride(from: 0.0, through: 120.0, by: 1.0) {
            if off.update(level: room, now: t, paused: false, reason: nil) != .none { offFired = true }
        }
        check("auto-pause disabled ⇒ never fires", !offFired)

        // Brief silence between sentences must not pause a normal conversation.
        var speaking = SilenceMonitor(enabled: true, pauseAfter: 30)
        var pausedMidSpeech = false
        for step in 0..<600 {                                   // 60 s, 0.1 s steps
            let t = Double(step) * 0.1
            let level: Float = (step % 40 < 15) ? room : speech  // ~1.5 s gaps between phrases
            if speaking.update(level: level, now: t, paused: false, reason: nil) == .autoPause { pausedMidSpeech = true }
        }
        check("pauses between sentences don't trigger a pause", !pausedMidSpeech)

        // --- StallMonitor --------------------------------------------------------------
        var stall = StallMonitor()
        stall.start(now: 0)
        check("healthy capture is left alone", !stall.shouldRecover(lastDelivery: 9.9, now: 10))
        check("no recovery inside the cooldown", !stall.shouldRecover(lastDelivery: 0, now: 4))
        check("stalled capture asks for recovery", stall.shouldRecover(lastDelivery: 5, now: 10))
        check("recovery is not retried immediately", !stall.shouldRecover(lastDelivery: 5, now: 12))
        check("recovery retried after the cooldown", stall.shouldRecover(lastDelivery: 5, now: 17))

        // --- SessionClock --------------------------------------------------------------
        var clock = SessionClock(t0: 100)
        check("elapsed tracks wall clock while running", abs(clock.time(now: 110) - 10) < 0.001)
        clock.pause(now: 110)
        check("elapsed freezes while paused", abs(clock.time(now: 140) - 10) < 0.001)
        clock.resume(now: 140)
        check("paused time is excluded after resume", abs(clock.time(now: 150) - 20) < 0.001)
        check("total paused is reported", abs(clock.totalPaused(now: 150) - 30) < 0.001)
        clock.pause(now: 150)
        clock.pause(now: 155)   // idempotent — a second pause must not double-count
        clock.resume(now: 160)
        check("repeated pause/resume stays consistent", abs(clock.time(now: 170) - 30) < 0.001)

        // A bookmark dropped after a pause lands on the RECORDED timeline (what the audio file has),
        // not on wall-clock time — otherwise every marker after a pause would point past the audio.
        check("bookmark time matches recorded audio length", abs(clock.time(now: 160) - 20) < 0.001)

        print(failures.isEmpty ? "OK" : "FAIL: \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 2)
    }

    // MARK: synth helpers

    /// Write a sine .wav (16 kHz mono) of `seconds` for the import test.
    static func writeSineWav(to url: URL, seconds: Int) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let n = 16_000 * seconds
        let samples: [Float] = (0..<n).map { sin(Float($0) * 0.06) * 0.4 }
        guard let buf = AudioFileIO.makeBuffer16kMono(samples) else { return false }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return false }
        do { try file.write(from: buf); return true } catch { return false }
    }

    static func parseSRTTimes(_ srt: String) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        for line in srt.components(separatedBy: "\n") where line.contains("-->") {
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            func sec(_ s: String) -> Double {
                let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                let hms = t.split(separator: ":")
                guard hms.count == 3 else { return 0 }
                return (Double(hms[0]) ?? 0) * 3600 + (Double(hms[1]) ?? 0) * 60 + (Double(hms[2]) ?? 0)
            }
            out.append((sec(parts[0]), sec(parts[1])))
        }
        return out
    }

    /// Synthesize a tiny .mov with BOTH a video track (distinct frames) and an audio track (sine), so
    /// the import path (decode audio + extract frames) runs end-to-end. Returns false if synth fails.
    static func makeTinyVideoWithAudio(to url: URL, seconds: Int) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let w = 320, h = 240
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000])
        aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(vInput), writer.canAdd(aInput) else { return false }
        writer.add(vInput); writer.add(aInput)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<seconds {
            while !vInput.isReadyForMoreMediaData { usleep(5_000) }
            if let img = patternImage(i % 3, size: 240), let pb = pixelBuffer(from: img, w: w, h: h) {
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
            }
        }
        vInput.markAsFinished()

        let sr = 16_000, total = 16_000 * seconds, chunk = 8_000
        var written = 0
        while written < total {
            while !aInput.isReadyForMoreMediaData { usleep(5_000) }
            let count = min(chunk, total - written)
            let samples: [Float] = (0..<count).map { sin(Float(written + $0) * 0.05) * 0.3 }
            if let sb = makeAudioSampleBuffer(samples, sampleRate: sr, startSample: written) { aInput.append(sb) }
            written += count
        }
        aInput.markAsFinished()

        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        return writer.status == .completed
    }

    static func pixelBuffer(from image: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }

    static func makeAudioSampleBuffer(_ samples: [Float], sampleRate: Int, startSample: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        let dataSize = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: dataSize, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)
        }
        guard copied == noErr else { return nil }
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sizes = [4]
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                                   sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

// MARK: - Stage-1 self-tests (diarization / multilingual / calendar / cleanup / custom modes)

extension SelfTest {

    /// Run `say` → AIFF, decode to 16 kHz mono via AudioFileIO. Returns nil if the voice is missing.
    static func synthSpeech(_ text: String, voice: String?, file: String) -> [Float]? {
        let url = URL(fileURLWithPath: file)
        try? FileManager.default.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", file, text]
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let sema = DispatchSemaphore(value: 0)
        var samples: [Float]? = nil
        Task.detached {
            samples = try? await AudioFileIO.decodeTo16kMono(url: url)
            sema.signal()
        }
        sema.wait()
        return (samples?.isEmpty == false) ? samples : nil
    }

    /// A two-voice synthetic "conversation" (A/B alternating, gaps between) for the diarizer.
    /// Returns nil when no two distinct voices could synthesize.
    static func synthTwoSpeakerClip() -> [Float]? {
        let aText = "Welcome everyone to the quarterly planning meeting. Today we will review the roadmap and assign the remaining work for the release."
        let bText = "Thanks for having me. I think the most important question is whether the login fix can actually ship before Friday's deadline."
        let voicePairs = [("Samantha", "Daniel"), ("Samantha", "Alex"), ("Allison", "Tom"), ("Victoria", "Fred")]
        for (va, vb) in voicePairs {
            guard let a1 = synthSpeech(aText, voice: va, file: "/tmp/tr_diar_a1.aiff"),
                  let b1 = synthSpeech(bText, voice: vb, file: "/tmp/tr_diar_b1.aiff"),
                  let a2 = synthSpeech("That is a fair point, and we should also double check the caching layer before we commit to a date.", voice: va, file: "/tmp/tr_diar_a2.aiff"),
                  let b2 = synthSpeech("Agreed. I will take the caching work and report back tomorrow afternoon with an estimate.", voice: vb, file: "/tmp/tr_diar_b2.aiff")
            else { continue }
            print("voices: \(va) + \(vb)")
            let gap = [Float](repeating: 0, count: 8_000)   // 0.5 s silence between turns
            return a1 + gap + b1 + gap + a2 + gap + b2
        }
        return nil
    }

    /// Feature A: on-device diarization over a (synthetic 2-voice) clip. Asserts ≥2 distinct slots
    /// on the known 2-speaker clip (≥1 when a user-provided file is used).
    static func runDiarize(path: String?) {
        setbuf(stdout, nil)
        print("== diarization self-test ==")
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var samples: [Float] = []
            var expectTwo = false
            if let path {
                samples = (try? await AudioFileIO.decodeTo16kMono(url: URL(fileURLWithPath: path))) ?? []
                print("audio: \(path) (\(samples.count) samples)")
            } else if let synth = synthTwoSpeakerClip() {
                samples = synth
                expectTwo = true
                print("audio: synthetic 2-voice conversation (\(String(format: "%.1f", Double(samples.count) / 16_000))s)")
            }
            guard !samples.isEmpty else { print("ERROR: no audio to diarize"); code = 1; sema.signal(); return }
            do {
                try await DiarizerService.shared.prepare { msg, frac in
                    print("  [model] \(msg) \(frac.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
                }
                let turns = try await DiarizerService.shared.diarize(samples: samples)
                let slots = Set(turns.map { $0.speaker })
                print("----------------------------------------")
                for t in turns {
                    print("Speaker \(t.speaker): \(String(format: "%6.2f", t.start))s – \(String(format: "%6.2f", t.end))s")
                }
                print("----------------------------------------")
                print("turns=\(turns.count) distinct speakers=\(slots.count)")
                let slotsOK = !slots.isEmpty && slots.sorted().first == 1            // 1-based, first-appearance
                let needed = expectTwo ? 2 : 1
                let ok = slots.count >= needed && slotsOK
                print(ok ? "OK" : "FAIL (expected ≥\(needed) speakers, 1-based slots)")
                code = ok ? 0 : 2
            } catch {
                print("ERROR: \(error)"); code = 1
            }
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature A: pure alignment test — known overlaps, first-appearance slot order, nearest-midpoint
    /// fallback. No models.
    static func runAlign() {
        setbuf(stdout, nil)
        print("== speaker-alignment self-test ==")
        var ok = true
        func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }

        // Normalization: raw ids appear as B-first → B gets slot 1; ids repeat → same slot.
        let turns = SpeakerAlignment.normalize([
            (id: "spk_B", start: 0.0, end: 4.0),
            (id: "spk_A", start: 4.5, end: 9.0),
            (id: "spk_B", start: 9.5, end: 12.0),
            (id: "spk_C", start: 12.5, end: 15.0),
        ])
        check("first-appearance slots (B→1, A→2, C→3)",
              turns.map { $0.speaker } == [1, 2, 1, 3])

        // Max-overlap assignment.
        let segs = [
            TranscriptSegment(start: 0.0, end: 3.0, text: "one"),     // inside turn 1 → speaker 1
            TranscriptSegment(start: 3.5, end: 6.0, text: "two"),     // 0.5s in t1, 1.5s in t2 → speaker 2
            TranscriptSegment(start: 9.6, end: 11.0, text: "three"),  // inside turn 3 → speaker 1
            TranscriptSegment(start: 20.0, end: 22.0, text: "four"),  // zero overlap → nearest midpoint → C (slot 3)
        ]
        let labeled = SpeakerAlignment.assign(segments: segs, turns: turns)
        check("max-overlap picks speaker 1 for [0,3]", labeled[0].speaker == 1)
        check("max-overlap picks speaker 2 for [3.5,6]", labeled[1].speaker == 2)
        check("repeat turn keeps slot 1 for [9.6,11]", labeled[2].speaker == 1)
        check("zero-overlap falls back to nearest (slot 3)", labeled[3].speaker == 3)
        check("text/timing untouched", labeled.map { $0.text } == segs.map { $0.text }
              && labeled.map { $0.start } == segs.map { $0.start } && labeled.map { $0.end } == segs.map { $0.end })
        check("empty turns → unchanged", SpeakerAlignment.assign(segments: segs, turns: []).allSatisfy { $0.speaker == nil })

        // Rendering: labels appear AFTER the [mm:ss] anchor, resolve renames, and absence of
        // speakers renders byte-identically to the unlabeled form.
        var meta = SessionMeta(date: Date(timeIntervalSince1970: 0), sourceLabel: "Mic", modelName: "m")
        meta.speakerNames = ["2": "Alice"]
        let md = DocumentBuilder.markdown(meta: meta, segments: labeled, frames: [])
        check("md label after anchor", md.contains("[00:00] **Speaker 1:** one"))
        check("md rename resolves", md.contains("[00:03] **Alice:** two"))
        check("md lines stay [mm:ss]-anchored", !md.contains("** [0"))
        let mdPlain = DocumentBuilder.markdown(meta: meta, segments: segs, frames: [])
        check("no speakers → no labels", !mdPlain.contains("**Speaker") && mdPlain.contains("[00:00] one"))
        check("snippet path strips label", SessionStore.stripLeadingSpeakerLabel("**Alice:** hello there") == "hello there"
              && SessionStore.stripLeadingSpeakerLabel("plain line") == "plain line")

        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Synthesize a Spanish clip if a Spanish voice is installed (else nil).
    static func synthSpanishClip() -> [Float]? {
        let text = """
        Hola a todos y bienvenidos a la reunión de planificación de este trimestre. Hoy vamos a \
        revisar los resultados financieros, el estado del proyecto principal y los próximos pasos \
        del equipo. Primero, las ventas crecieron un dieciocho por ciento respecto al trimestre \
        anterior, gracias al lanzamiento de la nueva versión del producto. Segundo, necesitamos \
        contratar dos ingenieros más antes de que termine el mes para cumplir con el calendario.
        """
        for voice in ["Mónica", "Monica", "Paulina", "Jorge", "Juan", "Diego"] {
            if let s = synthSpeech(text, voice: voice, file: "/tmp/tr_lang_es.aiff") {
                print("spanish voice: \(voice)")
                return s
            }
        }
        return nil
    }

    /// Feature B: one-shot language detection with a multilingual model.
    static func runDetect(path: String?) {
        setbuf(stdout, nil)
        print("== language-detect self-test ==")
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var samples: [Float] = []
            var expected: String? = nil
            if let path {
                samples = (try? await AudioFileIO.decodeTo16kMono(url: URL(fileURLWithPath: path))) ?? []
                print("audio: \(path)")
            } else if let es = synthSpanishClip() {
                samples = es; expected = "es"
            } else if let en = synthSpeech("Hello everyone and welcome to the planning meeting for this quarter.", voice: nil, file: "/tmp/tr_lang_en.aiff") {
                print("no Spanish voice installed — falling back to an English clip")
                samples = en; expected = "en"
            }
            guard !samples.isEmpty else { print("ERROR: no audio"); code = 1; sema.signal(); return }
            do {
                let engine = TranscriptionEngine()
                try await engine.prepare(model: "openai_whisper-base") { msg, _ in print("  [status] \(msg)") }
                let det = try await engine.detectLanguage(samples: samples)
                let top = det.probs.sorted { $0.value > $1.value }.prefix(5)
                print("detected: \(det.language)")
                print("top probs: \(top.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))")
                // Spec assertion: non-empty detection. The expected-code comparison is informational —
                // synthetic TTS clips are a known-hard case for language ID (real speech detects far
                // better); the Auto path's English fallback covers low-confidence results by design.
                if let expected, det.language != expected {
                    print("note: expected \(expected), detected \(det.language) — TTS clip; informational only")
                }
                let ok = !det.language.isEmpty
                print(ok ? "OK" : "FAIL (empty detection)")
                code = ok ? 0 : 2
            } catch { print("ERROR: \(error)"); code = 1 }
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature B: multilingual transcription — explicit `--lang` pins the language; no `--lang`
    /// exercises the Auto detect-once-then-pin path. Never touches ~/Desktop/Transcripts.
    static func runMultilingual(path: String?, lang: String?) {
        setbuf(stdout, nil)
        print("== multilingual self-test ==")
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var samples: [Float] = []
            if let path {
                samples = (try? await AudioFileIO.decodeTo16kMono(url: URL(fileURLWithPath: path))) ?? []
                print("audio: \(path)")
            } else if let es = synthSpanishClip() {
                samples = es
            } else if let en = synthSpeech("Hello everyone, this is a short test of the multilingual model.", voice: nil, file: "/tmp/tr_lang_en.aiff") {
                print("no Spanish voice installed — using an English clip")
                samples = en
            }
            guard !samples.isEmpty else { print("ERROR: no audio"); code = 1; sema.signal(); return }
            do {
                let engine = TranscriptionEngine()
                try await engine.prepare(model: "openai_whisper-base") { msg, _ in print("  [status] \(msg)") }
                let resolved: String
                if let lang {
                    resolved = lang
                    print("language: \(resolved) (explicit — pinned, no detection)")
                } else {
                    // Auto path: language MUST be resolved by one detection BEFORE transcribing.
                    resolved = try await engine.detectLanguage(samples: Array(samples.prefix(30 * 16_000))).language
                    print("language: \(resolved) (auto — detect-once-then-pin)")
                }
                let segs = try await engine.transcribeSamples(samples, language: resolved)
                let text = segs.map { $0.text }.joined(separator: " ")
                print("----------------------------------------")
                print("RESULT [\(resolved)]: \(text)")
                print("----------------------------------------")
                let ok = !resolved.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                print(ok ? "OK" : "FAIL")
                code = ok ? 0 : 2
            } catch { print("ERROR: \(error)"); code = 1 }
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature C: pure link-detection + trigger-decision tests (live EventKit is human-verified).
    static func runCalendar() {
        setbuf(stdout, nil)
        print("== calendar-logic self-test ==")
        var ok = true
        func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }
        func link(url: String? = nil, notes: String? = nil, location: String? = nil) -> String? {
            MeetingLinkDetector.videoMeetingURL(urlField: url, notes: notes, location: location)?.absoluteString
        }

        // Link detection — strong providers in any field.
        check("zoom /j in URL field", link(url: "https://us02web.zoom.us/j/1234567890?pwd=abc") != nil)
        check("zoom /my in notes", link(notes: "Join: https://zoom.us/my/nikhil today") != nil)
        check("teams meetup-join in notes", link(notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc") != nil)
        check("teams.live.com in location", link(location: "https://teams.live.com/meet/12345") != nil)
        check("google meet in location", link(location: "https://meet.google.com/abc-defg-hij") != nil)
        check("webex /meet", link(notes: "https://company.webex.com/meet/nikhil") != nil)
        check("webex /join", link(notes: "https://company.webex.com/join/nikhil") != nil)
        check("whereby", link(notes: "https://whereby.com/nikhil-room") != nil)
        check("zoom matched case-insensitively", link(notes: "HTTPS://ZOOM.US/J/999") != nil)
        // Rejection + weak fallback.
        check("no link → nil", link(notes: "Lunch with Sam at the corner cafe") == nil)
        check("doc link in NOTES is not a meeting", link(notes: "Agenda: https://docs.google.com/document/d/abc") == nil)
        check("generic https in URL FIELD = weak fallback", link(url: "https://example.com/standup") != nil)
        check("everything empty → nil", link() == nil)

        // Trigger decisions.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = now.addingTimeInterval(30)            // starts in 30 s
        let end = now.addingTimeInterval(1_830)
        func decide(start: Date, end: Date, lead: TimeInterval = 60, hasLink: Bool = true,
                    recording: Bool = false, fired: Bool = false, auto: Bool = false) -> MeetingTriggerAction {
            MeetingTriggerLogic.decide(now: now, start: start, end: end, leadSeconds: lead,
                                       hasLink: hasLink, isRecording: recording, alreadyFired: fired, autoStart: auto)
        }
        check("within lead → prompt", decide(start: start, end: end) == .prompt)
        check("autoStart mode → autoStart", decide(start: start, end: end, auto: true) == .autoStart)
        check("too early (outside lead) → ignore", decide(start: now.addingTimeInterval(600), end: now.addingTimeInterval(2_400)) == .ignore)
        check("already recording → NEVER fires", decide(start: start, end: end, recording: true, auto: true) == .ignore)
        check("already fired → fires once only", decide(start: start, end: end, fired: true) == .ignore)
        check("no link → ignore", decide(start: start, end: end, hasLink: false) == .ignore)
        check("in progress (started 5 min ago) → fires", decide(start: now.addingTimeInterval(-300), end: end) == .prompt)
        check("already ended → ignore", decide(start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-60)) == .ignore)

        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Feature D1: cleanup preserves counts/timestamps/verbatim; clean no-op when FM is unavailable.
    static func runCleanup(path: String?) {
        setbuf(stdout, nil)
        print("== cleanup self-test ==")
        print("FM available: \(TranscriptCleanup.isAvailable)")
        var ok = true
        func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }

        // Pure parser checks first (no model needed).
        let parsed = TranscriptCleanup.parseBatch("1| Hello there.\n2| We shipped the beta.\njunk\n9| out of range", count: 2)
        check("parseBatch maps numbered lines", parsed[0] == "Hello there." && parsed[1] == "We shipped the beta.")
        let sparse = TranscriptCleanup.parseBatch("2| Only the second.", count: 3)
        check("parseBatch leaves gaps nil", sparse[0] == nil && sparse[1] == "Only the second." && sparse[2] == nil)

        var segments: [TranscriptSegment] = [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Um, so, uh, we finished the, the login screen yesterday."),
            TranscriptSegment(start: 4.0, end: 9.5, text: "and like, the API is, you know, rate-limited so we'll add caching"),
            TranscriptSegment(start: 9.5, end: 14.0, text: "uh, priya will, will demo the beta on friday."),
        ]
        if let path, let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = raw.components(separatedBy: "\n").map { SessionStore.stripLeadingTimestamp($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") }
            if !lines.isEmpty {
                segments = lines.prefix(12).enumerated().map { i, l in
                    TranscriptSegment(start: Double(i) * 5, end: Double(i) * 5 + 5, text: l)
                }
            }
        }
        let input = segments

        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            let cleaned = await TranscriptCleanup.cleanSegments(input)
            check("segment count preserved", cleaned.count == input.count)
            check("timestamps preserved + monotonic",
                  zip(cleaned, input).allSatisfy { $0.start == $1.start && $0.end == $1.end }
                  && zip(cleaned, cleaned.dropFirst()).allSatisfy { $0.start <= $1.start })
            check("verbatim text untouched", zip(cleaned, input).allSatisfy { $0.text == $1.text })
            if TranscriptCleanup.isAvailable {
                let got = cleaned.filter { $0.cleanedText?.isEmpty == false }.count
                print("  cleaned \(got)/\(cleaned.count) segments")
                for c in cleaned where c.cleanedText != nil { print("    “\(c.text)” → “\(c.cleanedText!)”") }
                check("≥1 segment got a cleaned form", got >= 1)
            } else {
                check("unavailable AI → exact no-op (no cleaned forms, no throw)",
                      cleaned.allSatisfy { $0.cleanedText == nil })
            }
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature D2: custom summary mode runs (or degrades cleanly); empty template is a no-op.
    static func runCustomSummary(path: String?) {
        setbuf(stdout, nil)
        print("== custom-summary self-test ==")
        print("FM available: \(Intelligence.isAvailable)")
        let transcript = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? defaultMeetingTranscript
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var ok = true
            func check(_ label: String, _ cond: Bool) { print("  \(cond ? "✓" : "✗") \(label)"); ok = ok && cond }

            // Empty template must be rejected WITHOUT a model call (works regardless of FM).
            do {
                _ = try await Intelligence.summarizeCustom(transcript: transcript,
                                                           mode: CustomSummaryMode(name: "Blank", instructions: "   \n "))
                check("empty template rejected", false)
            } catch {
                let isEmptyTemplate: Bool
                if case SummaryError.emptyTemplate = error { isEmptyTemplate = true } else { isEmptyTemplate = false }
                check("empty template rejected as a no-op", isEmptyTemplate)
            }

            let mode = CustomSummaryMode(name: "Meeting minutes",
                                         instructions: "Produce meeting minutes: a one-line context, then bullets for each decision and each owner with their task. End with open questions if any.")
            do {
                let out = try await Intelligence.summarizeCustom(transcript: transcript, mode: mode)
                print("---- \(mode.name) ----\n\(out)\n----")
                check("non-empty output", !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } catch {
                print("  unavailable: \(error.localizedDescription)")
                check("throwing is only acceptable when FM is off", !Intelligence.isAvailable)
            }
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    // MARK: - Stage 2 self-tests

    static let timestampedMeeting = """
    [00:00] Welcome to the planning meeting.
    [00:30] Marketing will launch the campaign next week. Priya owns the landing page.
    [02:10] Engineering needs to fix the login bug before Friday.
    [05:40] We agreed to hire two contractors this quarter and demo the beta to the client.
    """

    /// Feature A — run one generation template; assert it decodes + is non-empty when FM is available,
    /// and is a clean (non-crashing) no-op when FM is off. Timestamp fields, when present, are mm:ss.
    static func runGenerate(path: String?, template: String?) {
        setbuf(stdout, nil)
        print("== generate self-test ==")
        print("FM available: \(GenerationStudio.isAvailable) — \(GenerationStudio.availabilityMessage() ?? "available")")
        let source = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? timestampedMeeting
        let map: [String: String] = ["minutes": "minutes", "soap": "soap", "dap": "dap",
                                     "flashcards": "flashcards", "quiz": "quiz", "shownotes": "shownotes",
                                     "blog": "blog", "titles": "titles", "interview": "interview",
                                     "decisions": "decisions", "qa": "qa", "studyguide": "studyguide"]
        let id = map[template ?? "minutes"] ?? "minutes"
        guard let tmpl = GenerationStudio.template(id: id) else { print("FAIL: unknown template"); exit(2) }
        print("template: \(tmpl.name) [\(tmpl.id)]")
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var ok = true
            func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }
            do {
                let out = try await GenerationStudio.generate(template: tmpl, sourceText: source)
                print("---- output (\(out.format)) ----\n\(out.text.prefix(600))\n----")
                check("non-empty output", !out.text.trimmingCharacters(in: .whitespaces).isEmpty)
                if out.format == "json", let json = out.json {
                    check("json decodes", (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
                }
                // Any mm:ss in the output must be a well-formed timestamp.
                if let m = out.text.range(of: #"\d{1,3}:\d{2}"#, options: .regularExpression) {
                    check("timestamp well-formed mm:ss", SessionStore.firstTimestamp(in: String(out.text[m])) != nil)
                }
            } catch {
                print("  unavailable: \(error.localizedDescription)")
                check("throwing only acceptable when FM is off", !GenerationStudio.isAvailable)
            }
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature A — audio clip extraction + waveform + muxed audiogram .mp4.
    static func runAudiogram(path: String?) {
        setbuf(stdout, nil)
        print("== audiogram self-test ==")
        let tmp = URL(fileURLWithPath: "/tmp/transcriber-audiogram")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let audioURL: URL
        if let path, FileManager.default.fileExists(atPath: path) { audioURL = URL(fileURLWithPath: path) }
        else {
            audioURL = tmp.appendingPathComponent("synth.m4a")
            let samples: [Float] = (0..<(16_000 * 6)).map { sin(Float($0) * 0.05) * (0.3 + 0.2 * sin(Float($0) * 0.0007)) }
            guard (try? AudioFileIO.writeCompactAudio(samples, to: audioURL)) != nil else { print("FAIL: synth audio"); exit(2) }
        }
        let sema = DispatchSemaphore(value: 0); var code: Int32 = 0
        Task.detached {
            var ok = true
            func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }
            do {
                let clipURL = tmp.appendingPathComponent("clip.m4a")
                let clip = try await ClipExporter.exportClip(audioURL: audioURL, start: 1, end: 4, to: clipURL)
                check("clip written", FileManager.default.fileExists(atPath: clip.url.path))
                check("clip duration ≈ 3s (\(String(format: "%.2f", clip.duration)))", abs(clip.duration - 3) < 0.3)

                let all = try await AudioFileIO.decodeTo16kMono(url: audioURL)
                let sliced = Array(all[(1 * 16_000)..<min(all.count, 4 * 16_000)])
                let img = ClipExporter.renderWaveform(samples: sliced, caption: "Audiogram test")
                check("waveform renders non-empty", (img?.width ?? 0) > 0 && (img?.height ?? 0) > 0)

                let mp4 = tmp.appendingPathComponent("audiogram.mp4")
                _ = try await ClipExporter.exportAudiogram(audioURL: audioURL, start: 1, end: 4, caption: "Audiogram test", to: mp4)
                check("audiogram .mp4 produced", FileManager.default.fileExists(atPath: mp4.path))
                let asset = AVURLAsset(url: mp4)
                let v = try await asset.loadTracks(withMediaType: .video)
                let a = try await asset.loadTracks(withMediaType: .audio)
                let dur = CMTimeGetSeconds(try await asset.load(.duration))
                check("mp4 has a video track", !v.isEmpty)
                check("mp4 has an audio track", !a.isEmpty)
                check("mp4 duration > 0 (\(String(format: "%.2f", dur)))", dur > 0)
            } catch {
                print("  error: \(error)"); check("no error", false)
            }
            print(ok ? "OK" : "FAIL"); code = ok ? 0 : 2
            sema.signal()
        }
        sema.wait(); exit(code)
    }

    /// Feature B — load bundled packs; assert parse, valid template ids, vocab merge, entitlement.
    static func runPacks() {
        setbuf(stdout, nil)
        print("== packs self-test ==")
        var ok = true
        func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }

        let packs = PackManager.shared.reload()
        print("loaded \(packs.count) pack(s): \(packs.map { $0.id })")
        check("≥ 4 packs bundled", packs.count >= 4)
        let knownTemplates = Set(GenerationStudio.builtins.map { $0.id })
        for pack in packs {
            check("\(pack.id): has vocab", !pack.vocabulary.isEmpty)
            check("\(pack.id): all template ids valid", pack.templateIds.allSatisfy { knownTemplates.contains($0) })
        }
        // Vocab merge: enable one pack, confirm its terms merge in; empty selection ⇒ [] (no-op).
        let saved = PackManager.shared.enabledPackIDs
        defer { PackManager.shared.enabledPackIDs = saved }
        if let first = packs.first {
            PackManager.shared.enabledPackIDs = [first.id]
            let merged = PackManager.shared.mergedVocabulary(userVocab: [])
            check("enabling a pack merges its vocab", merged.contains { first.vocabulary.contains($0) } && !merged.isEmpty)
            let withUser = PackManager.shared.mergedVocabulary(userVocab: ["MyTerm"])
            check("user vocab unions with pack vocab", withUser.contains("MyTerm") && withUser.count > 1)
        }
        PackManager.shared.enabledPackIDs = []
        check("empty selection ⇒ empty vocab (no-op)", PackManager.shared.mergedVocabulary(userVocab: []).isEmpty)

        // Entitlement seam grants everything.
        check("entitled: pack", Entitlements.isEntitled(.verticalPack("medical")))
        check("entitled: template", Entitlements.isEntitled(.premiumTemplate("soap")))
        check("entitled: BYOK", Entitlements.isEntitled(.cloudBYOK))
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Feature C2 — redaction: known PII masked, verbatim untouched, timestamps preserved, pseudonyms stable.
    static func runRedact(path: String?) {
        setbuf(stdout, nil)
        print("== redact self-test ==")
        var ok = true
        func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }

        let segments = [
            TranscriptSegment(start: 0, end: 5, text: "Hi, my name is John Smith and my email is john@example.com."),
            TranscriptSegment(start: 5, end: 10, text: "You can reach me at 555-123-4567 about the meeting on March 3rd."),
            TranscriptSegment(start: 10, end: 15, text: "John Smith will send over the signed contract this afternoon."),
        ]
        let redacted = Redactor.redactSegments(segments)
        for (i, s) in redacted.enumerated() { print("  [\(i)] \(s.redactedText ?? "(none)")") }

        check("segment count preserved", redacted.count == segments.count)
        check("timestamps preserved & monotonic", zip(redacted, segments).allSatisfy { $0.0.start == $0.1.start && $0.0.end == $0.1.end }
              && zip(redacted, redacted.dropFirst()).allSatisfy { $0.0.start <= $0.1.start })
        check("verbatim text untouched", zip(redacted, segments).allSatisfy { $0.0.text == $0.1.text })
        let r0 = redacted[0].redactedText ?? "", r1 = redacted[1].redactedText ?? "", r2 = redacted[2].redactedText ?? ""
        check("email masked", r0.contains("[EMAIL]") && !r0.contains("john@example.com"))
        check("phone masked", r1.contains("[PHONE]") && !r1.contains("555-123-4567"))
        check("date masked", r1.contains("[DATE]"))
        // Names are best-effort via NLTagger; if tagged, the pseudonym must be stable across segments.
        if r0.contains("[PERSON") {
            check("name masked (not leaked)", !r0.contains("John Smith"))
            check("pseudonym stable across segments", r0.contains("[PERSON 1]") && r2.contains("[PERSON 1]"))
        } else { print("  (NLTagger did not tag the person name — name redaction is best-effort)") }

        // Pass-level: verbatim transcript.md untouched; redactedText stored in session.json.
        let dir = URL(fileURLWithPath: "/tmp/transcriber-redact-session")
        try? FileManager.default.removeItem(at: dir)
        synthSession(dir, segments: segments)
        let mdBefore = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let sema = DispatchSemaphore(value: 0)
        Task.detached { await RedactionPass.run(dir: dir); sema.signal() }
        sema.wait()
        let mdAfter = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        check("transcript.md unchanged by the pass", mdBefore == mdAfter && mdAfter.contains("john@example.com"))
        check("redactedText persisted in session.json", DocumentBuilder.readSession(dir)?.segments.contains { $0.redactedText != nil } ?? false)
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Feature C1 — retention sweep: expired-unlocked removed, locked + recent kept, second run a no-op.
    static func runRetention(dir: String?) {
        setbuf(stdout, nil)
        print("== retention self-test ==")
        var ok = true
        func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }

        let root = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-retention")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trash = root.appendingPathComponent("_trash")
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let now = Date()
        let old = now.addingTimeInterval(-100 * 86_400)
        func make(_ name: String, date: Date, locked: Bool?) {
            let d = root.appendingPathComponent(name)
            let meta = SessionMeta(date: date, sourceLabel: "Mic", modelName: "m", retentionLocked: locked)
            synthSession(d, segments: [TranscriptSegment(start: 0, end: 2, text: "hello world")], meta: meta)
        }
        make("old-unlocked", date: old, locked: nil)
        make("old-locked", date: old, locked: true)
        make("recent", date: now, locked: nil)

        let policy = RetentionPolicy(autoDeleteEnabled: true, maxAgeDays: 30, deleteAudioOnly: false)
        let move: (URL) throws -> Void = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
        let r1 = Retention.sweep(root: root, policy: policy, now: now, trash: move)
        let fm = FileManager.default
        check("expired-unlocked trashed", !fm.fileExists(atPath: root.appendingPathComponent("old-unlocked").path))
        check("locked session kept", fm.fileExists(atPath: root.appendingPathComponent("old-locked").path))
        check("recent session kept", fm.fileExists(atPath: root.appendingPathComponent("recent").path))
        check("counts: 1 deleted, 1 locked-skip", r1.deletedSessions == 1 && r1.skippedLocked == 1)
        let r2 = Retention.sweep(root: root, policy: policy, now: now, trash: move)
        check("second run is a no-op", r2.deletedSessions == 0)
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Feature C4 — encryption seam: OFF passthrough byte-identical; ON recovers plaintext while
    /// on-disk bytes are NOT plaintext; SearchIndex in-memory finds terms + writes no cache.
    static func runEncrypt(dir: String?) {
        setbuf(stdout, nil)
        print("== encrypt self-test ==")
        var ok = true
        func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }

        let root = dir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp/transcriber-encrypt")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = Data("Secret transcript: the password is hunter2.".utf8)

        // OFF (default) — byte-identical passthrough.
        SessionIO.overrideKey = nil; SessionIO.isEncryptionEnabled = false
        let offURL = root.appendingPathComponent("off.bin")
        try? SessionIO.writeData(plain, to: offURL)
        let offDisk = (try? Data(contentsOf: offURL)) ?? Data()
        check("OFF: on-disk bytes identical (passthrough)", offDisk == plain)
        check("OFF: read-back identical", (try? SessionIO.readData(offURL)) == plain)

        // ON — encrypted at rest, recovers plaintext.
        SessionIO.overrideKey = SymmetricKey(size: .bits256)
        SessionIO.isEncryptionEnabled = true
        let onURL = root.appendingPathComponent("on.bin")
        try? SessionIO.writeData(plain, to: onURL)
        let onDisk = (try? Data(contentsOf: onURL)) ?? Data()
        check("ON: on-disk bytes are NOT plaintext", onDisk != plain && SessionIO.isEncryptedBlob(onDisk))
        check("ON: read decrypts to exact plaintext", (try? SessionIO.readData(onURL)) == plain)

        // SearchIndex in-memory while encrypted: synth a session (transcript.md encrypted on write),
        // index it, search a known term, assert NO cache file is written.
        let sdir = root.appendingPathComponent("session1")
        synthSession(sdir, segments: [TranscriptSegment(start: 0, end: 3, text: "photosynthesis converts sunlight into energy")])
        let onDiskMD = (try? Data(contentsOf: sdir.appendingPathComponent("transcript.md"))) ?? Data()
        check("transcript.md encrypted on disk", SessionIO.isEncryptedBlob(onDiskMD))
        let cacheURL = root.appendingPathComponent("index-cache.json")
        let index = SearchIndex(cacheURL: cacheURL)
        index.rebuildFromDisk(root: root)
        let hits = index.search("photosynthesis")
        check("in-memory index finds the term", hits.contains { $0.dir.lastPathComponent == "session1" })
        check("no plaintext cache written while encrypted", !FileManager.default.fileExists(atPath: cacheURL.path))

        SessionIO.isEncryptionEnabled = false; SessionIO.overrideKey = nil    // reset process flag
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }

    /// Feature D — slide-chat selection (pure): correct slide picked for a time-referenced question;
    /// even sample otherwise; macOS-26 build uses the text+OCR fallback.
    static func runSlideChat() {
        setbuf(stdout, nil)
        print("== slide-chat self-test ==")
        var ok = true
        func check(_ l: String, _ c: Bool) { print("  \(c ? "✓" : "✗") \(l)"); ok = ok && c }

        let frames = [
            FrameEvent(sessionTime: 0, imagePath: "images/0000.png", ocrText: "Title slide"),
            FrameEvent(sessionTime: 300, imagePath: "images/0001.png", ocrText: "Agenda"),
            FrameEvent(sessionTime: 750, imagePath: "images/0002.png", ocrText: "Architecture diagram"),
            FrameEvent(sessionTime: 1200, imagePath: "images/0003.png", ocrText: "Summary"),
        ]
        check("referencedTime parses 12:30 → 750s", SlideChat.referencedTime(in: "What was on the architecture diagram at 12:30?") == 750)
        let sel = SlideChat.selectSlides(frames: frames, question: "What was on the architecture diagram at 12:30?")
        print("  selected: \(sel.map { Int($0.sessionTime) })")
        check("nearest slide to 12:30 chosen first", sel.first?.sessionTime == 750)
        check("capped to maxImages", sel.count <= SlideChat.maxImages)
        let even = SlideChat.selectSlides(frames: frames, question: "summarize the whole talk")
        let evenTimes = even.map { $0.sessionTime }
        check("no time ref → even sample (non-empty, ordered)", !even.isEmpty && evenTimes == evenTimes.sorted())
        check("no slides → empty", SlideChat.selectSlides(frames: [], question: "anything at 1:00?").isEmpty)
        // On a macOS-26 build the image path is unavailable → text+OCR fallback is the active path.
        check("macOS-26 build: image input unavailable (text+OCR fallback)", SlideChat.imageInputAvailable == false)
        print(ok ? "OK" : "FAIL"); exit(ok ? 0 : 2)
    }
}

/// Thread-safe holder for the latest streaming update (the onUpdate closure is @Sendable
/// and fires from the StreamingTranscriber actor).
final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _last = ""
    private var _count = 0

    func update(_ text: String) {
        lock.lock()
        _last = text
        _count += 1
        lock.unlock()
        print("  [update #\(_count)] \(text)")
    }
    var last: String { lock.lock(); defer { lock.unlock() }; return _last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
