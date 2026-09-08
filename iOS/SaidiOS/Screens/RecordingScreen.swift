import SwiftUI
import SaidKit

/// Screen 04 — Listening.
///
/// Violet-deep ground. Older turns fade back; the live one sits at full strength with an amber blob
/// and an amber caret. That is the identity's one rule doing the work: no label is needed to know
/// where to look.
///
/// Names read `Speaker 1` live and that is deliberate, not a placeholder — diarization is a batch
/// pass after stop, so claiming a name here would be a lie the app cannot back up.
struct RecordingScreen: View {
    @ObservedObject var model: RecordingModel
    var onDone: (URL?) -> Void
    var onCaptureSlide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markedLines = Set<Int>()

    var body: some View {
        ZStack {
            Palette.violetDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                meterBlock
                transcript
                controls
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.isPaused ? Theme.pause : Palette.amber)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 1 : 0.45)
                Text(statusText)
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 11).padding(.trailing, 13).padding(.vertical, 6)
            .background(Color.white.opacity(0.14))
            .clipShape(Capsule())

            Spacer()

            Text("On this iPhone")
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    @State private var pulse = false

    private var statusText: String {
        switch model.status {
        case .paused(.silence):       return "Paused — it went quiet"
        case .paused(.interruption):  return "Paused — call in progress"
        case .paused(.routeLost):     return "Paused — headphones removed"
        case .paused(.user):          return "Paused"
        case .preparing(let m, _):    return m
        case .finalizing:             return "Finishing…"
        case .failed(let m):          return m
        default:                      return "Listening — this room"
        }
    }

    // MARK: Timer + meter

    private var meterBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(DocumentBuilder.timestamp(model.elapsed))
                .font(Theme.mono(60, weight: .medium))
                .foregroundStyle(.white)
                .monospacedDigit()
                .accessibilityLabel("Recorded \(MonoTime.spoken(model.elapsed))")

            meter
                .frame(height: 48)

            if case .paused(.silence) = model.status {} else if model.quietSeconds > 0,
               model.quietSeconds >= 22 {
                Text("auto-pausing in \(max(0, 30 - model.quietSeconds))s")
                    .font(Theme.mono(11))
                    .foregroundStyle(Palette.amber.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 22)
    }

    /// Amber marks live. The bars are driven by the sink's recent RMS, the same probe the Mac meter
    /// uses, so a quiet room looks the same on both.
    private var meter: some View {
        GeometryReader { geo in
            let count = 12
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<count, id: \.self) { i in
                    let h = barHeight(i, in: geo.size.height)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(i))
                        .frame(height: h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.level)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int, in max: CGFloat) -> CGFloat {
        guard !model.isPaused else { return max * 0.08 }
        // A fixed profile scaled by the live level — a meter, not a spectrum analyser.
        let profile: [CGFloat] = [0.28, 0.52, 0.38, 0.72, 0.44, 0.88, 0.62, 1.0, 0.48, 0.30, 0.20, 0.14]
        let scaled = profile[i % profile.count] * CGFloat(min(1, model.level * 9))
        return Swift.max(max * 0.08, max * scaled)
    }

    private func barColor(_ i: Int) -> Color {
        if model.isPaused { return .white.opacity(0.16) }
        let lit = Int(CGFloat(12) * CGFloat(min(1, model.level * 9)))
        return i < lit ? Palette.amber : .white.opacity(0.25)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { i, seg in
                        turn(index: i, text: seg.text,
                             live: false,
                             faded: i < model.segments.count - 2)
                            .id("t\(i)")
                    }
                    if !model.hypothesis.isEmpty {
                        turn(index: -1, text: model.hypothesis, live: true, faded: false)
                            .id("live")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: model.segments.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func turn(index: Int, text: String, live: Bool, faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Blob(size: 9, color: live ? Palette.amber : .white)
                Text("Speaker 1")
                    .font(Theme.ui(12, weight: .bold))
                    .foregroundStyle(live ? Palette.amber : .white.opacity(0.8))
                if live {
                    Text("now")
                        .font(Theme.ui(11, weight: .semibold))
                        .foregroundStyle(Palette.amber)
                }
                if index >= 0, markedLines.contains(index) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.amber)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text(text)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(.white.opacity(live ? 1 : 0.9))
                if live { Caret() }
            }
            .padding(.leading, 16)
        }
        .opacity(faded ? 0.45 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard index >= 0 else { return }
            model.addBookmark()
            markedLines.insert(index)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(live ? "Currently speaking. " : "")\(text)")
        .accessibilityHint(index >= 0 ? "Double tap to mark this moment" : "")
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 11) {
            if model.bookmarkCount > 0 {
                HStack(spacing: 11) {
                    Blob(size: 8, color: Palette.amberInk)
                        .padding(6).background(Palette.amberInk.opacity(0.001))
                    Text("Tap a line to mark it — \(model.bookmarkCount) marked")
                        .font(Theme.ui(13, weight: .semibold))
                        .foregroundStyle(Palette.amberInk)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15).padding(.vertical, 13)
                .background(Palette.amber)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)
            }

            HStack(spacing: 11) {
                Button(action: onCaptureSlide) {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Palette.amber, lineWidth: 2)
                            .frame(width: 15, height: 11)
                        Text("Slide").font(Theme.ui(15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture a slide")
                .accessibilityHint("Opens the camera without stopping the recording")

                Button {
                    Task { onDone(await model.stop()) }
                } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Palette.amberInk)
                            .frame(width: 15, height: 15)
                        Text("Done").font(Theme.ui(16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.amberInk)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(Palette.amber)
                    .clipShape(Capsule())
                    .background(Capsule().fill(Palette.amberPress).offset(y: 4))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Done")
                .accessibilityHint("Stops and saves this recording")
            }
            .padding(.horizontal, 20)

            if model.isPaused {
                Button("Resume") { model.resume() }
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                    .padding(.top, 2)
            } else {
                Button("Pause") { model.pause() }
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 20)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// The blinking caret on the live turn — amber, because it marks what is being said right now.
private struct Caret: View {
    @State private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Palette.amber)
            .frame(width: 3, height: 17)
            .padding(.leading, 3)
            .opacity(on ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
            }
    }
}
