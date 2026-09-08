import SwiftUI
import SaidKit

// Phase 3's Settings panels.
//
// Deliberately in their own file, as SEPARATE View structs rather than `@ViewBuilder` properties on
// `SettingsView`. Two reasons, one of which is load-bearing:
//
//  1. `SettingsView.body` is already a `Form` with thirteen sections, and the file carries a comment
//     recording that the type-checker gave up on one of them ("unable to type-check this expression
//     in reasonable time") once SaidKit became its own module. Adding five more sections inline
//     would walk straight back into that. Each panel here is a fresh, small problem for the solver.
//  2. Three of them need their own `@State` (an inventory that loads asynchronously, an editing
//     buffer), which a `@ViewBuilder` property on the parent cannot have.

// MARK: - Transcription engine

struct EngineSettingsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Engine", selection: $model.enginePreference) {
            ForEach(EnginePreference.allCases, id: \.self) { p in
                Text(p.displayName).tag(p)
            }
        }
        .disabled(model.isRecording || model.status.isBusyPreparing)

        Text(model.enginePreference.explanation)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        if model.enginePreference == .automatic {
            Text("Parakeet covers 25 European languages and is many times faster than real time, so a "
                 + "long recording finishes almost as soon as you stop it. Anything outside that set — "
                 + "Hindi, Arabic, Japanese, Korean and much else — goes to Whisper automatically, and "
                 + "the session records which engine ran.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if model.enginePreference == .parakeet {
            Label("A recording in a language Parakeet doesn't cover will produce fluent nonsense "
                  + "rather than an error. Automatic avoids that.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Storage

struct StorageSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var models: [InstalledModel] = []
    @State private var loading = true
    @State private var pendingDelete: InstalledModel?

    var body: some View {
        if loading {
            HStack { ProgressView().controlSize(.small); Text("Measuring…").font(.caption) }
        } else if models.isEmpty {
            Text("No models downloaded yet. They arrive on first use and then work offline.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(models) { m in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.callout)
                        HStack(spacing: 6) {
                            Text(m.kind.displayName)
                            if isRequired(m) { Text("· in use").foregroundStyle(.secondary) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(m.displaySize).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Delete") { pendingDelete = m }
                        .controlSize(.small)
                        .disabled(model.isRecording)
                }
            }
            HStack {
                Text("Total").font(.callout)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: ModelStorage.totalBytes(models),
                                               countStyle: .file))
                    .font(.callout).monospacedDigit()
            }
            Text("Said keeps two transcription engines plus whatever optional models you've enabled. "
                 + "Deleting one reclaims the space; anything still needed is downloaded again on next "
                 + "use, unless \"Never download models\" is on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        Button("Refresh") { reload() }.controlSize(.small)

        Divider()

        Toggle("Never download models", isOn: $model.neverDownloadModels)
        Text("Refuses every model download outright, so Said cannot reach the network for one. Models "
             + "already on this Mac keep working normally — this stops fetching, not using. Turn it on "
             + "once everything you need is downloaded and the app is provably offline.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        // The panel's own state is only refreshed on appear and on demand: walking the model
        // directories is real disk work, and this is a settings pane, not a live monitor.
        Color.clear.frame(height: 0).onAppear { reload() }
            .confirmationDialog("Delete \(pendingDelete?.name ?? "")?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let m = pendingDelete { try? ModelStorage.delete(m); reload() }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete.map { m in
                    isRequired(m)
                        ? "This model is needed by your current settings. The next recording will "
                          + "download it again — or fail, if \"Never download models\" is on."
                        : "Reclaims \(m.displaySize)."
                } ?? "")
            }
    }

    private func isRequired(_ m: InstalledModel) -> Bool {
        ModelStorage.isRequired(m,
                                enginePreference: model.enginePreference,
                                whisperVariant: model.model.rawValue,
                                diarizationEnabled: model.diarizationEnabled,
                                vocabularyBiasActive: !model.effectiveVocabulary.isEmpty)
    }

    private func reload() {
        loading = true
        Task.detached(priority: .utility) {
            let found = ModelStorage.inventory()
            await MainActor.run { models = found; loading = false }
        }
    }
}

// MARK: - Voices (cross-session speaker identity)

struct VoicesSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var voices: [Voiceprint] = []
    @State private var pending: [Voiceprint] = []
    @State private var confirmClearAll = false

    var body: some View {
        Toggle("Recognise speakers across sessions", isOn: $model.voiceprintsEnabled)
            .disabled(!model.diarizationEnabled)

        if !model.diarizationEnabled {
            Text("Needs \"Identify speakers\" above — the voice profiles are built from the same "
                 + "on-device pass that labels who spoke when.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("After you name a speaker once, Said can suggest the same name in later recordings. "
                 + "It always asks before applying one — it never assumes. The voice profiles are "
                 + "stored only on this Mac, are never included in a shared session unless you tick "
                 + "the box when sharing, and can be deleted below at any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        if !pending.isEmpty {
            Divider()
            Label("\(pending.count) voice profile(s) arrived with a shared session",
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
            Text("Keeping them lets Said recognise \(pending.map(\.name).joined(separator: ", ")) in "
                 + "your own recordings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep") { VoiceprintStore.acceptPending(); reload() }
                Button("Discard", role: .destructive) { VoiceprintStore.discardPending(); reload() }
            }
            .controlSize(.small)
        }

        if voices.isEmpty {
            Text("No voices saved yet.").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(voices) { v in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name).font(.callout)
                        Text("\(v.embeddings.count) sample(s) · \(v.sessionCount) session(s)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        VoiceprintStore.delete(id: v.id); reload()
                    }
                    .controlSize(.small)
                }
            }
            Button("Delete all voices", role: .destructive) { confirmClearAll = true }
                .controlSize(.small)
        }

        Color.clear.frame(height: 0).onAppear { reload() }
            .confirmationDialog("Delete every saved voice?", isPresented: $confirmClearAll) {
                Button("Delete all", role: .destructive) { VoiceprintStore.deleteAll(); reload() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Immediate and complete. Existing transcripts keep the names you already gave "
                     + "them; only the ability to recognise these voices again is removed.")
            }
    }

    private func reload() {
        voices = VoiceprintStore.all()
        pending = VoiceprintStore.pending()
    }
}

// MARK: - Learned terms

struct LearnedTermsSection: View {
    @State private var terms: [LearnedCorrection] = []
    @State private var confirmClearAll = false

    var body: some View {
        if terms.isEmpty {
            Text("Nothing learned yet. Correct the same word twice in the Session Viewer and Said "
                 + "will start listening for it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(terms) { t in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.right).font(.callout)
                        Text("heard as “\(t.wrong)” · corrected \(t.count)×")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { CorrectionMemory.delete(t); reload() }.controlSize(.small)
                }
            }
            Button("Forget all", role: .destructive) { confirmClearAll = true }.controlSize(.small)
        }
        Text("These terms bias what Said listens for in future recordings. They are never used to "
             + "rewrite a transcript — not this one, not an old one. A word only changes when the "
             + "recording actually contained it.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Color.clear.frame(height: 0).onAppear { reload() }
            .confirmationDialog("Forget every learned term?", isPresented: $confirmClearAll) {
                Button("Forget all", role: .destructive) { CorrectionMemory.clearAll(); reload() }
                Button("Cancel", role: .cancel) { }
            }
    }

    private func reload() { terms = CorrectionMemory.all() }
}

// MARK: - Semantic search

struct SemanticSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var building = false
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var stats: (sessions: Int, chunks: Int) = (0, 0)

    var body: some View {
        Toggle("Search by meaning as well as by words", isOn: $model.semanticSearchEnabled)
        Text("Finds a session from a paraphrase — ask about \"pricing\" and reach a meeting that only "
             + "ever said \"what we're going to charge\". Keyword search keeps working exactly as it "
             + "does now; the two are combined, so exact names and numbers stay precise. Needs a "
             + "one-time on-device language model from Apple, and Said then keeps an index of your "
             + "transcripts that it updates as you record.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        if model.semanticSearchEnabled {
            if building {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    Text("Indexing \(progress.done) of \(progress.total) sessions…").font(.caption)
                }
            } else {
                HStack {
                    Text("\(stats.sessions) session(s) indexed · \(stats.chunks) passage(s)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Index all sessions") { build() }.controlSize(.small)
                }
            }
            if SessionIO.isEncryptionEnabled {
                Label("Encryption is on, so the index is kept in memory only and is rebuilt each "
                      + "launch. No vectors are written to disk.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Color.clear.frame(height: 0).onAppear { refreshStats() }
    }

    private func refreshStats() {
        stats = (SemanticIndex.shared.indexedSessionCount, SemanticIndex.shared.indexedChunkCount)
    }

    private func build() {
        building = true
        Task {
            await SemanticIndex.shared.rebuildFromDisk(progress: { done, total in
                Task { @MainActor in progress = (done, total) }
            })
            await MainActor.run { building = false; refreshStats() }
        }
    }
}
