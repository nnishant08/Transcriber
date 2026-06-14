# Transcriber

A macOS app for live, **100% on-device** speech-to-text. A global hotkey (⌥⌘T) toggles recording;
audio comes from the **microphone**, **system audio**, or **both at once** (switchable). Live text
streams into a floating window; on stop the transcript is saved to `~/Desktop/Transcripts/` as a
timestamped session folder, then replaced by a full-quality re-transcription (and the source audio is
saved for playback). On-device **Apple Intelligence** powers summaries, **chat with a session**, and
**Ask across all sessions** — all cite/link back to `[mm:ss]`. A **Library** browses + full-text-searches
every session; the **Session Viewer** plays the audio with clickable transcript lines, bookmarks,
summary, and chat. You can **import** audio/video files, add live **bookmarks** (⌥⌘B), bias accuracy
with a **custom vocabulary**, and export to SRT/VTT/TXT/RTF/HTML/PDF or share to Notes/Obsidian. With
**Visual Capture** on, a session also captures slides/video frames, OCRs them on-device, and interleaves
them on the timeline. **Speaker diarization** labels who spoke when (renameable, color-coded, fully
on-device via FluidAudio). Transcription is **multilingual** (explicit language or auto-detect-once).
**Calendar-aware capture** offers (or auto-starts) a bot-free local recording when a video-meeting event
begins. An optional on-device **cleanup** view removes fillers/fixes punctuation (verbatim stays
canonical), and users can author **custom summary modes**. Shows in both the **Dock** and the **menu
bar**. **Everything stays on this Mac — no cloud, no account, works offline.**

> Status: two feature waves shipped & verified (unified store/Library/search; chat & intelligence,
> capture coverage, output & accuracy, UX & trust), plus **Stage 1** (diarization / multilingual /
> calendar capture / cleanup + custom modes) built & self-tested, awaiting human smoke-tests.
> The user iterates with Claude from here.

## User guide reference (SOURCE for info sheets / user instructions / quick-starts / FAQs)
**When asked to produce any USER-FACING material (one-pager, quick-start, how-to, keyboard-shortcut card,
feature sheet, FAQ, release notes), build it from THIS section** — it's the plain-English capability map.
(The sections below it are engineering detail.) Everything is on-device; never describe a cloud/online step.

**What it is.** A private, on-device live transcription app for macOS (Apple Silicon, macOS 14+; on-device
AI requires macOS 26 + Apple Intelligence). Nothing leaves the Mac.

**Speakers (who said what)** — turn on *Identify speakers* in Settings and each finished session gets
"Speaker 1 / Speaker 2…" labels on the timeline, color-coded in the Session Viewer. Click a speaker chip
to **rename** them for that session (e.g. "Alice"); renames persist and are searchable. Fully on-device
(a small speaker model downloads once, then offline). Off by default.

**Languages** — with a multilingual model (*base*, *small*, or *large-v3-turbo*) pick an explicit
language (Spanish, French, German, Japanese, …) or **Auto-detect**, which listens to the first few
seconds and locks one language for the whole session. The `*.en` models stay English-only and the UI
guides a model switch rather than producing wrong-language output.

**Calendar-aware capture (bot-free)** — optional: Transcriber watches your calendar (read on-device
only) for events with a video-meeting link (Zoom, Teams, Meet, Webex, Whereby) and either **prompts**
you ("Meeting starting — record?") or **auto-starts** a local recording at your lead time. No bot joins
the call — it's just local system-audio capture; the meeting title becomes the session title.

**Cleaned view & custom summaries** — optionally store an on-device **cleaned** version of each
transcript (fillers removed, punctuation fixed; timestamps intact). The Viewer has a Verbatim/Cleaned
switch — **Verbatim is always the default and the saved transcript is never altered.** You can also
author **custom summary modes** (e.g. "Meeting minutes") in Settings; they appear next to the built-in
styles and cache per session.

**Recording (the core loop)**
- Pick a **source** — *Mic*, *System Audio*, or *Mic + System* (toolbar segmented control or Settings).
  "System Audio" transcribes whatever is playing (calls, videos); "Mic + System" mixes both (e.g. a full
  call with your voice + theirs).
- **Start/Stop** with **⌥⌘T** from any app, or the big record button.
- Live text shows **confirmed** words solid + the **in-progress** tail dimmed with a caret.
- On **Stop**: the session is saved to `~/Desktop/Transcripts/<date-time>/` (a folder with `transcript.md`
  + `session.json`), a full-quality pass cleans it up, and the **source audio is saved** (`audio.m4a`,
  toggle in Settings, default on) for playback.

**Live bookmarks** — press **⌥⌘B** while recording to drop a marker at the current moment; markers appear
as jump points in the Session Viewer.

**Library** (menu bar ▸ *Open Library*, or the books icon) — lists every session newest-first with title,
date, source, tags, and a snippet. **Search** transcripts + slide text (keyword, ranked, with `[mm:ss]`
snippets). Filter by **tag** or **date range**. Per row: **Open** (Session Viewer), **Reveal in Finder**,
**Delete** (to Trash). Also **Ask** and **Import…** buttons.

**Session Viewer** (Open a session from the Library) — one window with:
- the **timestamped transcript** — click any line to **play/seek** the audio there;
- an **audio player** (play/pause/scrub) when audio was saved;
- **bookmarks** + **chapters** as clickable jump points;
- a **Summary** panel — switch styles **TL;DR / Detailed notes / Executive**, plus auto **action items**;
- a **Chat** panel — ask questions about that session; answers cite a clickable `[mm:ss]`;
- **Export / Share** (see below).

**On-device AI (Apple Intelligence)** — *Summarize* (3 styles), *Chat with a session* (grounded, cites
`[mm:ss]`), *Ask across all sessions* (menu bar / Library — answers link back to the source sessions),
and automatic **titles + tags**. If Apple Intelligence is off/unavailable, these disable or fall back
cleanly (search still works; Ask still lists matching sessions).

**Import** — drag an **audio or video** file (`.mp3 .m4a .wav .mp4 .mov`) onto the window or the Dock icon,
or use Library ▸ *Import…*. It transcribes into a full session; video files also sample + OCR frames.

**Accuracy — custom vocabulary** — add names/acronyms/jargon in Settings; they bias transcription (live and
final). Empty = no change.

**Export & share** — from the Session Viewer's **Export** menu: subtitles **SRT/VTT**, **TXT**, **RTF**
(opens in Word/Pages), **HTML**, **PDF**; **Share…** (system share sheet → Notes, Mail, Messages, AirDrop…);
**Send to Obsidian vault** (set the vault folder in Settings). Copy is available on the summary.

**Visual Capture** (Settings toggle, off by default) — capture slides/screens alongside audio. Modes:
*On change* (one clean frame per slide), *Every N seconds* (video), *Manual only*. **⌥⌘S** force-grabs a
frame anytime. Frames are OCR'd on-device and interleaved with the transcript; export to a single HTML/PDF.

**Keyboard shortcuts** (all configurable in Settings): **⌥⌘T** start/stop recording · **⌥⌘B** add bookmark ·
**⌥⌘S** grab a visual frame. They work globally (from any app).

**Permissions** (first-run onboarding walks these): **Microphone** (for mic / both) · **Screen Recording**
(for system audio + visual — *quit & relaunch* after granting) · **Notifications** (optional — a heads-up
when a long transcription / summary / import finishes; degrades silently if denied).

**Where things live** — sessions in `~/Desktop/Transcripts/<date-time>/`. Each folder is self-contained and
movable (`transcript.md` + `session.json` [+ `audio.m4a` / `source.*` for playback] [+ `images/` if visual]).

**Models** — WhisperKit, on-device: *base.en* (fastest, real-time), *small.en* (balanced), *base* /
*small* (multilingual siblings), *large-v3-turbo* (most accurate, multilingual). Chosen in Settings;
downloads once, then fully offline. The speaker model (FluidAudio) also downloads once, anonymously.

**Good for** — lectures & classes, meetings & standups, calls (Mic + System), interviews, podcasts/videos
(import), voice notes; then summarize, search across everything, or chat to recall details.

**Limits to mention honestly** — on-device AI features need macOS 26 + Apple Intelligence; system audio needs
the Screen Recording grant (and a relaunch after granting); non-English transcription needs a multilingual
model selected; calendar capture needs the optional Calendar grant; speaker names don't carry across sessions
(per-session rename only — cross-session voiceprints are a future build); attaching slide *images* to chat is
a future macOS-27 capability (today chat uses the transcript + OCR'd slide text).

## Target & stack
- Apple Silicon, **macOS 14+ deployment target** (raised from 13 in Stage 1 — FluidAudio's platform
  floor is macOS 14; the app is built & run on macOS 26, so the bump is functionally harmless).
  SwiftUI + AppKit. NOTE: the floor bump surfaced `onChange(of:perform:)` deprecation WARNINGS in
  pre-existing view code — left as-is on purpose (presentation files are non-regression territory).
- Built with **Swift Package Manager** — there is **no selected Xcode**, only Command Line Tools, but
  full **Xcode IS installed** at `/Applications/Xcode.app`. `Scripts/build_app.sh` points the build at
  it via `DEVELOPER_DIR` (needed because a dependency uses the `#Preview` macro plugin from Xcode).
- On-device STT: **WhisperKit** (Argmax, CoreML). Model downloads once (~150 MB for base.en), then offline.
- On-device speaker diarization: **FluidAudio 0.15.2** (FluidInference; Pyannote segmentation +
  WeSpeaker embeddings, CoreML/ANE; zero transitive package deps). Models download once, anonymously.
- Meeting detection: **EventKit** (system framework, no SPM entry; optional Calendar permission).
- Global hotkey: **KeyboardShortcuts** (sindresorhus).
- System audio: **ScreenCaptureKit**. Microphone: **AVAudioEngine**.
- On-device AI summary: Apple **FoundationModels** (Apple Intelligence, macOS 26).
- App Sandbox **disabled** (personal tool — avoids entitlement friction for TCC + audio).

## Build & run
```sh
Scripts/setup_signing.sh      # ONCE: create the stable self-signed identity (so TCC grants persist)
Scripts/make_icon.sh          # ONCE (or when changing the icon): regenerate Resources/AppIcon.icns
Scripts/build_app.sh          # swift build -c release, assemble + sign + de-quarantine Transcriber.app
open ./Transcriber.app        # or run ./Transcriber.app/Contents/MacOS/Transcriber to see logs
```
- After `open`, allow **~1–2 s** for LaunchServices; the Transcript window opens on launch.
- **Fully Quit before relaunching** (menu-bar ▸ Quit, or `pkill -f Transcriber.app`) — otherwise `open`
  just re-activates the running instance instead of starting fresh.
- Pinned exact dependency versions live in `Package.swift`. WhisperKit/KeyboardShortcuts APIs drift
  across versions — read the pinned tag's source before changing API calls.

## Source map (Sources/Transcriber/)
- `Main.swift` — `@main AppMain`. Dispatches CLI self-test modes (below) else runs the SwiftUI app.
  Contains `SelfTest` (file / streaming / summary verifiers).
- `TranscriberApp.swift` — `TranscriberApp: App` (a single `MenuBarExtra` scene, `.window` style),
  `MenuBarLabel` (icon reflects recording state), `AppDelegate` (sets `.regular` activation policy,
  runs `AppModel.shared.onLaunch()`, `applicationShouldHandleReopen` reopens window on Dock click,
  logs launch + permission status), and `WindowManager` (NSWindowDelegate; builds the Transcript /
  Settings windows as manual `NSWindow`s and clears refs on close). `debugLog()` writes launch lines.
- `AppModel.swift` — `@MainActor` singleton `AppModel.shared` (`ObservableObject`): `transcript`,
  `isRecording`, `source`, `model`, `status`, `summary`, `isSummarizing`. Owns the start/stop flows,
  the global-hotkey registration, transcript saving, `openTranscriptsFolder()`, `summarizeTranscript()`.
  Enums: `AudioSource`, `WhisperModel`, `EngineStatus`.
- `TranscriptionEngine.swift` — wraps WhisperKit: `prepare(model:progress:)` (download w/ progress +
  load), `transcribeFile()`, `finalPass()` (VAD-chunked full-quality), `makeStreamer()`. Plus the
  `StreamingTranscriber` actor (rolling-window live transcription) and `TranscriptText` cleanup.
- `AudioSupport.swift` — `CaptureError`, `SampleSink` (thread-safe `[Float]` buffer), `Resampler16k`
  (AVAudioConverter → 16 kHz mono Float32), `CMSampleBuffer.asPCMBuffer`.
- `AudioCaptureMic.swift` — AVAudioEngine input tap → `Resampler16k` → `SampleSink`.
- `AudioCaptureSystem.swift` — ScreenCaptureKit `SCStream` (audio + minimal 2×2 video) → `Resampler16k`
  → `SampleSink`. Tries `SCShareableContent` directly to test Screen Recording authorization.
- `Summarizer.swift` — on-device summary via FoundationModels `LanguageModelSession.respond(to:)`,
  with availability checks.
- `MenuContent.swift` — menu-bar popover (status, source picker, Start/Stop, model/source info,
  Open Transcript Window, **Open Library**, Open Transcripts Folder, Settings, Quit).
- `TranscriptWindow.swift` — control surface: source picker + Start/Stop + Settings, status, Summarize,
  **Open Library**, Open Transcripts Folder, Copy, Clear; the AI-summary panel; the auto-scrolling read-only transcript.
- `SettingsView.swift` — `KeyboardShortcuts.Recorder`, model picker, source picker.
- `Shortcuts.swift` — `KeyboardShortcuts.Name.toggleRecording` (⌥⌘T) + `.grabFrame` (⌥⌘S, manual capture).
- `Theme.swift` — design tokens (light/dark adaptive colors via dynamic NSColor, fonts, radii).
- `TranscriptComponents.swift` — toolbar atoms (ToolbarIcon, SourceSegmented, Summarize/Stop buttons,
  KbdView), RecordingTimer, LiveMeter, InviteCanvas (record ring), DownloadingCanvas (progress ring).
- `TranscriptCanvas.swift` — the recording/review transcript (gutter timestamps + serif body, confirmed
  solid + dimmed hypothesis tail + blinking caret, inline FrameCard slides w/ OCR disclosure) + SummaryCanvas.
- `ScreenCapture.swift` — `CaptureTarget`/`CaptureMode`/`CaptureTargetOption` + `VisualCapture`: builds the
  `SCContentFilter` from the chosen target, runs the detector / interval timer / manual grab, writes PNGs
  into the session `images/`, emits `FrameEvent`s. Owns its own video stream (mic case) or ingests frames
  from the shared AudioCaptureSystem stream (system-audio case). All mutable state on one serial `queue`.
- `FrameChangeDetector.swift` — `VisualConstants` (tunables), `dHash`/`hamming`, and the per-slide
  settle state machine for "On change" mode.
- `DocumentBuilder.swift` — `TranscriptSegment`/`FrameEvent`/`SessionMeta`/`SessionDoc`; the T0 timeline
  merge → Markdown and self-contained HTML; session-folder layout; `writeSession`/`readSession`.
  `SessionMeta` carries `title`/`tags`/`schemaVersion` AND (Prompt 2) `audioFile`/`durationSeconds`/
  `bookmarks`/`chapters`/`actionItems`/`summaries`/`imported` — all `decodeIfPresent` so OLD session.json
  still decodes. Defines `Bookmark`/`Chapter`. `writeSessionJSON` writes ONLY session.json (leaves
  transcript.md untouched — used by migration, title backfill, and Viewer artifact caching).
  `makeSessionFolder(date:withImages:)`.
- `SlideOCR.swift` — on-device Vision OCR (`VNRecognizeTextRequest`), batched over saved frames.
- `Exporter.swift` — single-file HTML (base64-embedded images) + PDF (via `WKWebView.createPDF`).
- `SessionStore.swift` — the unified on-disk store. `SessionInfo` (listing row), `allSessions()`,
  `sessionDirectoryURLs()`; markdown→plain-text + snippet + `[mm:ss]` helpers; `ensureTitle(dir:)`
  (on-device title/tag backfill, updates session.json only); `migrateLegacyFlatFiles()` (non-destructive,
  idempotent, backs up first); `TitleBackfill` actor (serial, throttled). Defines `.transcriberSessionSaved`.
- `TitleGenerator.swift` — on-device auto title + ≤5 tags via FoundationModels (same `#available(macOS 26)`
  pattern as `Summarizer`); defensive parse/sanitize (strips markdown-wrapped `**Title:**`/`**Tags:**`
  labels, word-boundary tag cap); `generateTags` (focused tags-only prompt — more reliable than the
  combined title+tags prompt on long inputs); deterministic `fallbackTitle` when AI is unavailable.
- `SearchIndex.swift` — in-app keyword inverted index over each session's `transcript.md` (incl. OCR text).
  `search(_:) -> [SessionHit]` (ranked by match count + recency; snippets carry the nearest `[mm:ss]`);
  `rebuildFromDisk()` (validates vs disk mtimes) + `index(sessionDir:)`/`remove(dir:)`; JSON cache under
  Application Support (fast cold start, correctness always from disk). Thread-safe (`NSLock`), `Sendable`.
- `LibraryWindow.swift` — `LibraryModel` (`@MainActor`) + the Library SwiftUI view: lists sessions newest
  first, tag + date-range filters, full-text search, Open (→ Session Viewer) / Reveal in Finder /
  Delete-to-Trash (`NSWorkspace.recycle`), **Ask** + **Import…**, live-refresh on `.transcriberSessionSaved`.
- `Intelligence.swift` (Prompt 2) — on-device chat/ask/summary via FoundationModels (text-only; reuses
  `Summarizer` guards). `answerForSession` (A1, grounded, cites `[mm:ss]`), `ask` (A2, retrieves via
  `SearchIndex` → `AskResult{text,sources}`), `summarize(style:)`/`actionItems`/`chapters` (A3),
  `SummaryStyle`, `ChatTurn`. Single `run(instructions:prompt:)` wraps `LanguageModelSession.respond`.
  Multimodal image input is ABSENT in the macOS 26 SDK → text+OCR only; the macOS-27 attach site is noted.
- `Subtitles.swift` (C1) — `srt`/`vtt(dir:)` from timed segments (or `[mm:ss]`-derived), sanitized to
  monotonic non-overlapping cues; nil when a session has no usable timing.
- `Sharing.swift` (C3) — `NSSharingServicePicker` share sheet (Notes/Mail/…) + Obsidian (write `.md`
  into a vault folder, or `obsidian://new`). NO AppleScript/Automation.
- `AudioFile.swift` (B1/B2/B3) — `AudioFileIO` (decode any audio/video → 16 kHz mono via AVAudioFile or
  AVAssetReader; write compact AAC `.m4a`/`.caf`; `AVAssetImageGenerator.image(at:)` frame extraction) +
  `AudioMixer` (sums mic+system `SampleReceiver` ports into the shared sink with headroom + a limiter).
- `Importer.swift` (B1) — drag-drop / Import… of audio & video → a full session folder via `DocumentBuilder`
  (transcribe + finalPass; video also samples + OCRs frames). Off the recording path; opens the Viewer.
- `Notifier.swift` (D3) — `UserNotifications` wrapper; lazy auth, silent no-op when denied; guards the
  no-bundle (CLI self-test) case so the same binary never traps.
- `SessionViewer.swift` (the new in-app surface) — `SessionViewerModel` + the Viewer: clickable timestamped
  transcript, `AVAudioPlayer` bar (seek on line/citation/bookmark/chapter), summary suite (style switcher,
  action items, chapters), grounded chat panel, export/share menu. `OnDeviceBadge`. Library Open routes here.
- `OnboardingWindow.swift` (D2) — first-run Mic + Screen Recording (+ quit-relaunch note) + optional
  Notifications walkthrough + optional Calendar step (Stage 1; status only queried once enabled);
  persists an `onboarded` flag.
- `AskWindow.swift` (A2) — cross-session Ask window (query → on-device answer + clickable source sessions).
- `SpeakerAlignment.swift` (Stage 1, A) — `SpeakerTurn` + pure functions: `normalize` (raw diarizer
  cluster ids → stable 1-based slots in first-appearance order) and `assign` (max-temporal-overlap
  segment labeling; zero overlap → nearest midpoint; never re-times/drops a segment). `--selftest-align`.
- `Diarizer.swift` (Stage 1, A) — `DiarizerService` actor wrapping FluidAudio (`DiarizerModels.
  downloadIfNeeded` + `DiarizerManager.performCompleteDiarization`, idempotent prepare with the same
  (message, fraction?) progress shape) + `DiarizationPass.run(dir:samples:)`, the post-save pass that
  labels segments, sets `speakerCount`, re-renders transcript.md WITH labels, and re-indexes. The
  cross-session voiceprint hook (SpeakerManager/enrollment) is marked FUTURE and not built.
- `Cleanup.swift` (Stage 1, D1) — `TranscriptCleanup` (per-segment batched FoundationModels cleanup;
  strict within-line instructions; `parseBatch` defensive parser) + `CleanupPass.run(dir:)` (post-save,
  writes ONLY session.json `cleanedText`s — transcript.md is never touched).
- `CalendarMonitor.swift` (Stage 1, C) — pure `MeetingLinkDetector` (Zoom/Teams/Meet/Webex/Whereby
  regexes; generic https in the URL FIELD only as weak fallback) + pure `MeetingTriggerLogic.decide`
  (link required, never while recording, fire-once, lead window incl. in-progress) + the `@MainActor`
  `CalendarMonitor` (EKEventStore + 60 s timer + `.EKEventStoreChanged`; exists ONLY while the toggle
  is on; lazy `requestFullAccessToEvents`; silently inert when denied).
- `Generation.swift` (Stage 2, A) — `GenerationStudio` template registry + execution. `GenerationKind`
  (summaryStyle / customMode / structured generators), `GenerationTemplate {id,name,group,kind}`,
  `GenerationOutput {text,format,json}`, `builtins`/`allTemplates(customModes:)`. `generate(template:
  sourceText:slidesText:)` delegates summary/custom kinds to `Intelligence` (byte-identical output,
  cached in `meta.summaries`) and structured kinds to `StructuredGen`. Portable exports: `flashcardsCSV`
  (Anki front/back), `quizCSV`, `flashcardsMarkdown`; pure `displayText`/`flashcardsDisplay`/`quizDisplay`
  re-render cached JSON even when AI is off.
- `GenerationTemplates.swift` (Stage 2, A) — the `@Generable` output types (meeting minutes, decision
  log, Q&A, objection log, SOAP/DAP, interview report, flashcards, quiz, study guide, show notes,
  titles, social, blog, email) + `StructuredGen.run` dispatcher. ALL gated `@available(macOS 26.0, *)`
  (the `@Generable` macro conforms to macOS-26-only `FoundationModels.Generable`); fields are
  non-optional with empty-string sentinels to sidestep Optional-Generable subtleties. `respond(to:
  generating:options:)` returns the decoded Swift value — no string parsing.
- `ClipExporter.swift` (Stage 2, A) — on-device audio clip (`exportClip`: decode→slice→`AudioFileIO`)
  + audiogram (`renderWaveform` Core Graphics RMS bars + optional burned-in caption; `exportAudiogram`
  writes a still-image H.264 video via AVAssetWriter and muxes it with the clip audio via
  AVMutableComposition → `.mp4`). Full video-clip compositing is OUT OF SCOPE (hook only).
- `Packs.swift` (Stage 2, B) — `Pack {id,name,description,vocabulary,templateIds,defaults}` +
  `PackManager` loading `Packs/*.json` via `Bundle.module` (SPM `resources:[.copy("Packs")]`; works for
  the raw self-test binary AND the .app). `mergedVocabulary(userVocab:)` unions enabled-pack vocab with
  the user's (empty ⇒ [] ⇒ promptTokens nil no-op preserved); `exposedTemplateIDs` validates against the
  registry; enabled ids persist in UserDefaults. Availability routes through `Entitlements`.
- `Entitlements.swift` (Stage 2, B) — `EntitlementProvider` seam + `PaidFeature`. `LocalEntitlementProvider`
  grants EVERYTHING (ships fully functional). The ONLY monetization scaffolding — NO StoreKit/commerce/
  license verification is built (intended-use note in the file; pricing undecided).
- `Retention.swift` (Stage 2, C1) — `RetentionPolicy {autoDeleteEnabled,maxAgeDays,deleteAudioOnly}`
  (UserDefaults, disabled by default). `sweep(root:policy:now:trash:)` (idempotent launch sweep; expired
  unlocked sessions → Trash, or audio-only when configured; `retentionLocked` exempts; `trash`/`now`
  injectable for tests) + manual `deleteAllAudio`/`deleteOlderThan`.
- `Redaction.swift` (Stage 2, C2) — `Redactor.redact`/`redactSegments` (NLTagger names/orgs/places +
  NSDataDetector phone/address/date/link + regex email/SSN/ID; STABLE `[PERSON n]` pseudonyms; non-
  overlapping span substitution) + `RedactionPass.run(dir:)` (writes ONLY `redactedText` per segment in
  session.json — `transcript.md` stays verbatim; mirrors `CleanupPass`). Works without AI (FM augment optional).
- `SessionIO.swift` (Stage 2, C4) — the single read/write SEAM. OFF (default) = byte-identical
  passthrough. ON = AES-GCM (CryptoKit), per-install key in the Keychain, optional Touch ID at unlock.
  `TRENC1` magic prefix → `readData` decrypts iff actually encrypted (robust mid-migration). `enable/
  disableEncryption` migrate existing sessions copy-then-verify-then-replace + one-time backup.
  `overrideKey` test hook. `transcript.md`/`session.json`/audio/images route through it; SearchIndex is
  in-memory-only (no plaintext cache) when ON.
- `SlideChat.swift` (Stage 2, D) — PURE slide-image selection: `selectSlides(frames:question:cap:)`
  (nearest a referenced `[mm:ss]`, else an even sample), `referencedTime`, `imageInputAvailable`
  (macOS-27 SDK flag + OS). The actual image-input call lives in `Intelligence.answerForSession` behind
  `#if TRANSCRIBER_MACOS27` + `#available(macOS 27)`; macOS 26 uses the text+OCR fallback verbatim.

## Data flow
Capture (`AudioCaptureMic` **or** `AudioCaptureSystem`, one at a time) → `Resampler16k` → shared
`SampleSink` (16 kHz mono Float32). `StreamingTranscriber` consumes the sink: each ~1 s it re-transcribes
the buffer from `lastConfirmedEnd` (`DecodingOptions.clipTimestamps`), confirms all but the last 2
segments, and publishes confirmed + hypothesis text — so live text grows without duplication (this
replicates WhisperKit's own mic-only `AudioStreamTranscriber` algorithm). On Stop: write the session
folder's live `transcript.md`, run one VAD-chunked `finalPass()` over the whole buffer, overwrite with
the clean version, then (off-main) index it + auto-title/tag (see Unified session store below).

> **Unified session store (Prompt 1):** EVERY session — audio-only *and* visual — now saves as a
> folder `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/` (`transcript.md` + `session.json`, plus
> `images/` only when visual). This replaces the old audio-only flat `transcript-….md`. Legacy flat
> files are migrated once on launch (`SessionStore.migrateLegacyFlatFiles`): non-destructive (one
> full backup to `~/Desktop/Transcripts_backup_<stamp>` first), copy-then-verify-then-remove,
> idempotent (re-run = no-op). Export stays gated on visual sessions (`canExport = lastSessionDir &&
> lastSessionHasVisual`) so audio-only folders don't surface a text-only HTML/PDF.

## Visual Capture (document mode) — Sources: ScreenCapture / FrameChangeDetector / DocumentBuilder / SlideOCR / Exporter
- **Toggle** in Settings / menu (persisted, default off). When on, a session adds `images/` + frames to
  the folder layout (all sessions are folders now — see Unified session store). `session.json` stays
  machine-readable and drives export.
- **Per-session target** (Settings picker, live from `SCShareableContent`, refreshed on open): main display,
  a specific display, a window, or an app. Own windows excluded; `showsCursor = false`.
- **Per-session mode**: On change (dHash + settle state machine — one clean frame per slide), Every N s
  (interval timer; for video), Manual only. **⌥⌘S** force-grabs the current frame in any mode.
- **Stream topology** (the key non-regression rule):
  - System audio + visual → ONE `SCStream` (AudioCaptureSystem) carrying `.audio` (→ SampleSink, unchanged)
    and `.screen` (→ VisualCapture.ingest). Filter is the chosen visual target, so audio is scoped to it.
  - Mic + visual → mic audio via AudioCaptureMic (unchanged) + a SEPARATE video-only `SCStream` owned by
    VisualCapture. If the captured window/app dies, only video stops; mic audio keeps recording.
  - When visual is OFF, AudioCaptureSystem uses the original 2×2 audio-only config verbatim.
- **Timeline / T0**: one monotonic `CACurrentMediaTime()` at recording start. WhisperKit segment
  timestamps are relative to the audio buffer start (== T0); frame events are `now - T0`. DocumentBuilder
  sorts both by time and interleaves `[mm:ss] text` with `![mm:ss](images/…png)` + an OCR `<details>` block.
- **Two passes, same builder**: a live save on stop (streamer's confirmed segments + frames), then the
  full-quality `finalPassSegments` + batched OCR re-merge (frames are NOT re-captured).
- **OCR**: Vision, on-device, run off the main thread (`Task.detached`) in the final pass. OCR toggle in Settings.
- **Export**: HTML (base64 images, self-contained) + PDF (`WKWebView`). User-triggered via NSSavePanel; the
  folder + transcript.md is the lightweight canonical form, HTML/PDF the larger portable share form.
- **Threading**: VisualCapture confines ALL state to one serial `queue`; `onFrame`/`onStopped` are invoked
  on the main actor (`DispatchQueue.main.async`) to avoid cross-thread closure reads from SCStream's
  delegate thread. `stop()` drains the queue via an async continuation (no MainActor block).
- **Tunables** (`VisualConstants`): CHANGE_THRESHOLD 12, STABLE_THRESHOLD 3, STABLE_WINDOW 1s, MIN_INTERVAL 2s,
  ~2 fps, MAX_IMAGES 500, interval default 15s, thumbnail 240px. dHash measures EDGE STRUCTURE — sparse
  near-uniform frames hash near-zero, so the threshold is tuned for real (dense) screen content.

## Unified store, Library & full-text search (Prompt 1 — Sources: SessionStore / TitleGenerator / SearchIndex / LibraryWindow / DocumentBuilder / AppModel)
- **One layout for all sessions** — folders with `transcript.md` + `session.json` (+ `images/` if visual).
  `AppModel.startFlow` always `makeSessionFolder(withImages: visualCaptureEnabled)`; `finalizeDocumentSession`
  handles both (audio-only just has no frames). Migration on launch (see Data flow). NOTHING here touches
  capture / streaming / `finalPass` / hotkeys / signing / the visual stream topology.
- **Auto title + tags** — after `finalPass`, `SessionStore.ensureTitle(dir:)` runs OFF the save path
  (`Task.detached`): on-device via `TitleGenerator` (FoundationModels, `#available(macOS 26)`) → a ≤8-word
  title + ≤5 lowercased/deduped tags, stored in `session.json` via `writeSessionJSON` (transcript.md never
  re-rendered). Unavailable AI / empty transcript → deterministic fallback title (first words / date),
  empty tags. Saving NEVER fails or blocks on titling. Migrated/legacy sessions are titled lazily by the
  `TitleBackfill` actor (serial, 300 ms apart) when the Library first lists them.
- **Library window** (`WindowManager.showLibrary`, manual NSWindow like Transcript/Settings; reachable from
  the menu-bar popover and the Transcript toolbar). Lists sessions newest first (title/date/source, slide
  badge + image count, snippet, tags); tag + date-range filters; Open (`transcript.md`) / Reveal in Finder /
  Delete-to-Trash (`NSWorkspace.recycle`, never hard-delete). Live-refreshes via `.transcriberSessionSaved`.
- **Cross-session search** (`SearchIndex`, in-app, on-device, NO Spotlight) — tokenized case-insensitive
  inverted index over each `transcript.md` (which already embeds OCR text for visual sessions). Built from
  disk on launch (cache under Application Support for cold start, but disk mtimes are the source of truth),
  updated incrementally on each save. `search(_:) -> [SessionHit]` ranks by match count + recency; each hit
  carries snippets with the nearest `[mm:ss]`. The hit type is the reuse surface for a future "chat with your
  sessions" feature. Keyword only — no semantic/embedding search.
- **Notification** `.transcriberSessionSaved` (`userInfo["dir"]`) decouples save → Library refresh + index
  update. Posted by `AppModel` (live + final save), `SessionStore.ensureTitle`, and the launch migration/rebuild.

## Prompt 2 — Chat & Intelligence, Capture coverage, Output & accuracy, UX & trust
**100% on-device, additive, off/neutral by default. No new deps. Only NEW permission = Notifications (lazy, silent if denied).**
- **Chat & intelligence (A)** — `Intelligence.swift`, text-only FoundationModels (`respond(to:options:)`):
  per-session grounded chat (cites clickable `[mm:ss]`), cross-session **Ask** (retrieves via
  `SearchIndex` → answers + clickable source sessions), and a summary suite (TL;DR/detailed/executive +
  action items + `[mm:ss]` chapters). Cached in `session.json` (`summaries`/`actionItems`/`chapters`).
  Multimodal image input is ABSENT in the macOS 26 SDK (verified against the framework's swiftinterface) →
  text+OCR only; the macOS-27 attach site is marked, gated behind `#available(macOS 27)`.
- **Capture coverage (B)** — *highest regression risk; all gated off by default.*
  - **Import** (`Importer`/`AudioFileIO`): drag-drop or Import… of `.mp3/.m4a/.wav/.mp4/.mov` → a full
    session folder (audio decode → `transcribeSamples` + finalPass; video also samples frames every N s
    + OCR). Opens in the Viewer.
  - **Mic + System** (`AudioSource.micPlusSystem` + `AudioMixer`): both captures resample to 16 kHz mono
    and feed an `AudioMixer` (sum × 0.85 + hard limit) into the ONE shared `SampleSink`; the existing
    single `StreamingTranscriber`/`finalPass` run UNCHANGED downstream. Visual rides the SYSTEM stream
    (same topology as system-audio+visual); the mic is a separate audio-only capture. The capture sources
    now take a `SampleReceiver` (the sink for single-source = byte-identical; a mixer port for Mic+System).
  - **Save audio** (`saveAudioEnabled`, default ON): on stop, writes `audio.m4a` (16 kHz AAC, T0-aligned)
    from the sink; `meta.audioFile`/`durationSeconds`. Imported audio keeps the original as `source.<ext>`.
- **Output & accuracy (C)** — SRT/VTT (`Subtitles`), `.txt`/`.rtf` + HTML/PDF (`Exporter`), share sheet +
  Obsidian (`Sharing`, no Automation). **Custom vocabulary** (`customVocabulary`) → `DecodingOptions.promptTokens`
  via `whisperKit.tokenizer.encode(text:)` (WhisperKit 1.0.0, verified) in BOTH streaming + finalPass;
  **empty list → `promptTokens` nil → EXACT no-op** (never `[]`, which would change the prefill).
- **UX & trust (D)** — live bookmarks (`⌥⌘B` Carbon hotkey, no permission → `meta.bookmarks`),
  first-run permission `OnboardingWindow`, **Recent Sessions** menu (cached, refreshed on save), done
  `Notifier` notifications (long finalPass / import; gated >30 s; silent if denied), persistent
  `OnDeviceBadge` ("On-device · offline") in windows + menu.
- **Session Viewer** (`SessionViewer.swift`, manual NSWindow via `WindowManager.showViewer(dir:)`): the one
  in-app surface hosting transcript + playback + bookmarks + summary + chat + export. Library **Open** routes
  here (Reveal in Finder still opens the folder). `WindowManager` also owns `showOnboarding`/`showAsk`.

## UI redesign (presentation only — Sources: Theme / TranscriptWindow / TranscriptComponents / TranscriptCanvas / MenuContent)
- **One UI state** drives the window: `AppModel.uiState ∈ {idle, downloading, recording, summary}`, derived
  from `showingSummary`, `isRecording`, and `status.isPreparing`. Titlebar, canvas, and status bar all swap
  per state. Reference mockup: `Transcriber-redesign.html`.
- **The signature**: the streamer's confirmed-vs-hypothesis split is surfaced — `AppModel.displaySegments`
  (confirmed, timestamped) render solid; `hypothesisText` renders dimmed (tertiary) with a blinking caret.
  `StreamingTranscriber.onUpdate` now passes a `LiveTranscript {confirmed:[TranscriptSegment], hypothesis}`
  instead of a String. The streamer ALGORITHM is unchanged; `transcript` (the full concat) is still computed
  for save/summarize, so saved output is byte-identical (verified: transcript.md / doc.md identical,
  session.json semantically identical — key order is JSONEncoder-nondeterministic, decoded order-independently).
- **Live meter + timer** = `RecordingHUD` (own ObservableObject so 12 Hz updates don't re-render the
  transcript). Meter bars come from `SampleSink.recentRMS()`. `currentLevel`/elapsed driven by a Timer while
  recording.
- **Custom titlebar**: the transcript NSWindow uses `titlebarAppearsTransparent + .fullSizeContentView`
  (WindowManager, `customTitlebar: true`) so the dark 52pt toolbar reaches the top; traffic lights overlay a
  78pt leading inset. Window-open-on-launch / reopen-on-Dock behavior is unchanged.
- **Tokens** (`Theme`): surfaces, hairlines, text 3-tier, record red (record dot / Stop / meter / "Listening"
  only), accent indigo (interactive), AI lavender (Summarize sparkle), the pink→indigo→teal gradient ONLY on
  the 2px summary-panel top edge. Transcript = New York serif 16.5pt; chrome = SF Pro; timestamps/timer = SF Mono.
  All colors adapt light/dark; popover uses `.ultraThinMaterial`. Reduced-motion drops meter/caret/pulse.
- **States that differ from the mockup (decisions)**: idle with a non-empty transcript is a **review**
  state (not the centered invite, which is for the empty/fresh state). Its toolbar has a **Record** pill
  (start a new session) + **Clear** (trash → back to invite) + Summarize + folder/gear, so there's always a
  way back. Export stays reachable from the menu-bar popover (the mockup omits it).
- **Toolbar labels** use `.lineLimit(1).fixedSize()` so they never wrap/truncate; default transcript window
  is 900×640 (minWidth 680) so the busiest (recording) toolbar fits.
- **Downloading** shows real progress: `prepare(model:progress:)`'s callback now passes `(message, fraction?)`.

## Permissions & code signing (READ THIS)
- **Microphone** (`NSMicrophoneUsageDescription`) — prompted on first mic use.
- **Screen Recording** (`NSScreenCaptureUsageDescription`) — required for system audio; triggered by
  ScreenCaptureKit. After granting you **must fully quit & relaunch** (the running process won't pick
  up a fresh grant). Handled with a clear error → System Settings ▸ Privacy & Security ▸ Screen Recording.
- **Calendar** (`NSCalendarsUsageDescription` + `NSCalendarsFullAccessUsageDescription`, Stage 1) —
  OPTIONAL, for calendar-aware capture only. Lazy (requested only when the feature is toggled on),
  silent-if-denied (same contract as Notifications). When the toggle is OFF, no `EKEventStore` is
  ever instantiated — even the static status check is gated behind the toggle.
- **Stable signing is essential.** TCC binds grants to the app's code signature. Ad-hoc signing changes
  the signature every rebuild, so grants kept breaking ("toggle on but still denied"). Fixed with a
  **stable self-signed identity** "Transcriber Local Signing" in an isolated keychain
  (`Scripts/setup_signing.sh`); `build_app.sh` uses it if present (else ad-hoc). The designated
  requirement is byte-identical across rebuilds (verified), so grants now persist. If permissions ever
  act stale: `tccutil reset ScreenCapture com.nikhil.transcriber` (and `Microphone`), then re-grant.
- The global hotkey uses Carbon RegisterEventHotKey → **no permission dialog** normally.

## Pinned dependency API facts (verified at the tag — read before changing calls)
- **WhisperKit 1.0.0** ships from the consolidated package **`argmaxinc/argmax-oss-swift`** (exact
  `1.0.0`), product/module `WhisperKit`. `import WhisperKit`.
  - `WhisperKit(WhisperKitConfig(model:"openai_whisper-base.en", modelFolder:, load:true, download:false))`
    — **`load:true` is required** (with `modelFolder` set and `load` nil, models silently don't load).
  - `WhisperKit.download(variant:progressCallback:) async throws -> URL` (progress = Foundation `Progress`).
  - `transcribe(audioArray:[Float], decodeOptions:, callback:, segmentCallback:) async throws -> [TranscriptionResult]`
    and `transcribe(audioPath:String, …) -> [TranscriptionResult]`. `WhisperKit.sampleRate == 16000`.
  - Models: `openai_whisper-base.en` (default), `openai_whisper-small.en`, `openai_whisper-large-v3_turbo`.
  - `AudioStreamTranscriber` exists but is **mic-only** (uses `audioProcessor.startRecordingLive`) → not
    usable for system audio; we reimplement its confirm algorithm in `StreamingTranscriber`.
- **KeyboardShortcuts 2.4.0** (exact). `KeyboardShortcuts.Name(_, default:)`, `.Recorder(_:name:)`,
  `onKeyDown(for:action:)`. Ships localized resources → `build_app.sh` copies its `*.bundle` into Resources.
- **FoundationModels** (macOS 26 SDK): `SystemLanguageModel.default.availability` (`.available` /
  `.unavailable(.appleIntelligenceNotEnabled | .deviceNotEligible | .modelNotReady)`),
  `LanguageModelSession(instructions:)` → `respond(to: String) async throws -> Response<String>`,
  read `.content`. All `@available(macOS 26)` → guarded with `#available`. Verified available on this Mac.
- **WhisperKit 1.0.0 multilingual facts** (verified at the tag): `DecodingOptions.language: String?`
  (ISO code; nil = no forced language) + `detectLanguage: Bool`; the array-based detector is literally
  misspelled **`detectLangauge(audioArray:)`** [sic] returning `(language, langProbs)` — only the
  `detectLanguage(audioPath:)` spelling is correct. Detection requires a multilingual model (throws on
  `*.en`). Multilingual variants: `openai_whisper-base`, `openai_whisper-small`,
  `openai_whisper-large-v3_turbo`. `DecodingTask.translate` exists but is deliberately NOT wired
  (source-language transcription only; translation is a later stage).
- **FluidAudio 0.15.2** (git tag `v0.15.2`, exact pin; **platform floor macOS 14**, which forced the
  deployment-target bump; zero package dependencies). Verified at the tag:
  `DiarizerModels.downloadIfNeeded(progressHandler: (DownloadProgress) -> Void) async throws ->
  DiarizerModels` (anonymous HuggingFace download from `FluidInference/speaker-diarization-coreml` —
  a Bearer token is attached ONLY if an HF_TOKEN-style env var exists, so no account is ever needed;
  cache under `~/Library/Application Support/FluidAudio/Models/`); `DiarizerManager(config:)` (class;
  `DiarizerConfig.clusteringThreshold` defaults 0.7 — the documented sweet spot);
  `initialize(models: consuming DiarizerModels)` (sync, non-throwing);
  `performCompleteDiarization(_ samples, sampleRate: 16000)` — **synchronous + throwing**, generic over
  `RandomAccessCollection<Float>`, returns `DiarizationResult` whose `segments: [TimedSpeakerSegment]`
  carry `speakerId: String`, `startTimeSeconds`/`endTimeSeconds: Double`. Run it off the main thread.
  `OfflineDiarizerManager` (higher-accuracy VBx) deliberately NOT used. If a future version ever
  requires an HF token, STOP and flag it — that would break the no-account positioning.

## Headless self-tests (no mic / no permissions)
Run the built binary (`.build/release/Transcriber` or the bundle's MacOS binary):
- `--selftest [audio.wav] [--model <id>]` — one-shot file transcription.
- `--selftest-stream [audio48k.wav]` — drives `Resampler16k` + `StreamingTranscriber` + `finalPass`.
- `--summarize [transcript.md]` — on-device summary; prints availability + result.
- `--selftest-capture [frames-dir]` — feeds frames into FrameChangeDetector; asserts one capture per
  distinct slide (synthesises 3 distinct full-frame patterns if no dir). Prints pairwise dHash hamming.
- `--selftest-ocr [image.png]` — Vision OCR of an image (synthesises a text image if none).
- `--selftest-doc` — synthetic segments + frame events → prints merged Markdown; asserts ordering.
- `--selftest-export [session-folder]` — builds HTML + PDF (synthesises a session if none). Runs a main
  run loop so WKWebView can render the PDF.
- `--selftest-migrate [dir]` — synthesises legacy flat `.md` files, migrates, and asserts each became
  `<name>/transcript.md` + `session.json`, bytes preserved, a backup exists, and a 2nd run is a no-op.
- `--selftest-index [dir]` — synthesises sessions (incl. OCR slide text), builds `SearchIndex`, runs
  queries; asserts correct sessions, snippets, `[mm:ss]` timestamps, and ranking (compares by folder name —
  `/tmp`→`/private/tmp` + trailing-slash make full-URL `==` unreliable in tests).
- `--selftest-title [transcript.md]` — runs title + tag generation; prints availability + output; asserts
  the deterministic fallback yields a non-empty title (the path used when Apple Intelligence is unavailable)
  and that markdown-wrapped `**Title:**`/`**Tags:**` labels are stripped.
- **Prompt 2:** `--selftest-chat` (grounded answer cites `[mm:ss]`; clean fallback on empty/unavailable),
  `--selftest-ask` (cross-session retrieval returns the right source), `--selftest-summary` (3 styles +
  action items + monotonic-start chapters), `--selftest-import` (audio file + a synthesized video+audio
  `.mov` → session folders, frames for video; writes to a temp root, never `~/Desktop/Transcripts`),
  `--selftest-mix` (mixer non-clipping + well-formed; single-source byte-identical), `--selftest-audio-save`
  (write→read-back duration matches), `--selftest-srt` (monotonic non-overlapping SRT/VTT cues),
  `--selftest-vocab` (promptTokens built for terms; empty/blank/no-model → nil no-op),
  `--selftest-bookmarks` (persist + reload from session.json; legacy → empty). `--retag [dir] [--force]`
  remains a maintenance utility.
- **Stage 1:** `--selftest-diarize [audio.wav]` (synthesizes a two-voice `say` conversation when no
  file given; downloads the FluidAudio models on first run; asserts ≥2 distinct 1-based slots on the
  synthetic clip), `--selftest-align` (pure: max-overlap assignment, first-appearance slot order,
  nearest-midpoint fallback, timing untouched), `--selftest-detect [audio.wav]` (multilingual
  `openai_whisper-base`; synthesizes a Spanish clip when a Spanish `say` voice exists, else falls back
  to English; asserts the detected code), `--selftest-multilingual [audio.wav] [--lang xx]` (explicit
  language pinned, or the Auto detect-once-then-pin path; never writes to ~/Desktop/Transcripts),
  `--selftest-calendar` (pure link-detection + trigger rules incl. never-while-recording and
  fire-once; live EventKit is human-verified), `--selftest-cleanup [transcript.md]` (segment count +
  timestamps + verbatim text preserved; ≥1 cleaned form when FM available, exact no-op when not),
  `--selftest-custom-summary [transcript.md]` (empty template rejected without a model call;
  non-empty output when FM available, clean throw when not).
- **Stage 2:** `--selftest-generate [transcript.md] [--template minutes|soap|flashcards|quiz|shownotes|
  blog|titles|interview|decisions|qa|studyguide]` (the `@Generable` output decodes + is non-empty when
  FM available; clean throw when off; JSON decodes for flashcards/quiz; any mm:ss well-formed),
  `--selftest-audiogram [audio.m4a]` (synthesizes a sine clip if none; clip duration matches, waveform
  renders, muxed `.mp4` has video+audio tracks + duration; temp dir only), `--selftest-packs` (4 packs
  parse, valid template ids, vocab merge incl. empty ⇒ no-op, entitlement grants all),
  `--selftest-redact [transcript.md]` (email/phone/date masked, names → stable pseudonyms, verbatim
  untouched, timestamps preserved; `transcript.md` unchanged by the pass; works without FM),
  `--selftest-retention [dir]` (expired-unlocked trashed via an injected trash dir, locked + recent
  kept, second run a no-op), `--selftest-encrypt [dir]` (OFF passthrough byte-identical; ON on-disk
  bytes not plaintext + read decrypts exactly + transcript.md encrypted; SearchIndex in-memory finds
  terms and writes NO cache file), `--selftest-slidechat` (pure: nearest-slide selection for a
  time-referenced question, even sample otherwise, cap respected, macOS-26 build → image input
  unavailable → text+OCR fallback). All write only to temp dirs.
- `--retag [dir] [--force]` — maintenance utility (NOT a self-test): fills missing tags on titled-but-
  untagged sessions (keeps the title; skips near-empty `[BLANK_AUDIO]` transcripts) via `generateTags`.
  `--force` regenerates tags even on already-tagged sessions. Defaults to `~/Desktop/Transcripts`.
Test clips were made with `say` + `afconvert` (`/tmp/transcriber_test.wav`, `/tmp/tr_long_48k_stereo.wav`).
All visual self-tests pass headlessly; the LIVE capture path (real SCStream video) needs a real screen +
Screen Recording grant + on-screen content and must be verified by running the app.

## Status — all DONE & user-verified
- [x] Menu-bar + Dock app launches (opens the control window on launch).
- [x] WhisperKit file transcription, model download + offline caching.
- [x] Streaming pipeline (resample, rolling-window dedup) + full-quality final pass.
- [x] Live **mic** transcription (user-verified, incl. via AirPods mic).
- [x] Live **system-audio** transcription (user-verified, incl. while listening on AirPods).
- [x] Global hotkey ⌥⌘T; auto-save timestamped `.md` to `~/Desktop/Transcripts/`.
- [x] On-device AI summary (Apple Intelligence) via the Summarize button.
- [x] **Visual Capture** — USER-VERIFIED working end-to-end on a real screen (capture target, frame
      detection, interleaved transcript.md + images/, OCR, live thumbnails, HTML/PDF export). Detector /
      OCR / timeline-merge / export also pass headless self-tests; adversarial review done + fixes applied;
      no audio regression.
- [x] **Unified session store + Library + full-text search** (Prompt 1) — all sessions save as folders;
      legacy flat `.md` migrate non-destructively (backup + idempotent); auto title/tags on-device with
      fallback; Library lists/sorts/filters with Open/Reveal/Delete-to-Trash + live refresh; keyword search
      across transcript + OCR text with ranked, timestamped snippets. `--selftest-migrate`/`-index`/`-title`
      pass headlessly; existing self-tests still pass; backward-compatible `readSession` verified on an
      old-schema `session.json`. **USER-VERIFIED via GUI:** first launch migrated the real 5 flat files →
      folders (byte-identical, one backup, idempotent on relaunch); Library lists/searches/tag-filters;
      on-device titles+tags generated. Two bugs found & fixed during GUI verify: (1) snippet timestamps
      leaked from the `**Date:**` header line → now skip the header (legacy → `—`); (2) title/tag parse
      didn't strip markdown-bolded `**Title:**`/`**Tags:**` labels → now stripped, with a display-time
      sanitize guard + no-model self-heal of already-stored titles.
- [~] **Prompt 2 — Chat & Intelligence / Capture / Output / UX & trust** — per-session chat (cites
      `[mm:ss]`) + cross-session Ask + summary suite (styles/action-items/chapters, cached); audio/video
      import; Mic+System mixer (off by default, single-source byte-identical); save-audio + clickable
      transcript playback; SRT/VTT + txt/rtf + share/Obsidian; custom-vocab biasing (empty = no-op); live
      bookmarks; onboarding; Recent menu; done notifications; on-device badge; the Session Viewer.
      **Build green; ALL self-tests pass** (9 new + all prior incl. streaming/file transcription unchanged).
      **Adversarial multi-agent review done** (15 confirmed findings, 0 false-positives) → 13 fixed incl.
      the mixer PCM-reordering race (append inside the lock), session.json last-writer-wins (Viewer merges
      only its owned fields + atomic write), import error-status clobber, slider-scrub vs playback, derived-cue
      overlap, 3-digit-minute timestamps, citation markdown. 2 left by design (transient 2nd import model,
      singleton observer token). **AWAITING human smoke-tests** (live mic / live system / Mic+System /
      playback-seek / real file & video import / bookmarks / Notifications prompt / Notes-Obsidian share —
      can't be verified headlessly).
- [~] **Stage 1 — Diarization / Multilingual / Calendar capture / Cleanup + custom modes** — FluidAudio
      0.15.2 pinned (deployment target raised 13→14, its platform floor); speaker labels + per-session
      rename + colors; multilingual models + detect-once "Auto" + `*.en` guard; calendar prompt/auto-start
      through the existing startFlow with one-shot source override + title seeding; non-destructive
      per-segment cleanup + Verbatim/Cleaned Viewer switch; custom summary modes (authored in Settings,
      cached namespaced). **Build green; ALL self-tests pass** — the 7 new ones
      (diarize/align/detect/multilingual/calendar/cleanup/custom-summary) AND the entire prior suite
      unchanged (file + stream output text identical to pre-build). One prompt bug found & fixed during
      self-test (cleanup model echoed the literal "N|" format token → clearer instructions + defensive
      parser strip). **AWAITING human smoke-tests** (live 2-speaker diarization + rename persistence,
      speaker-model first download, live multilingual + Auto indicator, `*.en` guard UX, calendar
      prompt/auto-start/denial, cleaned-view toggle on a real filler-heavy recording, custom mode
      end-to-end, full regression sweep — list handed back at the end of the Stage-1 build).
- [~] **Stage 2 — Generation Studio / Vertical Packs / Privacy & Compliance / Multimodal Slide Chat** —
      Feature A: unified `@Generable` Generation Studio (meeting/clinical/interview/sales/study/creator
      templates) decoding to typed values, cached in `meta.generatedArtifacts`, export incl. flashcard/
      quiz CSV; audio clip + audiogram export; the 3 summary styles + Stage-1 custom modes unified into
      the Studio (identical output via the existing `Intelligence` path/cache). Feature B: Legal/Medical/
      Education/Finance-Sales packs (bundled JSON via `Bundle.module`) merging vocab (empty ⇒ no-op
      preserved) + surfacing templates; `EntitlementProvider` seam grants all (commerce NOT built).
      Feature C: retention auto-delete-to-Trash + per-session Keep + manual purge; non-destructive
      on-device redaction (Viewer Verbatim/Cleaned/Redacted switch + redacted export); compliance panel;
      optional AES-GCM encryption-at-rest seam (OFF = byte-identical passthrough, ON = no plaintext at
      rest + in-memory SearchIndex + optional Touch ID). Feature D: completed the macOS-27 slide-image
      attach site behind `#if TRANSCRIBER_MACOS27` + `#available(macOS 27)` with the macOS-26 text+OCR
      fallback; pure slide-selection logic shipped + tested. **Build green; ALL self-tests pass** — the 7
      new ones (generate/audiogram/packs/redact/retention/encrypt/slidechat) AND the entire prior suite
      unchanged (`--selftest-doc` md5 identical; default session.json omits the new keys; file + stream
      transcription text identical). **Feature D's image call is NOT compiled** (this machine has only the
      macOS 26 SDK — zero image symbols): A/B/C ship fully; D's image path compiles + runs once built with
      `MACOS27=1 DEVELOPER_DIR=<Xcode 27 beta>` (the SDK's exact image value type inside `Prompt {}` must
      be verified there — marked in `Intelligence.answerWithSlides`). **AWAITING human smoke-tests** (see
      the Stage-2 checklist: run each Studio template + audiogram, enable Medical/second pack, redact a
      PII session, retention sweep with a Keep, optional encryption round-trip + Touch ID, macOS-27
      slide chat, full Stage-0/1 regression sweep).

## Stage 2 — Generation Studio / Vertical Packs / Privacy & Compliance / Multimodal Slide Chat
**All additive, all OFF or neutral by default. With defaults untouched a session's `transcript.md` is
byte-identical and `session.json` semantically identical to post-Stage-1 (new optional keys absent).
No new SPM deps — everything is a system framework. Non-regression anchors unchanged: capture / streaming
algorithm / finalPass / diarization / hotkeys / signing / visual stream topology.**
- **A — Generation Studio**: `Generation.swift` + `GenerationTemplates.swift`. FoundationModels guided
  generation (`@Generable`, macOS 26 — verified at the SDK: `respond(to:generating:options:)` returns the
  decoded value; `@Guide(description:)` macro). Templates grouped (Summary/Meeting&work/Clinical/Interview/
  Study/Creator/Custom). Summary-style + custom-mode kinds delegate to `Intelligence` and ride
  `meta.summaries` (output byte-identical to the classic Summary panel); structured kinds ride
  `meta.generatedArtifacts` (a `GeneratedArtifact {templateId,format,content,createdAt}`, `decodeIfPresent`).
  Studio uses cleaned text when the Viewer's Cleaned view is active, else verbatim (documented). Clinical
  SOAP/DAP are labeled "draft, not a medical record". Creator audio: `ClipExporter` clips + audiograms.
  Viewer side-panel is now Summary / Studio / Chat. Video-clip compositing is OUT OF SCOPE.
- **B — Vertical Packs**: `Packs.swift` + `Entitlements.swift`. Bundled `Sources/Transcriber/Packs/*.json`
  shipped via SPM `resources:[.copy("Packs")]` → `Bundle.module` (resolves for the raw self-test binary
  AND the .app; `build_app.sh`'s existing `*.bundle` copy handles the .app — no script change needed).
  Enabling packs merges vocab into `effectiveVocabulary` (= user vocab ∪ enabled-pack vocab; empty ⇒ []
  ⇒ promptTokens nil ⇒ byte-identical no-op) and surfaces their templates. Settings ▸ Vertical packs.
  `EntitlementProvider` is the ONLY monetization seam and grants everything; payment/licensing deferred.
- **C — Privacy & Compliance**: `Retention.swift` (C1, launch sweep to Trash, per-session `retentionLocked`,
  manual purge — all idempotent, `trash`/`now` injectable), `Redaction.swift` (C2, NLTagger + NSDataDetector
  + regex, stable `[PERSON n]` pseudonyms, `redactedText` per segment ONLY — transcript.md sacred; Viewer
  Verbatim/Cleaned/Redacted switch with click-to-seek in all; redacted TXT/SRT/VTT export), the Settings
  Privacy & Compliance panel (accurate "privacy by architecture, not a certification" statement), and
  `SessionIO.swift` (C4, the encryption seam). **SessionIO is the single I/O seam**: OFF = byte-identical
  passthrough (proven by `--selftest-encrypt`), ON = AES-GCM + Keychain key + optional Touch ID, `TRENC1`
  magic so reads stay robust mid-migration, copy-then-verify-then-replace + one-time backup on enable/
  disable. **When encryption is ON the SearchIndex is in-memory only (no plaintext cache on disk).**
  transcript.md / session.json / audio / images route through SessionIO (audio playback decrypts to a
  temp file). Newly-written media via AVFoundation isn't auto-encrypted on write — the enable migration
  (and a re-run) encrypts it; the PII-bearing TEXT is always encrypted on write when ON.
- **D — Multimodal Slide Chat (macOS 27, gated)**: `SlideChat.swift` (pure selection) + the completed
  attach site in `Intelligence.answerForSession`. Double-gated: `#if TRANSCRIBER_MACOS27` (compile only
  with the macOS 27 SDK — `MACOS27=1` in `build_app.sh`) AND `#available(macOS 27)` (run only on the 27
  runtime). On macOS 26 the block is absent and the text+OCR chat is byte-for-byte the current behavior.
  The exact image value type inside `Prompt {}` MUST be verified at the macOS 27 SDK (marked TODO).
- **Out of scope (explicit)**: server-side FoundationModels routing / Private Cloud Compute / BYOK cloud
  (leaves the device — kept out to preserve the on-device moat), payment / license-key / StoreKit commerce
  (only the entitlement seam exists), full video-clip compositing (audiograms only), cross-session
  voiceprints (Stage 1), a tool-calling layer for slide chat (we pass images + existing OCR instead).

## Stage 1 — Diarization / Multilingual / Calendar capture / Cleanup + custom modes
**All additive, all OFF or neutral by default — with defaults untouched, a session's transcript.md is
byte-identical and session.json semantically identical to pre-Stage-1 (new optional keys are simply
absent).** Non-regression anchors: the capture layer / streaming algorithm / finalPass / hotkeys /
signing / visual stream topology are untouched; diarization + cleanup run as post-saves off the save
path (same `Task.detached` chain as titling, SERIALIZED: index → ensureTitle → DiarizationPass →
CleanupPass, so session.json read-modify-writes can't race).
- **A — Diarization**: Settings ▸ "Identify speakers (on-device)" (default off). Post-save,
  `DiarizationPass` runs FluidAudio over the same 16 kHz sink buffer finalPass used (snapshot taken
  on-main BEFORE detaching, so a new session's `sink.reset()` can't bite), aligns turns→segments via
  `SpeakerAlignment` (max overlap, nearest-midpoint fallback), writes `segments[].speaker` +
  `meta.speakerCount`, and re-renders transcript.md as `[mm:ss] **Speaker N:** text` (anchor still
  line-leading → click-to-seek/SearchIndex/stripLeadingTimestamp all unaffected; labels searchable).
  Viewer: color-coded chips (`Theme.speakerColor`, 8-hue adaptive palette) + click-to-rename →
  `meta.speakerNames` ("1"→"Alice") via the Viewer's owned-fields writer (allow-list extended with
  `speakerNames`), then a md re-render so renames are searchable. `SessionStore.plainText` strips the
  `**Name:**` label for snippets/titling; `timestampedTranscript` keeps it (chat can cite speakers).
- **B — Multilingual**: `WhisperModel` gains `base`/`small` (multilingual) + `isMultilingual` +
  `multilingualSibling`; `transcriptionLanguage` setting ("en" default / ISO code / "auto").
  **Detect-once-then-pin**: live "auto" delays the streamer ~3 s, runs ONE `detectLangauge` [sic] on
  the lead-in, then attaches the streamer with the pinned code (no mid-session flips; detection can't
  collide with the not-yet-running streamer on the shared WhisperKit). Explicit code = pinned, no
  detection. Import "auto" detects on the decoded lead-in. `*.en` models: language picker disabled
  with a hint; a stored non-English language shows a warning + one-click switch to the sibling —
  never silently-wrong output. `meta.language` stored only when ≠ "en". Status bar shows
  "Detected: …" during recording.
- **C — Calendar capture**: monitor exists ONLY while enabled (zero EventKit otherwise). Prompt mode
  (default) → Notifier line + an in-app Start/Ignore banner; auto mode → `startMeetingRecording` with
  a clear dismissible banner. Both route through the EXISTING `startFlow`; the configured source is a
  one-shot `sourceOverride` (the user's persisted source pick is untouched; `sessionSource` is what
  the session actually used — also fixes meta.sourceLabel). Meeting title seeds `meta.title`
  deterministically (ensureTitle keeps non-empty titles; tags backfill lazily). Link required by
  design (weak fallback: generic https in the URL FIELD only).
- **D — Cleanup + custom modes**: cleanup (default off) stores per-segment `cleanedText` in
  session.json ONLY — transcript.md is never rewritten; Viewer gets a Verbatim/Cleaned segmented
  switch (Verbatim default, only visible when a cleaned form exists; both views share the same
  `[mm:ss]` seek anchors). Summaries use the cleaned text only while the Cleaned view is active
  (documented). Custom modes: `CustomSummaryMode {name, instructions}` persisted as JSON in
  UserDefaults; editor in Settings; Viewer style picker lists built-ins + customs (segmented control
  unchanged when none exist); outputs cached in `meta.summaries` under namespaced keys
  `"custom:<name>"`; empty template = rejected no-op (`SummaryError.emptyTemplate`, no model call).
- **Out of scope (explicit)**: cross-session voiceprints / speaker enrollment (hook comment in
  `Diarizer.swift`), `DecodingTask.translate` (translation), `OfflineDiarizerManager`, multimodal
  chat images (still macOS-27).

## Decisions / behaviors of note
- **Dock + menu bar** (user changed from the spec's menu-bar-only): `LSUIElement=false`,
  `setActivationPolicy(.regular)`, generated `Resources/AppIcon.icns`, reopen-on-Dock-click.
- **Window opens on launch** — driven from `AppDelegate` (the `@StateObject` init does NOT run at launch
  for a menu-bar app, so launch-time work must go through the AppDelegate hook / `AppModel.shared`).
- **MenuBarExtra `.window` style** (popover) — needed to render the segmented source Picker.
- **Auxiliary windows are manual `NSWindow`s** (not SwiftUI `Window` scenes) for full launch control.
- **One source at a time**; **language pinned to "en"**; **source/model persisted** in UserDefaults.
- **Transcripts → `~/Desktop/Transcripts/`** (user changed from `~/Documents/`).
- **AirPods**: mic capture follows the system default input (AirPods mic works); system-audio capture is
  tapped at the OS mixer pre-output, so it captures audio even when output is AirPods. (Capturing mic +
  system simultaneously — e.g. for calls — is NOT implemented; would be a clean add via the shared sink.)
- **Stage-1 decisions**: deployment target 13→14 (FluidAudio's floor — the only viable way to add the
  dependency via SPM; documented in Package.swift + Info.plist). Detect-once-then-pin for Auto language
  (never per-window — flip-proof; the streamer attaches ~3 s late ONLY in Auto mode). Cleanup is
  per-segment `cleanedText` in session.json only (verbatim transcript.md sacred). Calendar capture uses a
  one-shot `sourceOverride` so a meeting recording never flips the user's persisted source. Meeting
  title seeds `meta.title` (ensureTitle keeps it; tags backfill lazily via the Library).

## Leftover scaffolding (candidate cleanup)
- `debugLog()` writes to `/tmp/transcriber_launch.log` + NSLog on every launch, and `AppDelegate` logs a
  `perms=…` line. Added while debugging the launch/permission issues; harmless and useful, but not
  "production." Safe to remove now that signing is stable (rebuild won't disturb grants). User was asked
  and hasn't decided yet.

## Gotchas (the ones that actually bite)
- Empty/garbled transcript → audio not correctly 16 kHz mono Float32.
- Build errors after dep bumps → API drift; pin the exact tag and read that source.
- Silent system audio → Screen Recording permission missing/stale, or sample buffer not converted right.
- Hotkey does nothing → app not running.
- "App doesn't open" / "permission on but denied" → almost always a **stale running instance** (Quit first)
  or a **signature change** (use the stable identity; `tccutil reset` if needed).
- First run "hangs" → model is downloading (needs internet once, then offline).
- Summary unavailable → Apple Intelligence off / device ineligible / model still downloading (macOS 26 only).
- "On change" captures nothing → high motion (video) never settles → use "Every N s"; or the content is
  near-uniform (dHash ≈ 0) → manual grab (⌥⌘S) or lower CHANGE_THRESHOLD.
- No frames at all → wrong/closed visual target (falls back to main display, logged), or Screen Recording
  not granted for the mic+visual video stream (same grant + relaunch flow as system audio).
- Export disabled → only available after a VISUAL session (needs `session.json`); audio-only sessions
  produce a flat `.md` with nothing to export.
- Audio scoped unexpectedly with system-audio+visual → the shared stream's audio follows the visual target
  (window/app filter = that app's audio; display filter = that display).
- No speaker labels after a session → toggle off, OR the first-run speaker-model download failed
  (needs internet once — retries next session), OR the clip was <1 s / one speaker. Labels appear a
  little AFTER save (post-pass) — the Library/Viewer refresh via `.transcriberSessionSaved`.
- Auto language detects wrong on unusual audio (heavy TTS/music) → by design it pins what it detects
  (or falls back to English on failure); pick an explicit language for critical sessions. Language ID
  needs a multilingual model — `*.en` models always pin "en".
- Calendar trigger never fires → event has no detectable video-meeting link (link required by design),
  Calendar permission denied (feature is silently inert), already recording, or the event already
  fired once this app run.
- Cleaned view missing → cleanup toggle off when the session was saved, Apple Intelligence
  unavailable, or the pass failed (logged; verbatim always intact). Cleanup never alters transcript.md.
