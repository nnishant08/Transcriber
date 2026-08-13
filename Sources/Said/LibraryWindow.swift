import SaidKit
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Smart collections (v3 screen 01 sidebar)

/// The sidebar's saved views. Every one is derived from data a session already carries — no new
/// state on disk, so an old session.json still lands in the right collections.
enum LibraryCollection: String, CaseIterable, Identifiable {
    case all, week, bookmarked, screen, speakers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .week: return "This week"
        case .bookmarked: return "Bookmarked"
        case .screen: return "Screen recordings"
        case .speakers: return "Multi-speaker"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .week: return "clock"
        case .bookmarked: return "bookmark"
        case .screen: return "play.rectangle"
        case .speakers: return "person.2"
        }
    }

    /// ⌘1…⌘5, the way a Mac sidebar numbers its top-level views.
    var shortcutIndex: Int { (LibraryCollection.allCases.firstIndex(of: self) ?? 0) + 1 }

    func contains(_ s: SessionInfo, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .week: return s.meta.date >= now.addingTimeInterval(-7 * 86_400)
        case .bookmarked: return !s.meta.bookmarks.isEmpty
        case .screen: return s.hasVideo
        case .speakers: return (s.meta.speakerCount ?? 0) > 1
        }
    }
}

// MARK: - Search tokens (v3 screen 01B)

/// v3: "Typing `speaker:` or `has:screen` completes into a token, exactly like Mail. It replaces both
/// dropdown chips and does far more." Tokens filter structurally; free text still goes to SearchIndex.
struct SearchToken: Identifiable, Equatable {
    enum Field: String, CaseIterable {
        case speaker, has, tag, `is`

        var hint: String {
            switch self {
            case .speaker: return "speaker:name"
            case .has: return "has:screen · has:audio · has:bookmark"
            case .tag: return "tag:name"
            case .is: return "is:kept · is:imported"
            }
        }
    }

    let field: Field
    let value: String

    var id: String { "\(field.rawValue):\(value)" }
    var display: String { "\(field.rawValue): \(value)" }

    /// Parse a typed fragment like `speaker:Priya` into a token (nil when it isn't one).
    static func parse(_ raw: String) -> SearchToken? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let name = String(t[t.startIndex..<colon]).lowercased()
        let value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let field = Field(rawValue: name), !value.isEmpty else { return nil }
        return SearchToken(field: field, value: value)
    }

    func matches(_ s: SessionInfo) -> Bool {
        let v = value.lowercased()
        switch field {
        case .speaker:
            let named = (s.meta.speakerNames ?? [:]).values.map { $0.lowercased() }
            if named.contains(where: { $0.contains(v) }) { return true }
            // Unnamed speakers are still addressable as "speaker 2" / "2".
            if let n = s.meta.speakerCount, let slot = Int(v.replacingOccurrences(of: "speaker", with: "")
                .trimmingCharacters(in: .whitespaces)) { return slot >= 1 && slot <= n }
            return false
        case .has:
            switch v {
            case "screen", "video", "recording": return s.hasVideo
            case "audio", "playback": return s.meta.audioFile != nil
            case "bookmark", "bookmarks": return !s.meta.bookmarks.isEmpty
            case "summary", "summaries": return !s.meta.summaries.isEmpty
            case "speaker", "speakers": return (s.meta.speakerCount ?? 0) > 1
            default: return false
            }
        case .tag:
            return s.meta.tags.contains { $0.lowercased().contains(v) }
        case .is:
            switch v {
            case "kept", "locked": return s.meta.retentionLocked == true
            case "imported": return s.meta.imported
            default: return false
            }
        }
    }
}

// MARK: - Model

/// Drives the Library route: lists sessions from disk (newest first), filters by collection + tag +
/// search tokens, and runs full-text search via `SearchIndex`. Live-refreshes on
/// `.transcriberSessionSaved`.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var query: String = "" { didSet { runSearch() } }
    @Published var tokens: [SearchToken] = []
    @Published var hits: [SessionHit] = []
    @Published var collection: LibraryCollection = .all
    @Published var selectedTag: String? = nil
    @Published var loading = false
    /// Sessions currently in flight to the Trash (drives the status pill).
    @Published var deleting = 0
    /// Set only when a move to the Trash actually failed; cleared on the next delete.
    @Published var deleteError: String?

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

    // MARK: Tokens

    func addToken(_ t: SearchToken) {
        guard !tokens.contains(t) else { return }
        tokens.append(t)
    }
    func removeToken(_ t: SearchToken) { tokens.removeAll { $0 == t } }
    func clearFilters() { tokens = []; query = ""; selectedTag = nil; collection = .all }

    // MARK: Derived listings

    var allTags: [String] { Array(Set(sessions.flatMap { $0.meta.tags })).sorted() }

    func tagCount(_ tag: String) -> Int { sessions.filter { $0.meta.tags.contains(tag) }.count }
    func collectionCount(_ c: LibraryCollection) -> Int { sessions.filter { c.contains($0) }.count }

    private func passesFilters(_ s: SessionInfo) -> Bool {
        collection.contains(s)
            && (selectedTag == nil || s.meta.tags.contains(selectedTag!))
            && tokens.allSatisfy { $0.matches(s) }
    }

    /// Browse list (no free text): sessions filtered by collection + tag + tokens, newest first.
    var visibleSessions: [SessionInfo] { sessions.filter(passesFilters) }

    /// Search results (free text present), respecting the same filters.
    var filteredHits: [SessionHit] {
        hits.filter { h in
            guard let info = info(for: h.dir) else { return false }
            return passesFilters(info)
        }
    }

    func info(for dir: URL) -> SessionInfo? { sessions.first { $0.dir.path == dir.path } }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasFilters: Bool { collection != .all || selectedTag != nil || !tokens.isEmpty || isSearching }

    /// v3's "4 of 128 shown".
    var countLabel: String {
        let shown = isSearching ? filteredHits.count : visibleSessions.count
        let total = sessions.count
        if shown == total { return "\(total) session\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total) shown"
    }

    var titleLabel: String {
        if isSearching { return "Search" }
        if let tag = selectedTag { return "#\(tag)" }
        return collection == .all ? "All Sessions" : collection.label
    }

    // MARK: Per-session actions

    func open(_ dir: URL) { ShellModel.shared.go(.session(dir)) }
    func reveal(_ dir: URL) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }

    /// Move sessions to the Trash.
    ///
    /// The rows are removed OPTIMISTICALLY, before the move is confirmed. `NSWorkspace.recycle`
    /// returns in microseconds but delivers its completion on the main run loop, and the callback
    /// can lag well behind the actual move — waiting for it to refresh the list is what made
    /// deleting look frozen for several seconds with nothing on screen. Anything that turns out
    /// not to have moved is put back below, so the optimism is always corrected.
    func delete(_ dirs: [URL]) {
        guard !dirs.isEmpty else { return }
        let paths = Set(dirs.map(\.path))
        let removed = sessions.filter { paths.contains($0.dir.path) }

        sessions.removeAll { paths.contains($0.dir.path) }
        hits.removeAll { paths.contains($0.dir.path) }
        deleting += dirs.count
        deleteError = nil

        // FileManager.trashItem, NOT NSWorkspace.recycle. `recycle` asks FINDER to do the move
        // via an Apple Event, which in a bundled app needs Automation permission — when that
        // doesn't arrive the call simply hangs, which is where the 10–20 s stall came from (a
        // plain CLI process never takes that path, which is why it timed at 0.02 s there).
        // `trashItem` renames straight into ~/.Trash, no Finder, no Apple Event, and still
        // records the original location so Finder's "Put Back" works.
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            var moved: [URL] = []
            var failures: [(URL, Error)] = []
            for dir in dirs {
                do {
                    // Routed through the C2 seam (injected with `trashItem` in AppModel.onLaunch),
                    // so the Library and SaidKit's own delete paths share one definition of "delete".
                    try SessionTrash.trash(dir)
                    moved.append(dir)
                } catch {
                    failures.append((dir, error))
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            let movedOut = moved, failedOut = failures
            await MainActor.run {
                guard let self else { return }
                NSLog("[Library] trashed \(movedOut.count)/\(dirs.count) in \(String(format: "%.2f", elapsed))s")
                self.deleting = max(0, self.deleting - dirs.count)
                movedOut.forEach { SearchIndex.shared.remove(dir: $0) }

                let succeeded = Set(movedOut.map(\.path))
                let failed = removed.filter { !succeeded.contains($0.dir.path) }
                guard !failed.isEmpty else { return }

                // Put back whatever didn't actually make it, keeping the newest-first order.
                self.sessions.append(contentsOf: failed)
                self.sessions.sort { $0.meta.date > $1.meta.date }
                self.deleteError = failedOut.first?.1.localizedDescription
                    ?? "Couldn't move \(failed.count) session\(failed.count == 1 ? "" : "s") to the Trash."
                if !self.query.isEmpty { self.runSearch() }
            }
        }
    }

    /// Copy a session's transcript to the pasteboard as Markdown (v3's row context menu).
    func copyAsMarkdown(_ dirs: [URL]) {
        let text = dirs.compactMap { SessionIO.readText($0.appendingPathComponent("transcript.md")) }
            .joined(separator: "\n\n---\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var shell: ShellModel

    private var lib: LibraryModel { shell.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            recordButton.padding(.bottom, 10)

            sectionHeader("Sessions")
            ForEach(LibraryCollection.allCases) { c in
                sidebarRow(label: c.label, symbol: c.symbol,
                           count: lib.collectionCount(c),
                           shortcut: "⌘\(c.shortcutIndex)",
                           selected: lib.collection == c && lib.selectedTag == nil) {
                    lib.collection = c
                    lib.selectedTag = nil
                    shell.go(.library)
                }
            }

            if !lib.allTags.isEmpty {
                sectionHeader("Tags").padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lib.allTags, id: \.self) { tag in
                            tagRow(tag)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                OnDeviceBadge()
                Spacer(minLength: 0)
                ToolbarIcon(system: "gearshape") { WindowManager.shared.showSettings() }
                    .help("Settings (⌘,)")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// v3 puts the one irreversible-feeling action at the top of the sidebar, in record red.
    private var recordButton: some View {
        Button { model.toggle(); shell.go(.capture) } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 12))
                Text(model.isRecording ? "Stop" : "Record")
                    .font(Theme.ui(13.5, weight: .semibold))
                Text("⌥⌘T").font(Theme.mono(10.5)).opacity(0.75)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.record))
        }
        .buttonStyle(.plain)
        .disabled(model.status.isBusyPreparing)
        .help(model.isRecording ? "Stop recording (⌥⌘T)" : "Start recording (⌥⌘T)")
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(Theme.sectionHeader).tracking(1.0)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func sidebarRow(label: String, symbol: String, count: Int, shortcut: String?,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                    .opacity(selected ? 1 : 0.8)
                Text(label).font(Theme.ui(13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(Theme.mono(10.5))
                    .foregroundStyle(selected ? Theme.onSelection.opacity(0.75) : Theme.text3)
            }
            .foregroundStyle(selected ? Theme.onSelection : Theme.textSidebar)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tagRow(_ tag: String) -> some View {
        let selected = shell.library.selectedTag == tag
        return Button {
            shell.library.selectedTag = selected ? nil : tag
            shell.go(.library)
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.speakerColor(abs(tag.hashValue) % 8 + 1))
                    .frame(width: 7, height: 7)
                    .frame(width: 16)
                Text(tag).font(Theme.ui(13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(shell.library.tagCount(tag))").font(Theme.mono(10.5))
                    .foregroundStyle(selected ? Theme.onSelection.opacity(0.75) : Theme.text3)
            }
            .foregroundStyle(selected ? Theme.onSelection : Theme.textSidebar)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar

struct LibraryToolbar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var shell: ShellModel
    private var lib: LibraryModel { shell.library }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lib.titleLabel).font(Theme.ui(13.5, weight: .semibold)).lineLimit(1).fixedSize()
                Text(lib.countLabel).font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
            }
            TokenSearchField(lib: lib)
                .frame(maxWidth: .infinity)
                .frame(minWidth: 180)
            ToolbarIcon(system: "square.and.arrow.down") { model.presentImportPanel() }
                .help("Import audio or video…")
            ToolbarIcon(system: "sidebar.right") { shell.inspectorVisible.toggle() }
                .help("Show or hide the inspector (⌥⌘I)")
            Button { WindowManager.shared.showAsk() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 12))
                    Text("Ask").font(Theme.ui(12.5, weight: .medium)).fixedSize()
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.accentBorder))
            }
            .buttonStyle(.plain)
            .help("Ask a question across every session")
        }
        .padding(.horizontal, 14)
    }
}

/// A Mail-style token field: committed tokens render as chips, free text keeps searching.
private struct TokenSearchField: View {
    @ObservedObject var lib: LibraryModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
            ForEach(lib.tokens) { token in
                HStack(spacing: 5) {
                    Text(token.display).font(Theme.ui(11.5, weight: .medium))
                    Button { lib.removeToken(token) } label: {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accentBorder))
            }
            TextField(lib.tokens.isEmpty ? "Search transcripts & slide text — or type speaker:, has:, tag:" : "",
                      text: Binding(get: { lib.query }, set: { commit($0) }))
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .focused($focused)
                .onSubmit { commit(lib.query + " ") }
            if lib.hasFilters {
                Button { lib.clearFilters() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.text3)
                .help("Clear search and filters")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.hairline2))
        .onTapGesture { focused = true }
    }

    /// `speaker:Priya ` (or Return) completes into a token; anything else stays free text.
    private func commit(_ raw: String) {
        guard raw.hasSuffix(" ") || raw.hasSuffix("\n") else { lib.query = raw; return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = SearchToken.parse(trimmed) {
            lib.addToken(token)
            lib.query = ""
        } else {
            lib.query = raw
        }
    }
}

// MARK: - Content list

struct LibraryContent: View {
    @ObservedObject var shell: ShellModel
    private var lib: LibraryModel { shell.library }

    var body: some View {
        Group {
            if lib.loading {
                placeholder("Loading…", "")
            } else if lib.isSearching {
                if lib.filteredHits.isEmpty {
                    placeholder("No matches", "Nothing matched “\(lib.query)”.")
                } else {
                    list(lib.filteredHits.map { $0.dir }, hits: lib.filteredHits)
                }
            } else if lib.visibleSessions.isEmpty {
                placeholder(lib.hasFilters ? "Nothing here" : "No sessions yet",
                            lib.hasFilters ? "No session matches these filters."
                                           : "Press ⌥⌘T from any app — you don't need this window open.")
            } else {
                list(lib.visibleSessions.map { $0.dir }, hits: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { statusPill }
        .animation(.easeInOut(duration: 0.18), value: lib.deleting)
        .animation(.easeInOut(duration: 0.18), value: lib.deleteError)
    }

    /// Non-blocking status for the Trash move. Deliberately NOT a modal: the rows already
    /// disappear on click, so a dialog would interrupt without telling the user anything new.
    /// It only needs to say the work is still finishing — and to speak up if it failed.
    @ViewBuilder private var statusPill: some View {
        if lib.deleting > 0 {
            pill {
                ProgressView().controlSize(.small)
                Text(lib.deleting == 1 ? "Moving to Trash…" : "Moving \(lib.deleting) sessions to Trash…")
                    .font(Theme.ui(13)).foregroundStyle(Theme.text2)
            }
        } else if let err = lib.deleteError {
            pill {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.record)
                Text(err).font(Theme.ui(13)).foregroundStyle(Theme.text2).lineLimit(2)
                Button("Dismiss") { lib.deleteError = nil }
                    .buttonStyle(.plain).font(Theme.ui(12, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func list(_ dirs: [URL], hits: [SessionHit]?) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(dirs, id: \.path) { dir in
                    let hit = hits?.first { $0.dir.path == dir.path }
                    SessionRow(info: lib.info(for: dir), hit: hit, shell: shell)
                    Divider().overlay(Theme.hairline)
                }
            }
        }
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.ui(16, weight: .medium)).foregroundStyle(Theme.text2)
            if !subtitle.isEmpty {
                Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Row

private struct SessionRow: View {
    let info: SessionInfo?
    let hit: SessionHit?
    @ObservedObject var shell: ShellModel
    @State private var hover = false

    private var lib: LibraryModel { shell.library }
    private var dir: URL? { info?.dir ?? hit?.dir }
    private var selected: Bool { dir.map { shell.selection.contains($0.path) } ?? false }
    /// The row that drives the inspector — v3 fills it with the system accent; the rest of a
    /// multi-selection gets the soft tint.
    private var primary: Bool { selected && shell.selection.count == 1 }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            SessionThumbnail(info: info, selected: primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(info?.displayTitle ?? hit?.title ?? "Session")
                    .font(Theme.ui(13.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(primary ? Theme.onSelection : Theme.text)
                metaLine
                if let hit {
                    ForEach(Array(hit.snippets.prefix(2).enumerated()), id: \.offset) { _, snip in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(snip.timestamp ?? "—").font(Theme.mono(10.5))
                                .foregroundStyle(primary ? Theme.onSelection.opacity(0.8) : Theme.accentText)
                                .frame(width: 38, alignment: .leading)
                            Text(snip.text).font(Theme.ui(12.5)).lineLimit(2)
                                .foregroundStyle(primary ? Theme.onSelection.opacity(0.92) : Theme.text2)
                        }
                    }
                } else if let snippet = info?.snippet, !snippet.isEmpty {
                    Text(snippet).font(Theme.ui(12.5)).lineLimit(2)
                        .foregroundStyle(primary ? Theme.onSelection.opacity(0.92) : Theme.text2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if let dir { lib.open(dir) } }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggleSelection() })
        .simultaneousGesture(TapGesture().onEnded { selectOnly() })
        .contextMenu { menu }
        // v3 screen 01C: "drag a session to Finder or Mail".
        .onDrag { NSItemProvider(contentsOf: dir) ?? NSItemProvider() }
    }

    @ViewBuilder private var metaLine: some View {
        let meta = info?.meta ?? hit?.meta
        HStack(spacing: 6) {
            if let meta {
                Text(Self.dateFmt.string(from: meta.date)).font(Theme.mono(10.5))
                if let d = meta.durationSeconds, d > 0 {
                    sep; Text(DocumentBuilder.timestamp(d)).font(Theme.mono(10.5))
                }
                sep; Text(meta.sourceLabel).font(Theme.ui(11.5))
                if let n = meta.speakerCount, n > 1 { sep; Text("\(n) speakers").font(Theme.ui(11.5)) }
                if meta.hasVideo { sep; Label("Screen", systemImage: "play.rectangle").font(Theme.ui(11)) }
                if meta.retentionLocked == true {
                    sep; Image(systemName: "lock.fill").font(.system(size: 8.5))
                }
            }
        }
        .foregroundStyle(primary ? Theme.onSelection.opacity(0.85) : Theme.text3)
        .lineLimit(1)
    }

    private var sep: some View {
        Circle().fill(primary ? Theme.onSelection.opacity(0.6) : Theme.text3).frame(width: 2.5, height: 2.5)
    }

    @ViewBuilder private var rowBackground: some View {
        if primary { Theme.selection }
        else if selected { Theme.selectionSoft }
        else if hover { Theme.rowHover }
        else { Color.clear }
    }

    @ViewBuilder private var menu: some View {
        let targets = selectionTargets
        Button("Open") { targets.first.map { lib.open($0) } }
        Button("Reveal in Finder") { targets.first.map { lib.reveal($0) } }
        Divider()
        Button("Copy as Markdown") { lib.copyAsMarkdown(targets) }
        Divider()
        Button(targets.count > 1 ? "Move \(targets.count) Sessions to Trash" : "Move to Trash") {
            lib.delete(targets)
            shell.selection = []
        }
    }

    /// Act on the whole selection when this row is part of it, else just this row.
    private var selectionTargets: [URL] {
        guard let dir else { return [] }
        if selected, shell.selection.count > 1 {
            return lib.sessions.filter { shell.selection.contains($0.dir.path) }.map { $0.dir }
        }
        return [dir]
    }

    private func selectOnly() { if let dir { shell.selection = [dir.path] } }
    private func toggleSelection() {
        guard let dir else { return }
        if shell.selection.contains(dir.path) { shell.selection.remove(dir.path) }
        else { shell.selection.insert(dir.path) }
    }

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd  HH:mm"; return f
    }()
}

/// 44×44 leading thumbnail: a poster frame from the session's video when it has one, else a source icon.
private struct SessionThumbnail: View {
    let info: SessionInfo?
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.onSelection.opacity(0.9) : Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected ? Color.white.opacity(0.15) : Theme.surface)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .task(id: info?.dir.path) { await loadThumbnail() }
    }

    private var symbol: String {
        guard let info else { return "waveform" }
        if info.meta.imported { return "square.and.arrow.down" }
        return info.hasVideo ? "play.rectangle" : "waveform"
    }

    /// A poster frame ~10% into the video. Encrypted sessions are skipped rather than decrypted to a
    /// temp file: a listing row is not worth writing plaintext to disk for.
    private func loadThumbnail() async {
        image = nil
        guard let info, info.hasVideo, let name = info.meta.videoFile else { return }
        let url = info.dir.appendingPathComponent(name)
        let duration = info.meta.durationSeconds ?? 0
        image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let raw = try? FileHandle(forReadingFrom: url).read(upToCount: 8),
                  !SessionIO.isEncryptedBlob(raw) else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 176, height: 176)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let at = CMTime(seconds: max(0.5, duration * 0.1), preferredTimescale: 600)
            guard let cg = try? await generator.image(at: at).image else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

// MARK: - Inspector (v3's right pane)

struct LibraryInspector: View {
    @ObservedObject var shell: ShellModel
    private var lib: LibraryModel { shell.library }

    var body: some View {
        if let info = shell.selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(info.displayTitle).font(Theme.ui(15, weight: .semibold)).lineLimit(3)
                        Text(subtitle(info)).font(Theme.mono(11)).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                    .padding(.horizontal, 15).padding(.top, 14).padding(.bottom, 12)
                    Divider().overlay(Theme.hairline)

                    VStack(alignment: .leading, spacing: 0) {
                        if let summary = bestSummary(info) {
                            inspectorHeader("Summary")
                            SummaryCard(text: summary)
                                .padding(.bottom, 15)
                        }
                        inspectorHeader("Open in")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                                  spacing: 7) {
                            openCard("Transcript", "Read, seek, export") { lib.open(info.dir) }
                            openCard("Studio", "Templates") { lib.open(info.dir) }
                            openCard("Chat", "Ask this session") { lib.open(info.dir) }
                            if info.hasVideo {
                                openCard("Screen video", "Play with transcript") { lib.open(info.dir) }
                            }
                        }
                        if !info.meta.tags.isEmpty {
                            inspectorHeader("Tags").padding(.top, 15)
                            FlowChips(items: info.meta.tags.map { ($0, $0) }) { tag in
                                lib.selectedTag = tag
                            }
                        }
                        Text("The inspector hides with ⌥⌘I and stays hidden, the way Finder's preview pane does.")
                            .font(Theme.ui(11)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 14)
                }
            }
        } else {
            VStack(spacing: 6) {
                Text(shell.selection.count > 1 ? "\(shell.selection.count) sessions selected" : "No selection")
                    .font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text2)
                Text(shell.selection.count > 1 ? "Right-click to act on all of them."
                                               : "Select a session to preview it here.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
        }
    }

    private func subtitle(_ info: SessionInfo) -> String {
        var parts = [SessionRowDateFormat.string(from: info.meta.date)]
        if let d = info.meta.durationSeconds, d > 0 { parts.append(DocumentBuilder.timestamp(d)) }
        parts.append(info.meta.sourceLabel)
        if info.hasVideo { parts.append("screen recording") }
        return parts.joined(separator: " · ")
    }

    /// The cheapest already-cached summary — the inspector never triggers a model run.
    private func bestSummary(_ info: SessionInfo) -> String? {
        for style in SummaryStyle.allCases {
            if let s = info.meta.summaries[style.rawValue], !s.isEmpty { return s }
        }
        return info.meta.summaries.values.first { !$0.isEmpty }
    }

    private func inspectorHeader(_ s: String) -> some View {
        Text(s.uppercased()).font(Theme.ui(10, weight: .semibold)).tracking(1.2)
            .foregroundStyle(Theme.text3).padding(.bottom, 9)
    }

    private func openCard(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(12, weight: .semibold))
                Text(subtitle).font(Theme.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The summary card with v3's pink→indigo→teal top edge (the one place that gradient appears).
struct SummaryCard: View {
    let text: String
    var lineLimit: Int? = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.summaryEdge.frame(height: 2)
            Text(text)
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2)
                .lineSpacing(2.5)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 12)
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

let SessionRowDateFormat: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd  HH:mm"; return f
}()
