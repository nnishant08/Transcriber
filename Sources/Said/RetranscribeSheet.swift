import SwiftUI
import SaidKit

/// **The one and only re-transcribe entry point** (Phase 3, §4.5).
///
/// Three places in the build wanted the same capability — backfilling word timings on an old
/// session, recovering from a wrong engine choice, and re-running after a language misdetection —
/// and they are all the same action. Building three variants would have meant three sets of
/// warnings to keep in step and three chances to forget one. There is one command, in the Viewer's
/// Export menu, and it never runs automatically or on more than the session in front of the user.
struct RetranscribeSheet: View {
    @ObservedObject var lib: SessionViewerModel
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var choice: EnginePreference = .automatic
    @State private var whisperVariant: WhisperModel = .baseEn
    @State private var running = false
    @State private var status = ""
    @State private var failure: String?

    private var hasEdits: Bool { lib.hasEdits }
    private var hasGenerated: Bool {
        !lib.meta.summaries.isEmpty || !(lib.meta.generatedArtifacts?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-transcribe this session").font(Theme.ui(15, weight: .semibold))

            Text("Runs the audio through transcription again and replaces the transcript. The "
                 + "recording itself is untouched.")
                .font(Theme.ui(12)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Engine", selection: $choice) {
                Text("Automatic").tag(EnginePreference.automatic)
                Text("Parakeet").tag(EnginePreference.parakeet)
                Text("Whisper").tag(EnginePreference.whisper)
            }
            .pickerStyle(.segmented)

            if choice != .parakeet {
                Picker("Whisper model", selection: $whisperVariant) {
                    ForEach(WhisperModel.allCases) { m in Text(m.label).tag(m) }
                }
            }
            Text(choice.explanation)
                .font(Theme.ui(11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)

            if let engine = lib.meta.engineLabel {
                Text("This transcript was made with \(engine).")
                    .font(Theme.ui(11)).foregroundStyle(Theme.text3)
            }

            // The warnings. Stated BEFORE running, because none of them can be undone afterwards.
            if hasEdits {
                warning("Your \(lib.edits.count) correction(s) will probably stop matching.",
                        detail: "Re-transcribing changes where lines begin and end, so corrections "
                              + "anchored to the old wording will no longer line up. They are kept in "
                              + "the session, not deleted, and the Viewer will tell you how many came "
                              + "loose — but they will stop taking effect. Export the current version "
                              + "first if you want to keep it.")
            }
            if hasGenerated {
                warning("Summaries and generated documents will be marked out of date.",
                        detail: "They are kept and not regenerated automatically — re-run the ones "
                              + "you still want.")
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Theme.ui(11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(Theme.ui(11)).foregroundStyle(Theme.text2)
                }
            }

            HStack {
                if hasEdits {
                    Button("Export current version first") { lib.exportText() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Re-transcribe") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { whisperVariant = model.model }
    }

    private func warning(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(Theme.ui(12, weight: .medium)).foregroundStyle(.orange)
            Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private func run() {
        running = true
        failure = nil
        let dir = lib.dir
        let preference = choice
        let variant = whisperVariant.rawValue
        let language = lib.meta.language
        let vocabulary = model.effectiveVocabulary

        Task {
            do {
                try await Retranscriber.run(dir: dir, preference: preference,
                                            whisperVariant: variant, language: language,
                                            vocabulary: vocabulary) { msg in
                    Task { @MainActor in status = msg }
                }
                await MainActor.run {
                    running = false
                    lib.reload()
                    lib.reloadEdits()
                    if hasGenerated { lib.summariesAreStale = true }
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    running = false
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

/// Re-runs transcription over a saved session's audio and replaces its transcript.
///
/// Kept out of `Importer` on purpose even though the two look similar: an import CREATES a session
/// from a file the user chose, this REPLACES the transcript of a session that already exists and has
/// a history — bookmarks, speaker names, edits, an id. Sharing one code path would have meant one of
/// them quietly doing the wrong thing to the other's invariants.
enum Retranscriber {

    enum Failure: LocalizedError {
        case noAudio
        var errorDescription: String? {
            "This session has no saved audio, so it can't be transcribed again. "
            + "(Audio is saved only when \"Save source audio\" was on at the time.)"
        }
    }

    static func run(dir: URL, preference: EnginePreference, whisperVariant: String,
                    language: String?, vocabulary: [String],
                    progress: @escaping @Sendable (String) -> Void) async throws {
        guard let doc = DocumentBuilder.readSession(dir) else { throw Failure.noAudio }
        guard let audioName = doc.meta.audioFile else { throw Failure.noAudio }
        let audioURL = dir.appendingPathComponent(audioName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { throw Failure.noAudio }

        progress("Decoding audio…")
        let samples = try await AudioFileIO.decodeTo16kMono(url: audioURL)
        guard !samples.isEmpty else { throw Failure.noAudio }

        let engine = TranscriptionEngine()
        progress("Loading model…")
        let decision = try await engine.prepare(preference: preference, language: language,
                                                whisperVariant: whisperVariant) { msg, _ in progress(msg) }

        progress("Transcribing with \(decision.engine.displayName)…")
        let bias = VocabularyBias(terms: vocabulary)
        let segments = try await engine.transcribeSamples(samples, language: language, bias: bias)
        guard !segments.isEmpty else { return }

        // Merge onto a FRESH read and keep every field the session already owned — the id, the
        // bookmarks, the speaker names, the title. Only the words and the engine record change.
        guard var fresh = DocumentBuilder.readSession(dir) else { return }
        fresh.segments = segments
        fresh.meta.engine = decision.engine.rawValue
        fresh.meta.engineModel = engine.activeModelName
        // Speaker labels described the OLD segmentation; carrying them onto new boundaries would
        // attribute words to whoever happened to hold the same index. Diarization can be re-run.
        fresh.meta.speakerCount = nil
        DocumentBuilder.writeSession(fresh, to: dir)

        SearchIndex.shared.index(sessionDir: dir)
        await SemanticIndex.shared.index(sessionDir: dir)
        SessionStore.postSessionSaved(dir)
        progress("Done.")
    }
}

// MARK: - Voiceprint proposals

/// "This might be Alice — confirm?"
///
/// **A match is a proposal, never an assignment** (§7.4). This is the entire user-facing surface of
/// that rule: nothing is named until someone presses a button here, and an ambiguous match offers
/// the candidates rather than the closest one.
struct VoiceprintProposalBar: View {
    @ObservedObject var lib: SessionViewerModel

    var body: some View {
        if let proposals = lib.meta.voiceprintProposals, !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(proposals, id: \.slot) { p in
                    HStack(spacing: 10) {
                        Circle().fill(Theme.speakerColor(p.slot)).frame(width: 8, height: 8)
                        if p.isAmbiguous {
                            Text("Speaker \(p.slot) could be \(p.alternatives.joined(separator: " or "))")
                                .font(Theme.ui(12))
                        } else {
                            Text("Speaker \(p.slot) might be \(p.name)").font(Theme.ui(12))
                        }
                        Spacer()
                        if p.isAmbiguous {
                            ForEach(p.alternatives, id: \.self) { name in
                                Button(name) { lib.acceptVoiceprint(slot: p.slot, name: name) }
                                    .controlSize(.small)
                            }
                        } else {
                            Button("Yes, \(p.name)") { lib.acceptVoiceprint(slot: p.slot, name: p.name) }
                                .controlSize(.small)
                        }
                        Button("Not them") { lib.rejectVoiceprint(slot: p.slot) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
            .padding(.bottom, 12)
        }
    }
}

extension SessionViewerModel {

    /// Accept a proposed identity: name the speaker for this session, and add this session's voice
    /// samples to that person's profile so future matching improves.
    func acceptVoiceprint(slot: Int, name: String) {
        renameSpeaker(slot: slot, to: name)
        dismissProposal(slot: slot)
    }

    /// Decline. The proposal goes away and nothing is learned from it — in particular the rejected
    /// voiceprint is NOT updated, because a "no" is evidence that these are different people and
    /// folding the samples in would make the next match worse, not better.
    func rejectVoiceprint(slot: Int) {
        dismissProposal(slot: slot)
    }

    private func dismissProposal(slot: Int) {
        var remaining = (meta.voiceprintProposals ?? []).filter { $0.slot != slot }
        if remaining.isEmpty { remaining = [] }
        meta.voiceprintProposals = remaining.isEmpty ? nil : remaining
        if var doc = DocumentBuilder.readSession(dir) {
            doc.meta.voiceprintProposals = meta.voiceprintProposals
            DocumentBuilder.writeSessionJSON(doc, to: dir)
        }
        objectWillChange.send()
    }
}
