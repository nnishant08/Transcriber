import SwiftUI
import AppKit

// MARK: - Toolbar atoms

struct ToolbarIcon: View {
    let system: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.06) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct KbdView: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.ui(11))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline2))
    }
}

/// Custom segmented source control (icon + label pills) used in the toolbar and the popover.
struct SourceSegmented: View {
    @Binding var source: AudioSource
    var enabled: Bool = true
    var fullWidth: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AudioSource.allCases) { src in
                seg(src, src.symbol, src.shortLabel)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .opacity(enabled ? 1 : 0.5)
    }

    private func seg(_ value: AudioSource, _ icon: String, _ label: String) -> some View {
        let selected = source == value
        return Button { if enabled { source = value } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
            }
            .fixedSize(horizontal: !fullWidth, vertical: true)
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Red "Record" pill for the review toolbar (start a fresh recording).
struct RecordPill: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggle() } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.record).frame(width: 9, height: 9)
                Text("Record").font(Theme.ui(12.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.recordText)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.recordSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.recordBorder))
        }
        .buttonStyle(.plain)
        .disabled(model.status.isBusyPreparing)
        .help("Start a new recording (⌥⌘T)")
    }
}

struct SummarizeButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.summarizeTranscript() } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.aiTint)
                Text("Summarize").font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.accentText).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accentBorder))
        }
        .buttonStyle(.plain)
        .disabled(model.transcript.isEmpty || model.isSummarizing)
        .help("Create an on-device AI summary (Apple Intelligence)")
    }
}

struct StopButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.record).frame(width: 9, height: 9)
                Text("Stop").font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.recordText).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.recordSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.recordBorder))
        }
        .buttonStyle(.plain)
        .help("Stop recording (⌥⌘T)")
    }
}

/// Pause / Resume for a live session. The session stays open either way — only the capture is
/// gated — so this never risks losing a recording the way Stop does.
struct PauseButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.togglePause() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill").font(.system(size: 11))
                Text(model.isPaused ? "Resume" : "Pause")
                    .font(Theme.ui(12.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.pauseText)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pauseSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.pauseBorder))
        }
        .buttonStyle(.plain)
        .help(model.isPaused ? "Resume recording (⌥⌘P)" : "Pause recording — the session stays open (⌥⌘P)")
    }
}

struct RecordingTimer: View {
    @ObservedObject var hud: RecordingHUD
    var body: some View {
        Text(String(format: "%02d:%02d", hud.elapsed / 60, hud.elapsed % 60))
            .font(Theme.mono(13)).monospacedDigit()
            .foregroundStyle(Theme.text)
    }
}

/// 8-bar live meter driven by RMS (hud.level) with a gentle time-based wiggle; falls back to a
/// level-only static read when reduced-motion is on.
struct LiveMeter: View {
    @ObservedObject var hud: RecordingHUD
    /// While paused the bars show the LIVE input (which is being dropped, not recorded), so they
    /// take the paused tint — a moving amber meter reads as "hearing this, not keeping it".
    var paused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let speeds: [Double] = [1.1, 0.8, 1.4, 0.95, 1.2, 0.85, 1.35, 1.0]
    private let phases: [Double] = [0, 0.6, 1.2, 0.3, 1.8, 0.9, 2.2, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06, paused: reduce)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<8, id: \.self) { i in
                    Capsule().fill(paused ? Theme.pause : Theme.record).opacity(0.85)
                        .frame(width: 2.5, height: barHeight(i, t: t))
                }
            }
            .frame(height: 18)
            .accessibilityHidden(true)
        }
    }

    private func barHeight(_ i: Int, t: Double) -> CGFloat {
        let level = CGFloat(hud.level)
        if reduce { return 4 + level * 14 }
        let wave = (sin(t * speeds[i] + phases[i]) + 1) / 2
        let amp = 0.18 + level * 0.82
        return 4 + amp * wave * 14
    }
}

// MARK: - Status-bar atoms (shared by the shell's status strip)

struct StatusText: View {
    let s: String
    init(_ s: String) { self.s = s }
    var body: some View { Text(s).lineLimit(1) }
}

struct StatusDot: View {
    var body: some View { Circle().fill(Theme.text3).frame(width: 3, height: 3) }
}

struct ListeningIndicator: View {
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

/// Paused: the session is open, nothing is being recorded. States WHY, because an automatic pause
/// the user didn't ask for must explain itself — and say that it will resume on its own.
struct PausedIndicator: View {
    let reason: PauseReason?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").font(.system(size: 10))
            Text(reason == .silence ? "Auto-paused — silent · resumes when audio returns" : "Paused")
                .lineLimit(1)
        }
        .foregroundStyle(Theme.pauseText)
        .help(reason == .silence
              ? "No audio was detected, so recording paused itself. It resumes automatically as soon as sound comes back — or press ⌥⌘P."
              : "Recording is paused. Press ⌥⌘P (or Resume) to continue this session.")
    }
}

/// The last few seconds before an automatic pause — so it is never a surprise.
struct AutoPauseCountdown: View {
    let seconds: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle").font(.system(size: 10))
            Text("silent — auto-pausing in \(seconds)s").lineLimit(1)
        }
        .foregroundStyle(Theme.pauseText)
        .help("No audio is coming in. Recording will pause itself, then resume automatically when sound returns.")
    }
}

/// Shown in place of "Listening" once the capture has carried nothing but digital silence for a
/// while. Deliberately states the elapsed time — "no audio for 40s" is actionable in the moment,
/// whereas an empty transcript half an hour later is not.
struct NoAudioIndicator: View {
    let source: AudioSource
    let seconds: Int

    private var hint: String {
        switch source {
        case .microphone:    return "no mic audio for \(seconds)s"
        case .systemAudio:   return "no system audio for \(seconds)s"
        case .micPlusSystem: return "no audio for \(seconds)s"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            Text(hint).lineLimit(1)
        }
        .foregroundStyle(Theme.record)
        .help("The capture is running but receiving only silence. Check that the audio is actually "
              + "playing, and that the right source (Mic / System Audio) is selected.")
    }
}

// MARK: - Idle / downloading canvases

struct InviteCanvas: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false
    var body: some View {
        VStack(spacing: 18) {
            Button { model.toggle() } label: {
                ZStack {
                    Circle().strokeBorder(hover ? Theme.text2 : Theme.text3, lineWidth: 1.5)
                        .frame(width: 92, height: 92)
                    Circle().fill(Theme.record).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Theme.recordSoft, lineWidth: hover ? 6 : 0))
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(hover ? 1.02 : 1)
            .onHover { hover = $0 }
            .help("Start transcribing (⌥⌘T)")

            VStack(spacing: 8) {
                Text("Start transcribing").font(Theme.ui(18, weight: .medium)).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    Text("Capturing \(model.source.label.lowercased())")
                    sep
                    Text(model.model.shortName)
                    sep
                    HStack(spacing: 4) { Text("press"); KbdView("⌥⌘T"); Text("anywhere") }
                }
                .font(Theme.ui(13)).foregroundStyle(Theme.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    private var sep: some View { Circle().fill(Theme.text3).frame(width: 3, height: 3) }
}

struct DownloadingCanvas: View {
    let message: String
    let fraction: Double?
    var body: some View {
        VStack(spacing: 18) {
            ProgressRing(fraction: fraction)
            VStack(spacing: 7) {
                Text(message).font(Theme.ui(18, weight: .medium)).foregroundStyle(Theme.text)
                Text(fraction != nil ? "one time only, then fully offline" : "almost ready")
                    .font(Theme.ui(13)).foregroundStyle(Theme.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct ProgressRing: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
            if let f = fraction {
                Circle().trim(from: 0, to: max(0.02, f))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: f)
                Text("\(Int((f * 100).rounded()))%").font(Theme.mono(17, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.text)
            } else {
                TimelineView(.animation(paused: reduce)) { ctx in
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(reduce ? 0 : ctx.date.timeIntervalSinceReferenceDate * 220))
                }
            }
        }
        .frame(width: 92, height: 92)
    }
}
