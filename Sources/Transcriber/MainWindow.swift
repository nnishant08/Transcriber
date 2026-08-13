import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The one window
//
// v3, screen 01: "Sidebar runs the full height. Traffic lights sit on the sidebar's translucent
// material, toolbar starts to its right. That single change is most of what makes a window read as
// Mac rather than Electron."
//
// So the app now has ONE main window with three columns — sidebar | content | inspector — and the
// Library, the capture surface, and the Session Viewer are ROUTES inside it rather than separate
// NSWindows. Settings, the floating capture panel, and Ask stay their own windows (v3 keeps them
// separate too: a settings window should look like a settings window).
//
// Nothing here touches capture, the streaming algorithm, finalPass, or the session format — this
// file is presentation and window plumbing only.

enum ShellRoute: Equatable {
    /// Browse + search every saved session (v3 screen 01).
    case library
    /// The capture surface: invite / downloading / live transcript / summary (v3 screen 05's canvas).
    case capture
    /// One session open for reading (v3 screen 02).
    case session(URL)

    var isSession: Bool { if case .session = self { return true }; return false }
}

@MainActor
final class ShellModel: ObservableObject {
    static let shared = ShellModel()

    @Published var route: ShellRoute = .library
    /// v3: "Inspector hides with ⌥⌘I and stays hidden per-window, the way Finder's preview pane does."
    @Published var inspectorVisible: Bool {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "shellInspectorVisible") }
    }
    /// Selected session directory paths (multi-select; v3 screen 01C).
    @Published var selection: Set<String> = []

    let library = LibraryModel()
    /// The open session, owned here so the session sidebar and the shell toolbar can both drive it.
    @Published private(set) var viewer: SessionViewerModel?

    private init() {
        let d = UserDefaults.standard
        inspectorVisible = (d.object(forKey: "shellInspectorVisible") as? Bool) ?? true
    }

    func go(_ r: ShellRoute) {
        if case .session(let dir) = r {
            if viewer?.dir.path != dir.path { viewer = SessionViewerModel(dir: dir) }
            selection = [dir.path]
        }
        route = r
    }

    /// Leave a session and go back to the list it came from.
    func closeSession() {
        viewer = nil
        route = .library
    }

    /// The single selected session (nil when zero or many are selected).
    var selectedSession: SessionInfo? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return library.sessions.first { $0.dir.path == path }
    }
}

// MARK: - Shell

struct MainShell: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var shell = ShellModel.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: shell.route.isSession ? Theme.sessionSidebarWidth : Theme.sidebarWidth)
                .sidebarMaterial()
            Divider().overlay(Theme.hairline)
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.windowBG)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .environmentObject(model)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        .onAppear { shell.library.reload() }
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        VStack(spacing: 0) {
            // The traffic lights live here, on the sidebar's material (v3 screen 01A).
            Color.clear.frame(height: Theme.toolbarHeight)
            switch shell.route {
            case .session:
                if let viewer = shell.viewer {
                    SessionSidebar(shell: shell, viewer: viewer)
                } else {
                    Spacer()
                }
            case .library, .capture:
                LibrarySidebar(shell: shell).environmentObject(model)
            }
        }
    }

    // MARK: Detail (everything right of the sidebar)

    @ViewBuilder private var detail: some View {
        switch shell.route {
        case .session:
            // The Session Viewer draws its own header, panel and player bar, so it fills the whole
            // detail area. (Phase 5 breaks it apart into the shell's toolbar + inspector.)
            if let viewer = shell.viewer {
                SessionViewer(lib: viewer).id(viewer.dir.path)
            } else {
                Color.clear.onAppear { shell.closeSession() }
            }
        case .library:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LibraryToolbar(shell: shell).frame(height: Theme.toolbarHeight).headerMaterial()
                    Divider().overlay(Theme.hairline)
                    LibraryContent(shell: shell)
                }
                if shell.inspectorVisible {
                    Divider().overlay(Theme.hairline)
                    LibraryInspector(shell: shell)
                        .frame(width: Theme.inspectorWidth)
                        .background(Theme.inspectorBG)
                }
            }
        case .capture:
            VStack(spacing: 0) {
                CaptureToolbar(shell: shell).frame(height: Theme.toolbarHeight).headerMaterial()
                Divider().overlay(Theme.hairline)
                CaptureCanvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { MeetingBanner() }
                    .overlay(alignment: .bottomTrailing) {
                        if model.isRecordingScreen {
                            ScreenPreviewCard().environmentObject(model)
                                .padding(16)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: model.isRecordingScreen)
                Divider().overlay(Theme.hairline)
                CaptureStatusBar().frame(height: 30).background(Theme.statusBG)
            }
        }
    }

    /// Drag-drop audio/video files onto the window → import (B1).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !usable.isEmpty else { return false }
        let collector = DropCollector()
        let group = DispatchGroup()
        for p in usable {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collector.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.all()
            if !urls.isEmpty { model.importFiles(urls) }
        }
        return true
    }
}

// MARK: - Capture surface (routed into the shell's content column)

/// The four capture states, unchanged in behavior — only re-homed from the old standalone
/// Transcript window into the shell.
struct CaptureCanvas: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.uiState {
        case .summary:
            SummaryCanvas().environmentObject(model)
        case .downloading:
            DownloadingCanvas(message: model.status.menuText, fraction: model.downloadFraction)
        case .recording:
            TranscriptCanvas(live: true).environmentObject(model)
        case .idle:
            if model.transcript.isEmpty {
                InviteCanvas().environmentObject(model)
            } else {
                TranscriptCanvas(live: false).environmentObject(model)
            }
        }
    }
}

private struct CaptureToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var shell: ShellModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.uiState {
            case .idle:        idle
            case .downloading: downloading
            case .recording:   recording
            case .summary:     summary
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
    }

    @ViewBuilder private var idle: some View {
        if model.transcript.isEmpty {
            Text("Record").font(Theme.ui(13.5, weight: .semibold)).lineLimit(1).fixedSize()
            Spacer()
            ScreenRecordButton(compact: true).environmentObject(model)
            SourceSegmented(source: $model.source, enabled: true)
            ToolbarIcon(system: "folder") { model.openTranscriptsFolder() }.help("Open ~/Desktop/Transcripts")
        } else {
            RecordPill().environmentObject(model)
            ScreenRecordButton(compact: true).environmentObject(model)
            SourceSegmented(source: $model.source, enabled: true)
            Spacer()
            SummarizeButton().environmentObject(model)
            ToolbarIcon(system: "trash") { model.clearTranscript() }.help("Clear — start a new transcript")
            ToolbarIcon(system: "folder") { model.openTranscriptsFolder() }.help("Open ~/Desktop/Transcripts")
        }
    }

    private var downloading: some View {
        Group {
            Text(model.status.menuText).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text2)
                .lineLimit(1).fixedSize()
            Spacer()
        }
    }

    private var recording: some View {
        Group {
            StopButton().environmentObject(model)
            PauseButton().environmentObject(model)
            RecordingTimer(hud: model.hud)
            LiveMeter(hud: model.hud, paused: model.isPaused)
            Spacer()
            if model.isRecordingScreen {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle").font(.system(size: 11))
                    Text("Screen").font(Theme.ui(12, weight: .medium)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(Theme.recordText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.recordSoft))
                .help("Recording \(model.screenTargetLabel) at \(model.screenQuality.shortLabel)")
            }
            HStack(spacing: 6) {
                Image(systemName: model.source.symbol).font(.system(size: 12))
                Text(model.source.label).font(Theme.ui(12.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.text2)
            SummarizeButton().environmentObject(model)
        }
    }

    private var summary: some View {
        Group {
            Button { model.closeSummary() } label: {
                HStack(spacing: 5) { Image(systemName: "chevron.left"); Text("Transcript").lineLimit(1).fixedSize() }
                    .font(Theme.ui(13, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text2)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Theme.aiTint)
                Text("Summary").font(Theme.ui(13, weight: .medium)).lineLimit(1).fixedSize()
            }
            Spacer()
            ToolbarIcon(system: "xmark") { model.closeSummary() }.help("Close summary")
        }
    }
}

private struct CaptureStatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            switch model.uiState {
            case .idle:
                if model.transcript.isEmpty {
                    StatusText(model.model.shortName); StatusDot(); StatusText(model.source.label)
                } else {
                    StatusText("\(model.wordCount) words"); StatusDot(); StatusText(model.model.shortName)
                }
                Spacer()
                StatusText(model.lastSavedURL?.deletingLastPathComponent().path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Saves to ~/Desktop/Transcripts")
            case .downloading:
                StatusText("Model not loaded")
                Spacer()
                StatusText("Recording stays disabled until ready")
            case .recording:
                StatusText("\(model.wordCount) words"); StatusDot(); StatusText(model.model.shortName)
                if model.isRecordingScreen {
                    StatusDot(); StatusText("Screen · \(model.screenTargetLabel) · \(model.screenQuality.shortLabel)")
                }
                if let lang = model.sessionLanguageLabel { StatusDot(); StatusText(lang) }
                if let notice = model.captureNotice { StatusDot(); StatusText(notice) }
                Spacer()
                if model.isPaused {
                    PausedIndicator(reason: model.pauseReason)
                } else if model.hud.silentSeconds >= 8 {
                    NoAudioIndicator(source: model.source, seconds: model.hud.silentSeconds)
                } else if model.autoPauseEnabled, model.hud.quietSeconds > 0,
                          Int(model.autoPauseSeconds) - model.hud.quietSeconds <= 8,
                          model.hud.quietSeconds < Int(model.autoPauseSeconds) {
                    AutoPauseCountdown(seconds: max(1, Int(model.autoPauseSeconds) - model.hud.quietSeconds))
                } else {
                    ListeningIndicator()
                }
            case .summary:
                StatusText("Summary of \(model.wordCount) words")
                Spacer()
                StatusText(model.lastSessionDir?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                           ?? model.lastSavedURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            }
        }
        .font(Theme.ui(11.5))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 16)
    }
}

/// Calendar-meeting banner (Feature C). Prompt mode: Start/Ignore. Auto mode: a clear, dismissible
/// "started (auto)" indicator so an auto-recording is never silent or surprising.
private struct MeetingBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let prompt = model.meetingPrompt {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 14)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting starting: \(prompt.title)")
                        .font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
                    Text("Record it bot-free? (local system audio — nothing joins the call)")
                        .font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 10)
                Button("Start") { model.startMeetingRecording(prompt) }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Ignore") { model.dismissMeetingPrompt() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface).shadow(radius: 6, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline2))
            .padding(.horizontal, 16).padding(.top, 10)
        } else if let title = model.autoStartedMeeting {
            HStack(spacing: 8) {
                Circle().fill(Theme.record).frame(width: 7, height: 7)
                Text("Recording started for “\(title)” (auto)")
                    .font(Theme.ui(12, weight: .medium)).lineLimit(1)
                Button { model.dismissAutoStartBanner() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                }.buttonStyle(.plain).help("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.surface).shadow(radius: 6, y: 2))
            .overlay(Capsule().strokeBorder(Theme.hairline2))
            .padding(.top, 10)
        }
    }
}

/// Thread-safe accumulator for async `NSItemProvider.loadObject` completions (drag-drop import).
final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
