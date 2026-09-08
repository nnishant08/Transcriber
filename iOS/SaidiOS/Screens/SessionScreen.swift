import SwiftUI
import AVKit
import SaidKit

/// Screen 06 — the session.
///
/// Everything is anchored to its moment: turns with speaker dots and mono timestamps, slide cards
/// dropped into the flow where they were taken, and one ink player that stays put across all three
/// tabs. Amber marks the current position, because amber marks whatever is happening now.
struct SessionScreen: View {
    @StateObject private var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var sharing = false

    init(dir: URL) { _model = StateObject(wrappedValue: SessionModel(dir: dir)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.windowBG.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabs
                content
            }

            if model.hasPlayback { PlayerBar(model: model) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Send this session")
            }
        }
        .sheet(isPresented: $sharing) { SendSheet(dir: model.dir, meta: model.meta) }
        .alert("Name this speaker", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let slot = renaming { model.rename(slot: slot, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Renames apply to this session and become searchable.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(displayTitle)
                .font(Theme.ui(27, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 7) {
                if let n = model.meta.speakerCount, n > 0 {
                    HStack(spacing: -7) {
                        ForEach(1...min(n, 3), id: \.self) { SpeakerDot(slot: $0, size: 22) }
                    }
                }
                Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private var displayTitle: String {
        let raw = model.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? TitleGenerator.fallbackTitle(transcript: "", date: model.meta.date) : raw
    }

    private var subtitle: String {
        var parts: [String] = []
        if let n = model.meta.speakerCount, n > 1 { parts.append("\(n) voices") }
        if model.duration > 0 { parts.append("\(Int(model.duration / 60)) min") }
        if !model.frames.isEmpty { parts.append("\(model.frames.count) slides") }
        if model.hasVideo { parts.append("screen recording") }
        return parts.joined(separator: " · ")
    }

    private var tabs: some View {
        HStack(spacing: 7) {
            tabChip("Transcript", 0)
            tabChip("The gist", 1)
            tabChip("To do", 2, badge: model.meta.actionItems.count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func tabChip(_ title: String, _ index: Int, badge: Int = 0) -> some View {
        Button { tab = index } label: {
            HStack(spacing: 5) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)").foregroundStyle(Palette.amberInk2)
                }
            }
            .font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(tab == index ? .white : Theme.text2)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(tab == index ? Palette.ink : Theme.surface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == index ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 1: GistTab(model: model)
        case 2: TasksTab(model: model)
        default: transcriptTab
        }
    }

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // A Mac-recorded screen video plays above the transcript, as it does on the Mac.
                    // The iPhone never records video, but it must play what the Mac sends it.
                    if model.hasVideo, let player = model.video {
                        VideoPlayer(player: player)
                            .frame(height: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    ForEach(model.rows) { row in
                        switch row {
                        case .segment(let i, let seg):
                            TurnRow(seg: seg,
                                    name: seg.speaker.map { model.speakerName($0) },
                                    slot: seg.speaker,
                                    active: model.isActive(row),
                                    onTap: { model.goTo(seg.start) },
                                    onRenameTap: { slot in
                                        renaming = slot
                                        renameText = model.speakerName(slot)
                                    })
                                .id(row.id)
                        case .frame(let f):
                            SlideCardRow(frame: f, image: model.frameImage(f),
                                         active: model.isActive(row)) { model.goTo(f.time) }
                                .id(row.id)
                        }
                    }
                    Color.clear.frame(height: 150)
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

// MARK: - Rows

private struct TurnRow: View {
    let seg: TranscriptSegment
    let name: String?
    let slot: Int?
    let active: Bool
    let onTap: () -> Void
    let onRenameTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let slot {
                    SpeakerDot(slot: slot)
                    Button { onRenameTap(slot) } label: {
                        Text(name ?? "Speaker \(slot)")
                            .font(Theme.ui(13, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double tap to rename this speaker")
                }
                MonoTime(seconds: seg.start, color: active ? Palette.amberInk2 : Theme.text3)
            }
            Text(seg.text)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(Theme.text)
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        // Amber marks the line being played — the identity's one rule.
        .background(active ? Palette.amberTint.opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name ?? "") at \(MonoTime.spoken(seg.start)). \(seg.text)")
        .accessibilityHint("Double tap to play from here")
    }
}

/// A slide on the timeline, at the moment it was taken.
private struct SlideCardRow: View {
    let frame: FrameEvent
    let image: UIImage?
    let active: Bool
    let onTap: () -> Void

    @State private var showText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "photo").font(.system(size: 13))
                    Text("Slide image missing").font(Theme.ui(12))
                }
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity).padding(.vertical, 26)
                .background(Theme.surface2)
            }

            HStack(spacing: 8) {
                MonoTime(seconds: frame.time, size: 11, weight: .medium, color: Palette.amberInk2)
                Text("SLIDE")
                    .font(Theme.mono(9.5, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Palette.amberInk2.opacity(0.75))
                Spacer(minLength: 0)
                if frame.text?.isEmpty == false {
                    Button { showText.toggle() } label: {
                        Text(showText ? "Hide text" : "Read text")
                            .font(Theme.ui(11, weight: .semibold))
                            .foregroundStyle(Palette.violet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(Palette.amberTint)

            if showText, let t = frame.text, !t.isEmpty {
                Text(t)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(Theme.surface2)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(active ? Palette.amber : Theme.hairline2)
                .offset(y: 3)
        )
        .padding(.leading, 18)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Slide at \(MonoTime.spoken(frame.time)). \(frame.text ?? "No text read")")
        .accessibilityHint("Double tap to play from here")
    }
}

// MARK: - Player

/// The ink player bar — a physical-feeling remote that stays put across all three tabs.
private struct PlayerBar: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                MonoTime(seconds: model.currentTime, color: Palette.amber)
                    .frame(width: 40, alignment: .leading)

                Slider(value: Binding(
                    get: { model.currentTime },
                    set: { model.currentTime = $0 }
                ), in: 0...max(model.duration, 1)) { editing in
                    model.isScrubbing = editing
                    if !editing { model.goTo(model.currentTime) }
                }
                .tint(Palette.amber)

                MonoTime(seconds: model.duration, color: .white.opacity(0.5))
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 26) {
                Button { model.skip(-15) } label: {
                    Text("15s").font(Theme.ui(13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
                .accessibilityLabel("Back 15 seconds")

                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Palette.amberInk)
                        .frame(width: 52, height: 52)
                        .background(Palette.amber)
                        .clipShape(Circle())
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Button { model.skip(15) } label: {
                    Text("15s").font(Theme.ui(13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
                .accessibilityLabel("Forward 15 seconds")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
}
