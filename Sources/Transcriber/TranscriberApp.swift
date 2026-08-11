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
        // The app is BOTH a menu-bar extra and a windowed app (v3 screen 03A: "Menu bar and window,
        // not either/or"). `.window` style gives us a popover we can put a segmented picker and
        // buttons into (the default `.menu` style can't render a segmented Picker).
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        // The main menu (v3 screen 01D). Windows are built manually by WindowManager, so the
        // commands hang off this scene.
        .commands { TranscriberCommands(model: model) }
    }
}

/// Reactive menu-bar icon: a plain waveform when idle, a filled waveform while recording, and a
/// pause badge while a session is held — so a paused (or auto-paused) session is visible from the
/// menu bar without opening the app.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: symbol).accessibilityLabel(label)
    }
    private var symbol: String {
        guard model.isRecording else { return "waveform" }
        return model.isPaused ? "pause.circle.fill" : "waveform.circle.fill"
    }
    private var label: String {
        guard model.isRecording else { return "Said — idle" }
        return model.isPaused ? "Said — paused" : "Said — recording"
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

    /// Files dropped on the Dock icon or "Open With… Said" → import them (B1).
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

    /// The ONE main window (v3): sidebar + content + inspector, with the Library, the capture
    /// surface, and the Session Viewer as routes inside it.
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var askWindow: NSWindow?

    /// Show the main window at a route (creating it on first use).
    func showMain(_ route: ShellRoute) {
        guard let model else { return }
        ShellModel.shared.go(route)
        if mainWindow == nil {
            mainWindow = makeWindow(
                title: "Said",
                size: NSSize(width: 1180, height: 720),
                content: AnyView(MainShell().environmentObject(model)),
                customTitlebar: true,
                autosave: "TranscriberMainWindow"
            )
        }
        present(mainWindow)
    }

    /// The capture surface (invite / live transcript / summary).
    func showTranscript() {
        debugLog("showTranscript model=\(model != nil) existing=\(mainWindow != nil)")
        showMain(.capture)
    }

    /// Browse / search every saved session.
    func showLibrary() { showMain(.library) }

    /// Open one session for reading (transcript + playback + summary + chat + export).
    func showViewer(dir: URL) { showMain(.session(dir)) }

    /// First-run permission onboarding.
    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: "Welcome to Said", size: NSSize(width: 460, height: 420),
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
                title: "Said Settings",
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

    private func makeWindow(title: String, size: NSSize, content: AnyView,
                            customTitlebar: Bool = false, autosave: String? = nil) -> NSWindow {
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
            // v3 screen 01A: the sidebar's material runs the full height and the traffic lights sit
            // on it, so the window draws its own chrome edge to edge.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .dynamic(light: NSColor(hex: 0xF6F6F4), dark: NSColor(hex: 0x1E1F21))
        }
        // Place it deliberately. `center()` alone lands the window half off-screen here: the hosting
        // controller reports a near-zero fitting size at this point and AppKit grows the window to
        // its real width afterwards, anchored at the left edge it was just given.
        window.setContentSize(size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let origin = NSPoint(x: visible.midX - frame.width / 2,
                                 y: visible.midY - frame.height / 2)
            window.setFrame(NSRect(origin: origin, size: frame.size), display: false)
        } else {
            window.center()
        }
        // Remember where the user put it (applied after the explicit placement above, so a first
        // run is centered and every later run reopens where they left it).
        if let autosave {
            window.setFrameAutosaveName(autosave)
            window.setFrameUsingName(autosave)
        }
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// When the user closes a window, drop our reference so the next "Open…" builds a fresh one.
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        if closed === mainWindow { mainWindow = nil }
        if closed === settingsWindow { settingsWindow = nil }
        if closed === onboardingWindow { onboardingWindow = nil }
        if closed === askWindow { askWindow = nil }
    }
}
