import SwiftUI
import SaidKit

/// The single root. Library is the home; the dock's middle third starts a recording; Ask takes the
/// right third — the placement the Mac redesign left open and the iPhone screens settled.
struct RootView: View {
    @StateObject private var recorder = RecordingModel()
    @State private var tab: RecordDock.Tab = .library
    @State private var recording = false
    @State private var sessions: [SessionInfo] = []
    @State private var justSaved: URL?
    @State private var capturingSlide = false
    @State private var recovered: SessionRecovery.Recovered?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.windowBG.ignoresSafeArea()

                Group {
                    switch tab {
                    case .library: LibraryScreen(sessions: sessions, justSaved: justSaved)
                    case .ask:     AskPlaceholder()
                    }
                }

                RecordDock(tab: $tab) { recording = true }
            }
            .navigationDestination(for: URL.self) { SessionScreen(dir: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $recording) {
            RecordingScreen(model: recorder) { saved in
                recording = false
                justSaved = saved
                reload()
            } onCaptureSlide: {
                capturingSlide = true
            }
            .task { await recorder.start() }
            // Presented OVER the recording view, which keeps running behind it.
            .fullScreenCover(isPresented: $capturingSlide) {
                SlideCaptureScreen(model: recorder) { capturingSlide = false }
            }
        }
        .onAppear(perform: reload)
        .task {
            // Finish anything a kill interrupted, BEFORE the library lists — so a recovered
            // recording is simply there, rather than appearing a moment later.
            let found = await SessionRecovery.recoverAll()
            if let first = found.first { recovered = first }
            reload()
        }
        .alert("Said recovered a recording", isPresented: Binding(
            get: { recovered != nil }, set: { if !$0 { recovered = nil } })) {
            Button("OK") { recovered = nil }
        } message: {
            if let r = recovered {
                Text("Said was closed while recording \(SessionRecovery.dayName(r.startedAt)). "
                     + "\(Int(r.seconds / 60)) min \(Int(r.seconds.truncatingRemainder(dividingBy: 60))) s were saved.")
            }
        }
    }

    private func reload() {
        Task.detached(priority: .userInitiated) {
            let all = SessionStore.allSessions()
            await MainActor.run { sessions = all }
        }
    }
}

/// Screen 02 — Library. Sticker cards on paper, newest first.
struct LibraryScreen: View {
    let sessions: [SessionInfo]
    let justSaved: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Said").font(Theme.ui(36, weight: .semibold))
                    Text(".").font(Theme.ui(36, weight: .semibold)).foregroundStyle(Palette.amber)
                }
                .padding(.bottom, 4)

                if sessions.isEmpty {
                    VStack(spacing: 10) {
                        BlobPair(size: 16)
                            .padding(16)
                            .background(Palette.violet)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Text("Nothing recorded yet")
                            .font(Theme.ui(16, weight: .semibold))
                        Text("Tap the button below and start talking.")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    SectionRule(title: "Sessions")
                    ForEach(sessions) { s in
                        NavigationLink(value: s.dir) {
                            SessionRowCard(info: s, highlighted: s.dir.path == justSaved?.path)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Color.clear.frame(height: 100)
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }
}

/// One session as a sticker card. Tile colour carries the KIND of session, so the list reads
/// before you read it.
struct SessionRowCard: View {
    let info: SessionInfo
    var highlighted = false

    private var tile: Color {
        if info.hasFrames { return Palette.violet }
        if info.hasVideo { return Palette.ink }
        if (info.meta.speakerCount ?? 0) > 1 { return Palette.amber }
        return Palette.ink
    }

    var body: some View {
        StickerCard(edge: highlighted ? Palette.violet : Theme.hairline2) {
            HStack(spacing: 14) {
                BlobPair(size: 12, leading: .white,
                         trailing: tile == Palette.amber ? Palette.amberInk : Palette.amber)
                    .frame(width: 44, height: 44)
                    .background(tile)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.displayTitle)
                        .font(Theme.ui(16, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 0)
                if let d = info.meta.durationSeconds, d > 0 { MonoTime(seconds: d) }
            }
            .padding(15)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.displayTitle). \(subtitle)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = info.meta.durationSeconds, d > 0 { parts.append("\(Int(d / 60)) min") }
        if let n = info.meta.speakerCount, n > 1 { parts.append("\(n) voices") }
        if info.hasFrames { parts.append("\(info.frameCount) slides") }
        if info.hasVideo { parts.append("screen") }
        if parts.isEmpty { parts.append(info.meta.sourceLabel) }
        return parts.joined(separator: " · ")
    }
}

struct AskPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            SectionRule(title: "Ask")
            Text("Coming in the next pass.")
                .font(Theme.ui(14)).foregroundStyle(Theme.text2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
