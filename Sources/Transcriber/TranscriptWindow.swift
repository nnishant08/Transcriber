import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main window. One UI state (idle / downloading / recording / summary) drives a state-swapped
/// titlebar, canvas, and status bar. Presentation only — all behavior comes from AppModel.
struct TranscriptWindow: View {
    @EnvironmentObject var model: AppModel

    private let titlebarLeadingInset: CGFloat = 78   // clears the traffic lights (custom titlebar)

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .frame(height: 52)
                .background(Theme.titlebar)
            Divider().overlay(Theme.hairline)

            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { meetingBanner }

            Divider().overlay(Theme.hairline)
            statusBar
                .frame(height: 30)
                .background(Theme.statusBG)
        }
        .background(Theme.windowBG)
        .frame(minWidth: 680, minHeight: 460)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
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

    // MARK: - Titlebar (per state)

    @ViewBuilder private var titlebar: some View {
        HStack(spacing: 10) {
            switch model.uiState {
            case .idle:        idleToolbar
            case .downloading: downloadingToolbar
            case .recording:   recordingToolbar
            case .summary:     summaryToolbar
            }
        }
        .padding(.leading, titlebarLeadingInset)
        .padding(.trailing, 14)
    }

    @ViewBuilder private var idleToolbar: some View {
        if model.transcript.isEmpty {
            // Fresh / empty — the record ring lives in the canvas.
            Text("Transcriber").font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text2)
                .lineLimit(1).fixedSize()
            Spacer()
            SourceSegmented(source: $model.source, enabled: true)
            ToolbarIcon(system: "books.vertical") { WindowManager.shared.showLibrary() }.help("Library — browse & search all sessions")
            ToolbarIcon(system: "folder") { model.openTranscriptsFolder() }.help("Open ~/Desktop/Transcripts")
            ToolbarIcon(system: "gearshape") { WindowManager.shared.showSettings() }.help("Settings")
        } else {
            // Review — a finished transcript is on screen; give a way back to recording / a clean slate.
            RecordPill().environmentObject(model)
            SourceSegmented(source: $model.source, enabled: true)
            Spacer()
            SummarizeButton().environmentObject(model)
            ToolbarIcon(system: "trash") { model.clearTranscript() }.help("Clear — start a new transcript")
            ToolbarIcon(system: "books.vertical") { WindowManager.shared.showLibrary() }.help("Library — browse & search all sessions")
            ToolbarIcon(system: "folder") { model.openTranscriptsFolder() }.help("Open ~/Desktop/Transcripts")
            ToolbarIcon(system: "gearshape") { WindowManager.shared.showSettings() }.help("Settings")
        }
    }

    private var downloadingToolbar: some View {
        Group {
            Text(model.status.menuText).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text2)
                .lineLimit(1).fixedSize()
            Spacer()
            ToolbarIcon(system: "gearshape") { WindowManager.shared.showSettings() }
        }
    }

    private var recordingToolbar: some View {
        Group {
            StopButton().environmentObject(model)
            RecordingTimer(hud: model.hud)
            LiveMeter(hud: model.hud)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: model.source.symbol).font(.system(size: 12))
                Text(model.source.label)
                    .font(Theme.ui(12.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.text2)
            SummarizeButton().environmentObject(model)
            ToolbarIcon(system: "folder") { model.openTranscriptsFolder() }
            ToolbarIcon(system: "gearshape") { WindowManager.shared.showSettings() }
        }
    }

    private var summaryToolbar: some View {
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

    // MARK: - Canvas (per state)

    @ViewBuilder private var canvas: some View {
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

    // MARK: - Calendar-meeting banner (Feature C)

    /// Prompt mode: Start/Ignore for a detected meeting. Auto mode: a clear, dismissible
    /// "started (auto)" indicator so an auto-recording is never silent or surprising.
    @ViewBuilder private var meetingBanner: some View {
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

    // MARK: - Status bar (per state)

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 9) {
            switch model.uiState {
            case .idle:
                if model.transcript.isEmpty {
                    StatusText(model.model.shortName); Dot(); StatusText(model.source.label)
                } else {
                    StatusText("\(model.wordCount) words"); Dot(); StatusText(model.model.shortName)
                }
                Spacer()
                StatusText(model.lastSavedURL?.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Saves to ~/Desktop/Transcripts")
            case .downloading:
                StatusText("Model not loaded")
                Spacer()
                StatusText("Recording stays disabled until ready")
            case .recording:
                StatusText("\(model.wordCount) words"); Dot(); StatusText(model.model.shortName)
                if model.visualCaptureEnabled { Dot(); StatusText("Visual capture on") }
                if let lang = model.sessionLanguageLabel { Dot(); StatusText(lang) }
                Spacer()
                ListeningIndicator()
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

// MARK: - Status-bar atoms

private struct StatusText: View {
    let s: String
    init(_ s: String) { self.s = s }
    var body: some View { Text(s).lineLimit(1) }
}
private struct Dot: View {
    var body: some View { Circle().fill(Theme.text3).frame(width: 3, height: 3) }
}
private struct ListeningIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduce)) { ctx in
            let on = reduce ? true : (sin(ctx.date.timeIntervalSinceReferenceDate * 3.0) > -0.3)
            HStack(spacing: 6) {
                Circle().fill(Theme.record).frame(width: 7, height: 7).opacity(on ? 1 : 0.35)
                Text("Listening")
            }
            .foregroundStyle(Theme.recordText)
        }
    }
}

/// Thread-safe accumulator for async `NSItemProvider.loadObject` completions (drag-drop import).
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
