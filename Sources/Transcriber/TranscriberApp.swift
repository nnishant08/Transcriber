import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

/// Unambiguous launch probe (NSLog→unified-log visibility is unreliable for this app).
/// Appends to /tmp/transcriber_launch.log. Used only to verify the launch path during bring-up.
func debugLog(_ s: String) {
    let line = "\(Date()): \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/transcriber_launch.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    NSLog("%@", s)
}

struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // Menu-bar-only app. `.window` style gives us a popover we can put a segmented
        // picker and buttons into (the default `.menu` style can't render a segmented Picker).
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reactive menu-bar icon: a plain waveform when idle, a filled waveform while recording.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform")
            .accessibilityLabel(model.isRecording ? "Transcriber — recording" : "Transcriber — idle")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        debugLog("applicationDidFinishLaunching perms: screenRecording=\(CGPreflightScreenCaptureAccess()) micStatus=\(mic)")
        // Regular app: Dock icon + app-switcher entry (alongside the menu-bar icon).
        NSApp.setActivationPolicy(.regular)
        // Reliable launch hook (independent of @StateObject creation timing): make sure the
        // shared model exists and run first-launch onboarding here.
        AppModel.shared.onLaunch()
    }

    /// Clicking the Dock icon when no window is open should reopen the transcript window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showTranscript() }
        return true
    }

    /// Files dropped on the Dock icon or "Open With… Transcriber" → import them (B1).
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.importFiles(urls)
    }
}

/// Lazily creates and shows the auxiliary windows (Transcript, Settings) as plain NSWindows
/// hosting SwiftUI views. Done manually rather than via SwiftUI `Window` scenes so the
/// menu-bar-only app opens with NO windows visible at launch.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    weak var model: AppModel?

    private var transcriptWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var libraryWindow: NSWindow?
    private var viewerWindows: [String: NSWindow] = [:]   // one per session dir
    private var onboardingWindow: NSWindow?
    private var askWindow: NSWindow?

    func showTranscript() {
        debugLog("showTranscript model=\(model != nil) existing=\(transcriptWindow != nil)")
        guard let model else { return }
        if transcriptWindow == nil {
            transcriptWindow = makeWindow(
                title: "Transcript",
                size: NSSize(width: 900, height: 640),
                content: AnyView(TranscriptWindow().environmentObject(model)),
                customTitlebar: true
            )
        }
        present(transcriptWindow)
    }

    /// The Library: lists / searches every saved session. Self-contained (its own LibraryModel),
    /// so it doesn't depend on the AppModel — but built the same manual-NSWindow way as the others.
    func showLibrary() {
        if libraryWindow == nil {
            libraryWindow = makeWindow(
                title: "Library",
                size: NSSize(width: 820, height: 600),
                content: AnyView(LibraryWindow())
            )
        }
        present(libraryWindow)
    }

    /// The in-app Session Viewer (transcript + playback + summary + chat + export) for one session.
    /// Library "Open" routes here. Re-opening the same session focuses the existing window.
    func showViewer(dir: URL) {
        let key = dir.path
        if let existing = viewerWindows[key] { present(existing); return }
        let w = makeWindow(title: "Session", size: NSSize(width: 1000, height: 660),
                           content: AnyView(SessionViewer(dir: dir)))
        viewerWindows[key] = w
        present(w)
    }

    /// First-run permission onboarding.
    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: "Welcome to Transcriber", size: NSSize(width: 460, height: 420),
                                          content: AnyView(OnboardingWindow()))
        }
        present(onboardingWindow)
    }
    func closeOnboarding() { onboardingWindow?.close(); onboardingWindow = nil }

    /// Cross-session Ask window.
    func showAsk() {
        if askWindow == nil {
            askWindow = makeWindow(title: "Ask your sessions", size: NSSize(width: 560, height: 480),
                                   content: AnyView(AskWindow()))
        }
        present(askWindow)
    }

    func showSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Transcriber Settings",
                size: NSSize(width: 440, height: 300),
                content: AnyView(SettingsView().environmentObject(model))
            )
        }
        present(settingsWindow)
    }

    func presentPermissionAlert(title: String, message: String, settingsAnchor: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
            NSWorkspace.shared.open(url)
        }
    }

    private func makeWindow(title: String, size: NSSize, content: AnyView, customTitlebar: Bool = false) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false   // ARC-safe: don't let AppKit release it on close
        window.delegate = self                // …and clear our cached reference when it closes
        if customTitlebar {
            // Integrated dark titlebar: SwiftUI content fills to the top edge and draws its own
            // toolbar; the traffic lights overlay its leading inset. (Presentation only.)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .dynamic(light: NSColor(hex: 0xF4F4F6), dark: NSColor(hex: 0x1D1E20))
        }
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// When the user closes a window, drop our reference so the next "Open…" builds a fresh one.
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        if closed === transcriptWindow { transcriptWindow = nil }
        if closed === settingsWindow { settingsWindow = nil }
        if closed === libraryWindow { libraryWindow = nil }
        if closed === onboardingWindow { onboardingWindow = nil }
        if closed === askWindow { askWindow = nil }
        if let key = viewerWindows.first(where: { $0.value === closed })?.key { viewerWindows[key] = nil }
    }
}
