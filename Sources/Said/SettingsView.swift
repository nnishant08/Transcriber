import SaidKit
import SwiftUI
import AppKit
import KeyboardShortcuts

/// Sheet state for the custom-summary-mode editor (nil = closed; `originalName` nil = adding new).
private struct ModeEditorState: Identifiable {
    var originalName: String?
    var name: String
    var instructions: String
    var id: String { originalName ?? "<new>" }

    init() { originalName = nil; name = ""; instructions = "" }
    init(editing mode: CustomSummaryMode) {
        originalName = mode.name; name = mode.name; instructions = mode.instructions
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State fileprivate var modeEditor: ModeEditorState?

    /// Extracted from `body` verbatim — same controls, same order, same modifiers. Once SaidKit
    /// became a separate module the type-checker could no longer solve this Section inline within
    /// its budget ("unable to type-check this expression in reasonable time"); pulling it into its
    /// own `@ViewBuilder` gives the solver a fresh, small problem. Presentation is unchanged.
    @ViewBuilder
    private var audioAndAccuracySection: some View {
        Toggle("Capture system audio at the audio engine (recommended)", isOn: $model.useProcessTap)
        Text("Uses a Core Audio process tap, so every app is heard regardless of window, "
             + "display, output device (speakers / headphones / external), volume, or mute. "
             + "Turn off to use the older ScreenCaptureKit path, which only hears apps with a "
             + "window on the captured display. Requires macOS 14.2+; screen recording always "
             + "uses its own ScreenCaptureKit video stream.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Auto-pause when there's no audio", isOn: $model.autoPauseEnabled)
        if model.autoPauseEnabled {
            Stepper(value: $model.autoPauseSeconds, in: 5...600, step: 5) {
                Text("Pause after \(Int(model.autoPauseSeconds)) s of silence")
            }
        }
        Text("Recording pauses itself after a silent stretch and resumes automatically the "
             + "moment sound returns (with a short pre-roll, so the first word isn't clipped). "
             + "Handy when a call is muted, a video is paused, or a meeting takes a break — "
             + "the silence never reaches the transcript. A pause you trigger yourself (⌥⌘P) "
             + "stays paused until you resume it.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Save source audio with each session (enables playback)", isOn: $model.saveAudioEnabled)
        Text("Saves a compact 16 kHz AAC file in the session folder so the Viewer can play it back and you can click a line to seek. ~0.5 MB/minute.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 4) {
            Text("Custom vocabulary").font(.callout)
            TextField("Names, acronyms, jargon — comma-separated", text: vocabText, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            Text("Biases transcription toward these terms in both live and final passes. Empty = no change.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        Form {
            Section("Global Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Pause / resume:", name: .togglePause)
                KeyboardShortcuts.Recorder("Add bookmark:", name: .addBookmark)
                Text("Work from any app. Pause (⌥⌘P) holds the session open and stops recording — paused time is left out of the audio and the transcript. Bookmark (⌥⌘B) drops a marker at the current moment while recording; markers show in the Session Viewer. Carbon hotkeys need no permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Model") {
                Picker("Model", selection: $model.model) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .disabled(model.isRecording || model.status.isBusyPreparing)

                Text("Larger models are more accurate but slower. base.en / small.en are best for real-time. The model downloads once on first use, then runs fully offline. Changing the model applies on the next Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Language") {
                Picker("Transcription language", selection: $model.transcriptionLanguage) {
                    ForEach(AppModel.languageOptions, id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .disabled(!model.model.isMultilingual || model.isRecording || model.status.isBusyPreparing)

                if !model.model.isMultilingual {
                    if model.transcriptionLanguage != "en" {
                        // A non-English language is stored but the active model can't honor it.
                        // Guide a model switch — never silently produce wrong-language output.
                        HStack(alignment: .firstTextBaseline) {
                            Label("English-only model selected — sessions will transcribe in English.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Use \(model.model.multilingualSibling.shortName)") {
                                model.model = model.model.multilingualSibling
                            }
                            .controlSize(.small)
                            .disabled(model.isRecording || model.status.isBusyPreparing)
                        }
                    } else {
                        Text("English-only model selected — switch to a multilingual model (base, small, or large-v3-turbo) to change language.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Auto-detect listens to the first few seconds, then locks one language for the whole session (live + final pass). 100% on-device.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Speakers") {
                Toggle("Identify speakers (on-device)", isOn: $model.diarizationEnabled)
                Text("Labels who spoke when (“Speaker 1, 2…”) after each session finishes — fully on-device (FluidAudio CoreML). First use downloads a small speaker model once, then works offline. Rename speakers per session in the Session Viewer.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Source") {
                Picker("Audio source", selection: $model.source) {
                    ForEach(AudioSource.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRecording)
                Text("System Audio requires the Screen Recording permission. “Mic + System” captures both at once (e.g. a call), mixed into one transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Audio & accuracy") { audioAndAccuracySection }

            Section("Intelligence") {
                Picker("Default summary style", selection: $model.defaultSummaryStyle) {
                    ForEach(SummaryStyle.allCases) { Text($0.label).tag($0) }
                }
                Text("Chat, Ask, and summaries run 100% on-device via Apple Intelligence. They degrade gracefully when it's unavailable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Toggle("Clean up transcript (remove fillers, fix punctuation)", isOn: $model.cleanupEnabled)
                Text("Adds an on-device cleaned VIEW per session — fillers and false starts removed, punctuation fixed, timestamps untouched. The saved transcript stays verbatim; switch views in the Session Viewer.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Custom summary modes").font(.callout)
                        Spacer()
                        Button("Add…") { modeEditor = ModeEditorState() }.controlSize(.small)
                    }
                    ForEach(model.customSummaryModes) { mode in
                        HStack {
                            Text(mode.name).font(.callout)
                            Spacer()
                            Button("Edit") { modeEditor = ModeEditorState(editing: mode) }.controlSize(.small)
                            Button(role: .destructive) {
                                model.customSummaryModes.removeAll { $0.name == mode.name }
                            } label: { Image(systemName: "trash") }.controlSize(.small)
                        }
                    }
                    Text("Your own named summary templates (e.g. “Meeting minutes — decisions, owners, deadlines”). They appear alongside TL;DR / Detailed / Executive in the Session Viewer.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Vertical packs") {
                Text("Domain bundles that add curated vocabulary (for accuracy) and surface matching Generation Studio templates. Enable any combination — their vocabulary unions with yours. 100% on-device.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(PackManager.shared.availablePacks) { pack in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(
                            get: { model.enabledPackIDs.contains(pack.id) },
                            set: { on in
                                var set = model.enabledPackIDs
                                if on { set.insert(pack.id) } else { set.remove(pack.id) }
                                model.enabledPackIDs = set
                            })) {
                            Text(pack.name).font(.callout)
                        }
                        Text(pack.description)
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(pack.vocabulary.count) vocab terms · \(pack.templateIds.count) templates")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if PackManager.shared.availablePacks.isEmpty {
                    Text("No packs are bundled.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Privacy & Compliance") {
                privacyStatement

                Toggle("Auto-delete old sessions", isOn: Binding(
                    get: { model.retentionPolicy.autoDeleteEnabled },
                    set: { model.retentionPolicy.autoDeleteEnabled = $0 }))
                if model.retentionPolicy.autoDeleteEnabled {
                    Stepper(value: Binding(get: { model.retentionPolicy.maxAgeDays },
                                           set: { model.retentionPolicy.maxAgeDays = $0 }), in: 1...3650, step: 1) {
                        Text("Delete after \(model.retentionPolicy.maxAgeDays) days")
                    }
                    Toggle("Delete only the audio (keep transcripts)", isOn: Binding(
                        get: { model.retentionPolicy.deleteAudioOnly },
                        set: { model.retentionPolicy.deleteAudioOnly = $0 }))
                }
                Text("Sessions older than the limit move to the Trash on launch (never a hard delete). Mark any session “Keep” in the Session Viewer to exempt it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Delete all saved audio") { confirm("Delete all saved audio?", "Transcripts are kept. Audio files move to the Trash.") { model.purgeAllAudio() } }
                        .controlSize(.small)
                    Spacer()
                    Button("Delete older than \(model.retentionPolicy.maxAgeDays) days") {
                        confirm("Delete old transcripts?", "Sessions older than \(model.retentionPolicy.maxAgeDays) days (except kept ones) move to the Trash.") {
                            model.purgeOlderThan(days: model.retentionPolicy.maxAgeDays)
                        }
                    }.controlSize(.small)
                }

                Text("On-device redaction (mask names, emails, phone numbers, etc.) is per session — open a session and tap “Redact”. The saved transcript always stays verbatim.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Toggle("Encrypt stored sessions (at rest)", isOn: Binding(
                    get: { model.encryptionEnabled },
                    set: { model.setEncryption($0) }))
                    .disabled(model.encryptionBusy || model.isRecording)
                if model.encryptionEnabled {
                    Toggle("Require Touch ID to unlock", isOn: $model.encryptionRequireTouchID)
                }
                if model.encryptionBusy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.encryptionStatus ?? "Working…").font(.caption) }
                } else if let s = model.encryptionStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                Text("AES-GCM with a key stored in your Keychain. Transcripts, metadata, audio, and slides are encrypted on disk; everything decrypts transparently in the app. Search runs in memory only while encrypted (no plaintext cache). Enabling/disabling migrates existing sessions safely (one-time backup first).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Calendar-aware capture") {
                Toggle("Detect meetings from my calendar", isOn: $model.calendarCaptureEnabled)
                if model.calendarCaptureEnabled {
                    Picker("When a meeting starts", selection: $model.calendarAutoStart) {
                        Text("Prompt me").tag(false)
                        Text("Auto-start recording").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Capture source", selection: $model.calendarCaptureSource) {
                        Text("System Audio").tag(AudioSource.systemAudio)
                        Text("Mic + System").tag(AudioSource.micPlusSystem)
                    }
                    Stepper(value: $model.calendarLeadSeconds, in: 0...600, step: 30) {
                        Text(model.calendarLeadSeconds <= 0 ? "Fire at meeting start"
                             : "Fire \(Int(model.calendarLeadSeconds / 60)) min \(Int(model.calendarLeadSeconds.truncatingRemainder(dividingBy: 60))) s before start")
                    }
                }
                Text("Bot-free: nothing joins your call. When a calendar event with a video-meeting link (Zoom, Teams, Meet, Webex, Whereby) starts, Said offers — or auto-starts — a local system-audio recording. Your calendar is read on-device only; needs the optional Calendar permission.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Sharing") {
                HStack {
                    Text(model.obsidianVaultPath.isEmpty ? "No Obsidian vault folder set"
                         : (model.obsidianVaultPath as NSString).abbreviatingWithTildeInPath)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !model.obsidianVaultPath.isEmpty { Button("Clear") { model.obsidianVaultPath = "" }.controlSize(.small) }
                    Button("Choose…") { chooseVault() }.controlSize(.small)
                }
                Text("“Send to Obsidian” in the Viewer writes a markdown note into this folder. Other apps (Notes, Mail…) use the system share sheet — no extra permission.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Screen Recording") {
                Toggle("Record the screen with every session", isOn: $model.screenRecordingEnabled)
                    .disabled(model.isRecording)

                Toggle("Ask which screen to record each time", isOn: $model.askScreenTargetEachTime)
                    .disabled(model.isRecording)
                Text("With more than one display connected, Said asks before it starts and records the one you pick — so a recording never silently lands on the laptop screen while you're presenting on the monitor. With a single display, or with a window or app chosen below, it doesn't ask.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Picker("Record", selection: $model.screenTarget) {
                    // Ensure the current selection is always representable.
                    if !model.availableTargets.contains(where: { $0.target == model.screenTarget }) {
                        Text("Current").tag(model.screenTarget)
                    }
                    ForEach(model.availableTargets) { opt in
                        Text(opt.label).tag(opt.target)
                    }
                }
                .disabled(model.isRecording)

                HStack {
                    Button("Refresh list") { model.refreshTargets() }
                        .controlSize(.small)
                        .disabled(model.isRecording)
                    Spacer()
                }

                Picker("Quality", selection: $model.screenQuality) {
                    ForEach(ScreenQuality.allCases) { q in Text(q.label).tag(q) }
                }
                .disabled(model.isRecording)

                Picker("Audio for screen recordings", selection: $model.screenAudioSource) {
                    ForEach(AudioSource.allCases) { s in Text(s.label).tag(s) }
                }
                .disabled(model.isRecording)

                KeyboardShortcuts.Recorder("Record screen:", name: .toggleScreenRecording)

                Text("⌥⌘S starts a recording that captures the screen AND the audio in one session — one video, one transcript, one timeline. The video is saved as screen.mp4 in the session folder and plays in the Session Viewer, where clicking any transcript line jumps the video to that moment. Paused time is cut out of both. Uses the same Screen Recording permission as system audio — no new grant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(width: 460)
        .frame(minHeight: 340)
        .onAppear { model.refreshTargets() }
        .sheet(item: $modeEditor) { state in
            ModeEditorSheet(state: state) { result in
                if let result {
                    var modes = model.customSummaryModes
                    if let original = state.originalName {
                        if let i = modes.firstIndex(where: { $0.name == original }) { modes[i] = result }
                        else { modes.append(result) }
                    } else {
                        modes.removeAll { $0.name == result.name }   // replace a same-named mode
                        modes.append(result)
                    }
                    model.customSummaryModes = modes
                }
                modeEditor = nil
            }
        }
    }

    /// The compliance-positioning statement (accurate, non-overstated: privacy by architecture).
    private var privacyStatement: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Everything stays on this Mac", systemImage: "lock.shield").font(.callout)
            Text("No cloud, no account, works offline. Transcription, AI, redaction, and search all run on-device; nothing is uploaded. Sessions live in ~/Desktop/Transcripts. This is privacy by architecture — not a formal certification (e.g. HIPAA); review redacted output before sharing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Retention: \(model.retentionPolicy.autoDeleteEnabled ? "auto-delete after \(model.retentionPolicy.maxAgeDays) days" : "off") · Encryption: \(model.encryptionEnabled ? "on" : "off")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { action() }
    }

    /// Custom-vocabulary list <-> comma/newline-separated text field.
    private var vocabText: Binding<String> {
        Binding(
            get: { model.customVocabulary.joined(separator: ", ") },
            set: { model.customVocabulary = $0.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault Folder"
        if panel.runModal() == .OK, let url = panel.url { model.obsidianVaultPath = url.path }
    }
}

/// Editor sheet for one custom summary mode. `done(nil)` = cancelled.
private struct ModeEditorSheet: View {
    let state: ModeEditorState
    let done: (CustomSummaryMode?) -> Void
    @State private var name: String
    @State private var instructions: String

    init(state: ModeEditorState, done: @escaping (CustomSummaryMode?) -> Void) {
        self.state = state
        self.done = done
        _name = State(initialValue: state.name)
        _instructions = State(initialValue: state.instructions)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.originalName == nil ? "New summary mode" : "Edit summary mode")
                .font(.headline)
            TextField("Name (e.g. Meeting minutes)", text: $name)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $instructions)
                    .font(.system(size: 12.5))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            }
            Text("Tell the on-device model exactly what to produce, e.g. “List decisions, owners, and deadlines as bullets, then open questions.” An empty template won't run.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                Button("Save") {
                    done(CustomSummaryMode(name: name.trimmingCharacters(in: .whitespaces),
                                           instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
