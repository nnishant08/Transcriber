import SwiftUI
import AppKit

/// The menu-bar popover (MenuBarExtra `.window` style), restyled to the redesign: a material
/// surface with a status row, full-width source control, a prominent Start/Stop row, the actions,
/// and a quiet on-device footer.
struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Status
            HStack(spacing: 9) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusTitle).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(model.model.shortName).font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)

            SourceSegmented(source: $model.source,
                            enabled: !model.isRecording && !model.status.isBusyPreparing,
                            fullWidth: true)
                .padding(.horizontal, 6).padding(.bottom, 8)

            startStopRow.padding(.horizontal, 6).padding(.bottom, 6)

            if model.isRecording {
                pauseRow.padding(.horizontal, 6).padding(.bottom, 6)
            } else {
                screenRow.padding(.horizontal, 6).padding(.bottom, 6)
            }

            divider

            PopoverRow(system: "macwindow", title: "Open transcript window") { WindowManager.shared.showTranscript() }
            PopoverRow(system: "books.vertical", title: "Open Library") { WindowManager.shared.showLibrary() }
            PopoverRow(system: "sparkles", title: "Ask your sessions") { WindowManager.shared.showAsk() }
            PopoverRow(system: "square.and.arrow.down", title: "Import audio / video…") { model.presentImportPanel() }
            PopoverRow(system: "folder", title: "Open transcripts folder") { model.openTranscriptsFolder() }
            if model.canExport {
                PopoverRow(system: "square.and.arrow.up", title: "Export last session (HTML)…") { model.exportHTML() }
                PopoverRow(system: "doc.richtext", title: "Export last session (PDF)…") { model.exportPDF() }
            }
            PopoverRow(system: "gearshape", title: "Settings…") { WindowManager.shared.showSettings() }

            if !model.recentSessions.isEmpty {
                divider
                Text("RECENT").font(Theme.ui(10, weight: .medium)).tracking(1.4)
                    .foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 2)
                ForEach(model.recentSessions.prefix(5)) { s in
                    PopoverRow(system: s.hasVideo ? "play.rectangle" : "waveform",
                               title: s.displayTitle) { WindowManager.shared.showViewer(dir: s.dir) }
                }
            }

            divider

            PopoverRow(system: "xmark", title: "Quit Said",
                       tint: Theme.recordText, iconTint: Theme.recordText) { NSApp.terminate(nil) }

            OnDeviceBadge().frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 4)
        }
        .padding(7)
        .frame(width: 290)
        .background(.ultraThinMaterial)
        .tint(Theme.accent)
        .onAppear { model.refreshRecentSessions() }
    }

    private var divider: some View {
        Divider().overlay(Theme.hairline).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var startStopRow: some View {
        Button { model.toggle() } label: {
            HStack(spacing: 9) {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.record).frame(width: 10, height: 10)
                    Text("Stop recording").font(Theme.ui(13, weight: .medium))
                } else {
                    Circle().fill(Theme.record).frame(width: 10, height: 10)
                    Text("Start recording").font(Theme.ui(13, weight: .medium))
                }
                KbdView("⌥⌘T")
            }
            .foregroundStyle(Theme.recordText)
            .frame(maxWidth: .infinity)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.recordSoft))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.recordBorder))
        }
        .buttonStyle(.plain)
        .disabled(model.status.isBusyPreparing)
    }

    /// Screen + audio in one go. Only offered when idle: mid-session the screen is either already
    /// being recorded or deliberately isn't, and neither can start halfway through a timeline.
    private var screenRow: some View {
        Button { model.toggleScreenRecording() } label: {
            HStack(spacing: 9) {
                Image(systemName: "record.circle").font(.system(size: 12))
                Text("Record screen + audio").font(Theme.ui(13, weight: .medium))
                KbdView("⌥⌘S")
            }
            .foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(model.status.isBusyPreparing)
        .help("Records \(model.screenTargetLabel) with \(model.screenAudioSource.label) audio, and transcribes it")
    }

    /// Pause/Resume — only meaningful during a session, so it only exists then.
    private var pauseRow: some View {
        Button { model.togglePause() } label: {
            HStack(spacing: 9) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill").font(.system(size: 11))
                Text(model.isPaused ? "Resume recording" : "Pause recording").font(Theme.ui(13, weight: .medium))
                KbdView("⌥⌘P")
            }
            .foregroundStyle(Theme.pauseText)
            .frame(maxWidth: .infinity)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.pauseSoft))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.pauseBorder))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch model.uiState {
        case .recording: return model.isPaused ? Theme.pause : Theme.record
        case .downloading: return Theme.accent
        default: return Theme.ok
        }
    }
    private var statusTitle: String {
        switch model.uiState {
        case .recording:
            if model.isPaused {
                return model.pauseReason == .silence ? "Auto-paused (silent)" : "Paused"
            }
            return "Recording…"
        case .downloading: return model.status.menuText
        case .summary: return "Summary"
        case .idle: return model.transcript.isEmpty ? "Ready" : "Ready · transcript saved"
        }
    }
}

private struct PopoverRow: View {
    let system: String
    let title: String
    var tint: Color = Theme.text
    var iconTint: Color = Theme.text2
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: system).font(.system(size: 14))
                    .foregroundStyle(hover ? Theme.accentText : iconTint).frame(width: 16)
                Text(title).font(Theme.ui(13)).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
