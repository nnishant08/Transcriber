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
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let speeds: [Double] = [1.1, 0.8, 1.4, 0.95, 1.2, 0.85, 1.35, 1.0]
    private let phases: [Double] = [0, 0.6, 1.2, 0.3, 1.8, 0.9, 2.2, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06, paused: reduce)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<8, id: \.self) { i in
                    Capsule().fill(Theme.record).opacity(0.85)
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
