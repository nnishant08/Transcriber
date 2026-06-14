import SwiftUI
import AppKit

/// Quick date-range filter for the Library.
enum DateRangeFilter: CaseIterable, Identifiable {
    case all, week, month, year
    var id: Self { self }
    var label: String {
        switch self {
        case .all: return "All time"
        case .week: return "Past 7 days"
        case .month: return "Past 30 days"
        case .year: return "Past year"
        }
    }
    /// Earliest date allowed, or nil for "all".
    func start(now: Date = Date()) -> Date? {
        switch self {
        case .all: return nil
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .year: return now.addingTimeInterval(-365 * 86_400)
        }
    }
}

/// Drives the Library window: lists sessions from disk (newest first), filters by tag + date range,
/// and runs full-text search via `SearchIndex`. Live-refreshes on `.transcriberSessionSaved`.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var query: String = "" { didSet { runSearch() } }
    @Published var hits: [SessionHit] = []
    @Published var selectedTag: String? = nil
    @Published var dateRange: DateRangeFilter = .all
    @Published var loading = false

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .transcriberSessionSaved,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func reload() {
        loading = sessions.isEmpty
        Task {
            let all = await Task.detached(priority: .userInitiated) { SessionStore.allSessions() }.value
            self.sessions = all
            self.loading = false
            // Lazily backfill titles for sessions that don't have one — and self-heal any whose stored
            // title still needs sanitizing (throttled, one at a time; the latter is a no-model repair).
            let needsTitle = all.filter { s in
                let t = s.meta.title?.trimmingCharacters(in: .whitespaces) ?? ""
                return t.isEmpty || TitleGenerator.sanitizeTitle(t) != t
            }.map { $0.dir }
            if !needsTitle.isEmpty { await TitleBackfill.shared.enqueue(needsTitle) }
            if !self.query.isEmpty { self.runSearch() }
        }
    }

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        hits = q.isEmpty ? [] : SearchIndex.shared.search(q)
    }

    var allTags: [String] { Array(Set(sessions.flatMap { $0.meta.tags })).sorted() }

    /// Browse list (search empty): sessions filtered by tag + date range, newest first.
    var visibleSessions: [SessionInfo] {
        let start = dateRange.start()
        return sessions.filter { s in
            (selectedTag == nil || s.meta.tags.contains(selectedTag!)) &&
            (start == nil || s.meta.date >= start!)
        }
    }

    /// Search results (search non-empty), respecting the same tag + date filters.
    var filteredHits: [SessionHit] {
        let start = dateRange.start()
        return hits.filter { h in
            (selectedTag == nil || h.meta.tags.contains(selectedTag!)) &&
            (start == nil || h.meta.date >= start!)
        }
    }

    func info(for dir: URL) -> SessionInfo? { sessions.first { $0.dir.path == dir.path } }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var countLabel: String {
        if isSearching {
            let n = filteredHits.count
            return "\(n) match\(n == 1 ? "" : "es")"
        }
        let n = visibleSessions.count
        return "\(n) session\(n == 1 ? "" : "s")"
    }

    // MARK: - Per-session actions

    func open(_ dir: URL) {
        WindowManager.shared.showViewer(dir: dir)   // in-app Session Viewer (Prompt 2)
    }
    func reveal(_ dir: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
    func delete(_ dir: URL) {
        NSWorkspace.shared.recycle([dir]) { [weak self] _, _ in
            Task { @MainActor in
                SearchIndex.shared.remove(dir: dir)
                self?.reload()
            }
        }
    }
}

// MARK: - View

struct LibraryWindow: View {
    @StateObject private var lib = LibraryModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(Theme.windowBG)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .onAppear { lib.reload() }
    }

    // MARK: Header (search + filters)

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.text2)
                TextField("Search transcripts & slide text…", text: $lib.query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(14))
                if !lib.query.isEmpty {
                    Button { lib.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))

            HStack(spacing: 12) {
                Menu {
                    Button("All tags") { lib.selectedTag = nil }
                    if !lib.allTags.isEmpty { Divider() }
                    ForEach(lib.allTags, id: \.self) { tag in
                        Button(tag) { lib.selectedTag = tag }
                    }
                } label: {
                    Label(lib.selectedTag ?? "All tags", systemImage: "tag").font(Theme.ui(12.5))
                }
                .menuStyle(.borderlessButton).fixedSize()

                Menu {
                    ForEach(DateRangeFilter.allCases) { r in
                        Button(r.label) { lib.dateRange = r }
                    }
                } label: {
                    Label(lib.dateRange.label, systemImage: "calendar").font(Theme.ui(12.5))
                }
                .menuStyle(.borderlessButton).fixedSize()

                Spacer()
                Button { WindowManager.shared.showAsk() } label: {
                    Label("Ask", systemImage: "sparkles").font(Theme.ui(12.5))
                }.buttonStyle(.plain).foregroundStyle(Theme.accentText)
                Button { AppModel.shared.presentImportPanel() } label: {
                    Label("Import…", systemImage: "square.and.arrow.down").font(Theme.ui(12.5))
                }.buttonStyle(.plain).foregroundStyle(Theme.text2)
                Text(lib.countLabel).font(Theme.ui(12)).foregroundStyle(Theme.text3)
            }
        }
        .padding(14)
        .background(Theme.titlebar)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if lib.loading {
            placeholder("Loading…", "")
        } else if lib.isSearching {
            if lib.filteredHits.isEmpty {
                placeholder("No matches", "Nothing matched “\(lib.query)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(lib.filteredHits) { hit in
                            SearchHitRow(hit: hit, info: lib.info(for: hit.dir), lib: lib)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        } else {
            if lib.visibleSessions.isEmpty {
                placeholder("No sessions yet", "Recordings you make will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(lib.visibleSessions) { s in
                            SessionRow(info: s, lib: lib)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.ui(16, weight: .medium)).foregroundStyle(Theme.text2)
            if !subtitle.isEmpty { Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.text3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Rows

private struct SessionRow: View {
    let info: SessionInfo
    @ObservedObject var lib: LibraryModel
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.hasImages ? "rectangle.on.rectangle.angled" : "waveform")
                .font(.system(size: 15)).foregroundStyle(Theme.text2)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(info.displayTitle).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if info.hasImages {
                        Label("\(info.imageCount)", systemImage: "photo")
                            .font(Theme.ui(10.5)).foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentSoft))
                    }
                    if let n = info.meta.speakerCount, n > 1 {
                        Label("\(n)", systemImage: "person.2")
                            .font(Theme.ui(10.5)).foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentSoft))
                            .help("\(n) speakers identified")
                    }
                }
                HStack(spacing: 7) {
                    Text(Self.dateFmt.string(from: info.meta.date)).font(Theme.mono(11.5)).foregroundStyle(Theme.text3)
                    Circle().fill(Theme.text3).frame(width: 2.5, height: 2.5)
                    Text(info.meta.sourceLabel).font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
                }
                if !info.snippet.isEmpty {
                    Text(info.snippet).font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                }
                if !info.meta.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(info.meta.tags.prefix(5), id: \.self) { tag in
                            Text(tag).font(Theme.ui(10.5)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            RowActions(dir: info.dir, lib: lib).opacity(hover ? 1 : 0.55)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(hover ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { lib.open(info.dir) }
        .contextMenu { RowMenu(dir: info.dir, lib: lib) }
    }

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd  HH:mm"; return f
    }()
}

private struct SearchHitRow: View {
    let hit: SessionHit
    let info: SessionInfo?
    @ObservedObject var lib: LibraryModel
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: (info?.hasImages ?? false) ? "rectangle.on.rectangle.angled" : "waveform")
                .font(.system(size: 15)).foregroundStyle(Theme.text2).frame(width: 22).padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(info?.displayTitle ?? hit.title).font(Theme.ui(14, weight: .medium))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(hit.matchCount) match\(hit.matchCount == 1 ? "" : "es")")
                        .font(Theme.ui(10.5)).foregroundStyle(Theme.text3)
                }
                Text(SessionRow.dateFmt.string(from: hit.meta.date)).font(Theme.mono(11.5)).foregroundStyle(Theme.text3)
                ForEach(Array(hit.snippets.enumerated()), id: \.offset) { _, snip in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(snip.timestamp ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.accentText)
                            .frame(width: 38, alignment: .leading)
                        Text(snip.text).font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
            RowActions(dir: hit.dir, lib: lib).opacity(hover ? 1 : 0.55)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(hover ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { lib.open(hit.dir) }
        .contextMenu { RowMenu(dir: hit.dir, lib: lib) }
    }
}

private struct RowActions: View {
    let dir: URL
    @ObservedObject var lib: LibraryModel
    var body: some View {
        HStack(spacing: 2) {
            ToolbarIcon(system: "doc.text") { lib.open(dir) }.help("Open transcript")
            ToolbarIcon(system: "folder") { lib.reveal(dir) }.help("Reveal in Finder")
            ToolbarIcon(system: "trash") { lib.delete(dir) }.help("Move to Trash")
        }
    }
}

private struct RowMenu: View {
    let dir: URL
    @ObservedObject var lib: LibraryModel
    var body: some View {
        Button("Open Transcript") { lib.open(dir) }
        Button("Reveal in Finder") { lib.reveal(dir) }
        Divider()
        Button("Move to Trash") { lib.delete(dir) }
    }
}
