import Foundation
import WebKit

enum ExportError: LocalizedError {
    case noSession
    var errorDescription: String? {
        "No session.json found in that folder — export needs a session produced by this app."
    }
}

/// Produces a portable single-file document (HTML or PDF) from a finished session folder. Fully
/// local; nothing is sent anywhere. The folder + `transcript.md` stays the lightweight canonical
/// form — these exports are the shareable form.
public enum Exporter {

    /// Self-contained HTML string for a session folder.
    public static func htmlString(for sessionDir: URL) -> String? {
        guard let doc = DocumentBuilder.readSession(sessionDir) else { return nil }
        // Frame images are read back through SessionIO, so an encrypted session exports correctly
        // instead of embedding ciphertext as a broken data URI.
        return DocumentBuilder.html(meta: doc.meta, segments: doc.segments, frames: doc.frames) { rel in
            try? SessionIO.readData(sessionDir.appendingPathComponent(rel))
        }
    }

    @discardableResult
    public static func exportHTML(sessionDir: URL, to output: URL) throws -> URL {
        guard let html = htmlString(for: sessionDir) else { throw ExportError.noSession }
        try Data(html.utf8).write(to: output)
        return output
    }

    // MARK: - Plain text / RTF (native, no dependencies; .rtf opens in Word/Pages/TextEdit)

    /// A readable plain-text rendering: a small header + the timestamped transcript lines.
    public static func plainText(for sessionDir: URL) -> String {
        let meta = DocumentBuilder.readSession(sessionDir)?.meta
        var out = ""
        if let meta {
            out += (meta.title?.isEmpty == false ? meta.title! : "Transcript") + "\n"
            out += humanStamp.string(from: meta.date) + " · " + meta.sourceLabel + "\n"
            if !meta.tags.isEmpty { out += "Tags: " + meta.tags.joined(separator: ", ") + "\n" }
            out += "\n"
        }
        out += SessionStore.timestampedTranscript(dir: sessionDir, maxChars: 5_000_000)
        return out
    }

    @discardableResult
    public static func exportTXT(sessionDir: URL, to output: URL) throws -> URL {
        try Data(plainText(for: sessionDir).utf8).write(to: output)
        return output
    }

    /// RTF built from an NSAttributedString (title bold, monospaced timestamps, serif body).
    static func rtfData(for sessionDir: URL) -> Data? {
        let meta = DocumentBuilder.readSession(sessionDir)?.meta
        let attr = NSMutableAttributedString()
        if let meta {
            let title = (meta.title?.isEmpty == false ? meta.title! : "Transcript")
            attr.append(NSAttributedString(string: title + "\n", attributes: [
                .font: PlatformFont.boldSystemFont(ofSize: 18)]))
            attr.append(NSAttributedString(string: humanStamp.string(from: meta.date) + " · " + meta.sourceLabel + "\n\n", attributes: [
                .font: PlatformFont.systemFont(ofSize: 11), .foregroundColor: PlatformColor.secondaryLabelCompat]))
        }
        let segs = SessionStore.timedSegments(dir: sessionDir)
        if segs.isEmpty {
            attr.append(NSAttributedString(string: SessionStore.transcriptPlainText(dir: sessionDir),
                                           attributes: [.font: PlatformFont.systemFont(ofSize: 13)]))
        } else {
            for s in segs {
                attr.append(NSAttributedString(string: DocumentBuilder.timestamp(s.start) + "  ", attributes: [
                    .font: PlatformFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: PlatformColor.secondaryLabelCompat]))
                attr.append(NSAttributedString(string: s.text + "\n", attributes: [
                    .font: PlatformFont.systemFont(ofSize: 13)]))
            }
        }
        return attr.saidRTFData()
    }

    @discardableResult
    public static func exportRTF(sessionDir: URL, to output: URL) throws -> URL {
        guard let data = rtfData(for: sessionDir) else { throw ExportError.noSession }
        try data.write(to: output)
        return output
    }

    private static let humanStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    @MainActor
    @discardableResult
    public static func exportPDF(sessionDir: URL, to output: URL) async throws -> URL {
        guard let html = htmlString(for: sessionDir) else { throw ExportError.noSession }
        let data = try await renderPDF(html: html)
        try data.write(to: output)
        return output
    }

    // MARK: - PDF rendering via WKWebView

    @MainActor
    private static func renderPDF(html: String) async throws -> Data {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 1000))
        let loader = LoadDelegate()
        webView.navigationDelegate = loader
        webView.loadHTMLString(html, baseURL: nil)
        try await loader.waitUntilLoaded()
        // Let layout + (already-inlined) images settle before snapshotting.
        try? await Task.sleep(nanoseconds: 350_000_000)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                cont.resume(with: result)
            }
        }
    }
}

@MainActor
private final class LoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func waitUntilLoaded() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
