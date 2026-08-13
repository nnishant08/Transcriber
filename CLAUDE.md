# Transcriber

A macOS app for live, **100% on-device** speech-to-text. A global hotkey (⌥⌘T) toggles recording;
audio comes from the **microphone**, **system audio**, or **both at once** (switchable). Live text
streams into a floating window; on stop the transcript is saved to `~/Desktop/Transcripts/` as a
timestamped session folder, then replaced by a full-quality re-transcription (and the source audio is
saved for playback). On-device **Apple Intelligence** powers summaries, **chat with a session**, and
**Ask across all sessions** — all cite/link back to `[mm:ss]`. A **Library** browses + full-text-searches
every session; the **Session Viewer** plays the session back with clickable transcript lines, bookmarks,
summary, and chat. **Screen recording** (⌥⌘S) captures the screen and the audio in one session — one
`screen.mp4`, one transcript, one timeline — and the Viewer plays the video against the words. You can
**import** audio/video files, add live **bookmarks** (⌥⌘B), bias accuracy with a **custom vocabulary**,
and export to SRT/VTT/TXT/RTF/HTML/PDF or share to Notes/Obsidian. **Speaker diarization** labels who spoke when (renameable, color-coded, fully
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
- **Pause/Resume** with **⌥⌘P** (or the Pause button / menu row) — the session stays open, and paused
  time is left out of both the audio and the transcript, so timestamps stay honest.
- Live text shows **confirmed** words solid + the **in-progress** tail dimmed with a caret.
- On **Stop**: the session is saved to `~/Desktop/Transcripts/<date-time>/` (a folder with `transcript.md`
  + `session.json`), a full-quality pass cleans it up, and the **source audio is saved** (`audio.m4a`,
  toggle in Settings, default on) for playback.

**Auto-pause on silence** (Settings ▸ Audio & accuracy, ON by default, 30 s) — when nothing is coming
in (a muted call, a paused video, a break), recording pauses itself and **resumes automatically the
moment sound returns**, replaying a short pre-roll so the first word isn't clipped. The status bar
counts down before it happens and says why afterwards. A pause **you** trigger stays paused until you
resume it, and nothing captured during it is ever recorded.

**It keeps recording through audio changes** — switching output mid-session (plugging into a monitor,
speakers, headphones, AirPods), muting the browser / the Mac / an external speaker, or a capture
stream the OS tears down no longer ends a session. The capture rebuilds itself around the new device
and the session continues; the status bar says "System audio reconnected" and the transcript carries
straight on. Muting only affects what the *speakers* do — system-audio capture is tapped upstream of
volume and mute, so it keeps hearing. Only after several failed reconnects does a session finish, and
then it says why.

**Live bookmarks** — press **⌥⌘B** while recording to drop a marker at the current moment; markers appear
as jump points in the Session Viewer.

**Library** (menu bar ▸ *Open Library*, or the books icon) — lists every session newest-first with title,
date, source, tags, and a snippet. **Search** every transcript (keyword, ranked, with `[mm:ss]`
snippets). Filter by **tag** or **date range**. Per row: **Open** (Session Viewer), **Reveal in Finder**,
**Delete** (to Trash). Also **Ask** and **Import…** buttons.

**Session Viewer** (Open a session from the Library) — one window with:
- the **timestamped transcript** — click any line to **play/seek** there;
- the **screen recording** (when there is one) above the transcript, collapsible, driven by the same
  player bar — clicking a line, bookmark, chapter or `[mm:ss]` citation jumps the video;
- an **audio player** (play/pause/scrub) for audio-only sessions;
- **bookmarks** + **chapters** as clickable jump points;
- a **Summary** panel — switch styles **TL;DR / Detailed notes / Executive**, plus auto **action items**;
- a **Chat** panel — ask questions about that session; answers cite a clickable `[mm:ss]`;
- **Export / Share** (see below).

**On-device AI (Apple Intelligence)** — *Summarize* (3 styles), *Chat with a session* (grounded, cites
`[mm:ss]`), *Ask across all sessions* (menu bar / Library — answers link back to the source sessions),
and automatic **titles + tags**. If Apple Intelligence is off/unavailable, these disable or fall back
cleanly (search still works; Ask still lists matching sessions).

**Import** — drag an **audio or video** file (`.mp3 .m4a .wav .mp4 .mov`) onto the window or the Dock icon,
or use Library ▸ *Import…*. It transcribes into a full session; a video import keeps its video, so the
session plays back in the Viewer exactly like a screen recording.

**Accuracy — custom vocabulary** — add names/acronyms/jargon in Settings; they bias transcription (live and
final). Empty = no change.

**Export & share** — from the Session Viewer's **Export** menu: subtitles **SRT/VTT**, **TXT**, **RTF**
(opens in Word/Pages), **HTML**, **PDF**; **Share…** (system share sheet → Notes, Mail, Messages, AirDrop…);
**Send to Obsidian vault** (set the vault folder in Settings). Copy is available on the summary.

**Screen recording** — press **⌥⌘S** (or *Record screen + audio*) and Said records the screen **and** the
audio in a single session: a `screen.mp4` in the session folder, plus the usual live transcript. Choose
what to record (main display, another display, a window, or one app's windows) and the quality
(720p/15 · 1080p/24 · 1440p/30) in Settings; audio defaults to **Mic + System** so you capture both the
call and yourself. A live preview shows what's being recorded. Pausing (⌥⌘P) cuts that time out of the
video and the transcript together, so `[mm:ss]` always points at the right frame. In the Session Viewer
the video sits above the transcript and every click — a line, a bookmark, a chapter, an AI citation —
seeks it. Leave *Record the screen with every session* on in Settings if you always want both.

**Keyboard shortcuts** (all configurable in Settings): **⌥⌘T** start/stop recording · **⌥⌘P** pause/resume ·
**⌥⌘B** add bookmark ·
**⌥⌘S** record screen + audio. They work globally (from any app).

**Permissions** (first-run onboarding walks these): **Microphone** (for mic / both) · **Screen Recording**
(for system audio + screen recording — *quit & relaunch* after granting) · **Notifications** (optional — a heads-up
when a long transcription / summary / import finishes; degrades silently if denied).

**Where things live** — sessions in `~/Desktop/Transcripts/<date-time>/`. Each folder is self-contained and
movable (`transcript.md` + `session.json` [+ `audio.m4a` / `source.*` for playback] [+ `screen.mp4` when
the screen was recorded]).

**Models** — WhisperKit, on-device: *base.en* (fastest, real-time), *small.en* (balanced), *base* /
*small* (multilingual siblings), *large-v3-turbo* (most accurate, multilingual). Chosen in Settings;
downloads once, then fully offline. The speaker model (FluidAudio) also downloads once, anonymously.

**Good for** — lectures & classes, meetings & standups, calls (Mic + System), interviews, podcasts/videos
(import), voice notes; then summarize, search across everything, or chat to recall details.

**Limits to mention honestly** — on-device AI features need macOS 26 + Apple Intelligence; system audio needs
the Screen Recording grant (and a relaunch after granting); non-English transcription needs a multilingual
model selected; calendar capture needs the optional Calendar grant; speaker names don't carry across sessions
(per-session rename only — cross-session voiceprints are a future build); a screen recording is a real
video file, so long sessions are large (~1–3 GB/hour at 1080p — drop to 720p for all-day capture);
chat reasons over the transcript, not the video's pixels.

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
- System audio: a **Core Audio process tap** (macOS 14.2+, default) with **ScreenCaptureKit** as the
  fallback. Screen recording owns a SEPARATE video-only `SCStream` → AVAssetWriter (H.264 + AAC).
  Microphone: **AVAudioEngine**.
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
  `isRecording`, `isPaused`/`pauseReason`, `source`, `model`, `status`, `summary`, `isSummarizing`.
  Owns the start/stop/**pause** flows, the global-hotkey registration, transcript saving,
  `openTranscriptsFolder()`, `summarizeTranscript()`. Enums: `AudioSource`, `WhisperModel`,
  `EngineStatus` (now incl. `.paused`). Capture is started through `startMic(into:)`/
  `startSystem(into:)` — used by BOTH `startFlow` and the recovery path, so a mid-session
  restart rebuilds a source exactly the way it was first built. Screen recording adds
  `screenRecordingEnabled`/`screenTarget`/`screenQuality`/`screenAudioSource` + `toggleScreenRecording()`. The HUD tick (12 Hz) drives the
  meter/timer AND `updateAutoPause` + `updateCaptureHealth` (the watchdog).
- `TranscriptionEngine.swift` — wraps WhisperKit: `prepare(model:progress:)` (download w/ progress +
  load), `transcribeFile()`, `finalPass()` (VAD-chunked full-quality), `makeStreamer()`. Plus the
  `StreamingTranscriber` actor (rolling-window live transcription) and `TranscriptText` cleanup.
- `AudioSupport.swift` — `CaptureError`, `SampleSink` (thread-safe `[Float]` buffer), `Resampler16k`
  (AVAudioConverter → 16 kHz mono Float32), `CMSampleBuffer.asPCMBuffer`.
- `CaptureControl.swift` — pause / auto-pause / capture-health primitives, deliberately small and
  PURE so they self-test headlessly (`--selftest-pause`). `AudioActivity` (tunables: silence RMS
  0.004, 30 s auto-pause, 1 s pre-roll, 3 s stall), `CaptureGate` (the pause valve every capture
  pushes through — OPEN forwards the exact array, so an unpaused session is byte-identical; CLOSED
  drops samples but keeps measuring level + last-delivery so auto-resume and the watchdog still
  work, retaining ≤1 s of pre-roll), `PauseReason`, `SilenceMonitor` (auto-pause/auto-resume
  decisions; only an AUTO pause resumes itself), `StallMonitor` (recovery decisions + cooldown),
  `SessionClock` (the pause-compressed timeline every timestamp is measured on).
- `AudioCaptureMic.swift` — AVAudioEngine input tap → `Resampler16k` → `SampleSink`. **Survives input
  device changes**: `.AVAudioEngineConfigurationChange` + a `kAudioHardwarePropertyDefaultInputDevice`
  listener (coalesced) rebuild a FRESH engine + tap + resampler around the new device, retrying with
  backoff, and keep pushing into the same receiver. `forceRestart(reason:)` is the watchdog's nudge.
- `AudioCaptureSystem.swift` — ScreenCaptureKit `SCStream` (audio + minimal 2×2 video) → `Resampler16k`
  → `SampleSink`. Tries `SCShareableContent` directly to test Screen Recording authorization.
- `Summarizer.swift` — on-device summary via FoundationModels `LanguageModelSession.respond(to:)`,
  with availability checks.
- `MenuContent.swift` — menu-bar popover (status, source picker, Start/Stop, model/source info,
  Open Transcript Window, **Open Library**, Open Transcripts Folder, Settings, Quit).
- `TranscriptWindow.swift` — control surface: source picker + Start/Stop + Settings, status, Summarize,
  **Open Library**, Open Transcripts Folder, Copy, Clear; the AI-summary panel; the auto-scrolling read-only transcript.
- `SettingsView.swift` — `KeyboardShortcuts.Recorder`, model picker, source picker.
- `Shortcuts.swift` — `KeyboardShortcuts.Name.toggleRecording` (⌥⌘T) + `.togglePause` (⌥⌘P) +
  `.toggleScreenRecording` (⌥⌘S) + `.addBookmark` (⌥⌘B).
- `Theme.swift` — design tokens (light/dark adaptive colors via dynamic NSColor, fonts, radii).
- `TranscriptComponents.swift` — toolbar atoms (ToolbarIcon, SourceSegmented, Summarize/Stop buttons,
  KbdView), RecordingTimer, LiveMeter, InviteCanvas (record ring), DownloadingCanvas (progress ring).
- `TranscriptCanvas.swift` — the recording/review transcript (gutter timestamps + serif body, confirmed
  solid + dimmed hypothesis tail + blinking caret) + SummaryCanvas.
- `ScreenRecorder.swift` — the screen-recording feature. `ScreenTarget` (display / window / app,
  persisted) + `ScreenTargetOption` + `ScreenQuality` (720p·15 / 1080p·24 / 1440p·30, with the H.264
  bitrate derived from the encoded size). `ScreenRecorder` owns a video-only `SCStream` and is ALSO a
  `SampleReceiver`, so the session's own 16 kHz mono audio is encoded into the video's AAC track live —
  no second capture, no post-hoc remux of a multi-GB file. Frames are stamped on the pause-compressed
  `SessionClock` time (`sessionTime()`), so a pause removes the same span from video, audio and
  transcript. `ScreenWriter` (same file) is the encoder — AVAssetWriter + a pixel-buffer adaptor + an
  audio input, with NO ScreenCaptureKit, which is what lets `--selftest-screenrec` verify it headlessly.
  `finish(endingAt:)` ends the session at the true session length because SCK sends nothing while the
  screen is static; the first accepted frame is stamped at 0 so playback never opens on black.
- `DocumentBuilder.swift` — `TranscriptSegment`/`SessionMeta`/`SessionDoc`; the timestamped transcript →
  Markdown and self-contained HTML; session-folder layout; `writeSession`/`readSession`.
  `SessionMeta.videoFile`/`videoWidth`/`videoHeight` name the session's video (`screen.mp4`, or a copied
  import); `SessionDoc` decodes explicitly so a pre-screen-recording `session.json` (which carries a
  `frames` array from the removed screenshot feature) still loads — the key is ignored.
  `SessionMeta` carries `title`/`tags`/`schemaVersion` AND (Prompt 2) `audioFile`/`durationSeconds`/
  `bookmarks`/`chapters`/`actionItems`/`summaries`/`imported` — all `decodeIfPresent` so OLD session.json
  still decodes. Defines `Bookmark`/`Chapter`. `writeSessionJSON` writes ONLY session.json (leaves
  transcript.md untouched — used by migration, title backfill, and Viewer artifact caching).
  `makeSessionFolder(date:withImages:)`.
- `Exporter.swift` — single-file HTML (base64-embedded images) + PDF (via `WKWebView.createPDF`).
- `SessionStore.swift` — the unified on-disk store. `SessionInfo` (listing row), `allSessions()`,
  `sessionDirectoryURLs()`; markdown→plain-text + snippet + `[mm:ss]` helpers; `ensureTitle(dir:)`
  (on-device title/tag backfill, updates session.json only); `migrateLegacyFlatFiles()` (non-destructive,
  idempotent, backs up first); `TitleBackfill` actor (serial, throttled). Defines `.transcriberSessionSaved`.
- `TitleGenerator.swift` — on-device auto title + ≤5 tags via FoundationModels (same `#available(macOS 26)`
  pattern as `Summarizer`); defensive parse/sanitize (strips markdown-wrapped `**Title:**`/`**Tags:**`
  labels, word-boundary tag cap); `generateTags` (focused tags-only prompt — more reliable than the
  combined title+tags prompt on long inputs); deterministic `fallbackTitle` when AI is unavailable.
- `SearchIndex.swift` — in-app keyword inverted index over each session's `transcript.md`.
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
  Text-only: chat reasons over the transcript, not the video's pixels.
- `Subtitles.swift` (C1) — `srt`/`vtt(dir:)` from timed segments (or `[mm:ss]`-derived), sanitized to
  monotonic non-overlapping cues; nil when a session has no usable timing.
- `Sharing.swift` (C3) — `NSSharingServicePicker` share sheet (Notes/Mail/…) + Obsidian (write `.md`
  into a vault folder, or `obsidian://new`). NO AppleScript/Automation.
- `AudioFile.swift` (B1/B2/B3) — `AudioFileIO` (decode any audio/video → 16 kHz mono via AVAudioFile or
  AVAssetReader; write compact AAC `.m4a`/`.caf`; `AVAssetImageGenerator.image(at:)` frame extraction) +
  `AudioMixer` (sums mic+system `SampleReceiver` ports into the shared sink with headroom + a limiter).
- `Importer.swift` (B1) — drag-drop / Import… of audio & video → a full session folder via `DocumentBuilder`
  (transcribe + finalPass; a video import is COPIED in as `source.<ext>` and recorded as `meta.videoFile`,
  so it plays in the Viewer like a screen recording — skipped above 8 GB). Off the recording path.
- `Notifier.swift` (D3) — `UserNotifications` wrapper; lazy auth, silent no-op when denied; guards the
  no-bundle (CLI self-test) case so the same binary never traps.
- `SessionViewer.swift` (the new in-app surface) — `SessionViewerModel` + the Viewer: clickable timestamped
  transcript, ONE player bar over two engines (`AVPlayer` + an `AVKit` video pane when the session has a
  video, else `AVAudioPlayer`; every seek goes through `goTo`), summary suite (style switcher,
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
  sourceText:)` delegates summary/custom kinds to `Intelligence` (byte-identical output,
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
- `AudioCaptureProcessTap.swift` — the DEFAULT system-audio backend (`useProcessTap`, default ON).
  A Core Audio **process tap** (`CATapDescription(stereoGlobalTapButExcludeProcesses:)` excluding our
  own pid + `AudioHardwareCreateProcessTap` + a private aggregate device + `AudioDeviceIOProcIDWithBlock`)
  → `Resampler16k` → the same `SampleReceiver` every other capture uses, so the streamer / finalPass /
  mixer / diarization are untouched. `muteBehavior = .unmuted` and `isPrivate = true`, so tapping never
  alters what the user hears and no device appears in Sound settings. Unlike the SCK path this hears
  EVERY process — window or not, foreground or not — and is independent of the output device, its
  volume, and its mute. `@available(macOS 14.2)` (two minors above the deployment target), so all entry
  points are `#available`-gated. `AppModel.startProcessTap` returns false → the SCK path runs verbatim
  when: the toggle is off, OS < 14.2, or the tap can't be created. (Screen recording no longer forces
  the fallback — the recorder owns its own video-only stream, so the tap stays the audio backend.) **Self-healing across device changes**:
  `buildChain()` (tap → format → private aggregate → IOProc → start) is the ONE construction path,
  used by `start()` AND by `restartCapture(reason:)`, which rebuilds it in FULL — tap included.
  Rebuilding only the aggregate around a surviving tap was not enough (see the device-change finding
  under Gotchas), and re-creating the tap is also the only way to re-read `kAudioTapPropertyFormat`,
  which a stale `tapFormat` would otherwise turn into silently-dropped buffers. Four triggers:
  default-output device change, device-LIST change while our clock device is no longer the default,
  and a 1 Hz watchdog with **two** signals — no IO callbacks for 3 s (aggregate died) and callbacks
  arriving but carrying no nonzero samples for 12 s (stream alive but deaf; bounded to 3 restarts via
  `zeroRestarts`, since genuine silence is indistinguishable). Restarts retry with backoff, are
  serialized by `rebuilding`, and `onStreamStopped` fires only once they're exhausted.
- `SysAudioProbe.swift` — the `--selftest-sysaudio` LIVE diagnostic. Read-only CoreAudio helpers
  (`defaultOutputDevice`/`deviceName`/`isMuted`/`volume`) + a capture loop that tabulates captured
  RMS / peak / exact-zero % against the output device's mute + volume twice a second. Diagnostic
  only — it touches nothing on the recording path. See the system-audio findings under Gotchas.

## Data flow
Capture (`AudioCaptureMic` **or** system audio — `AudioCaptureProcessTap` by default, falling back to
`AudioCaptureSystem`; see the source map) → `Resampler16k` → **`CaptureGate`** (pause valve + level /
liveness probe; a no-op passthrough while open) → shared
`SampleSink` (16 kHz mono Float32). When a screen recording is live, a `SampleTee` sits at that last hop
and hands the SAME samples to `ScreenRecorder` for the video's audio track; with no screen recording
there is no tee at all. `StreamingTranscriber` consumes the sink: each ~1 s it re-transcribes
the buffer from `lastConfirmedEnd` (`DecodingOptions.clipTimestamps`), confirms all but the last 2
segments, and publishes confirmed + hypothesis text — so live text grows without duplication (this
replicates WhisperKit's own mic-only `AudioStreamTranscriber` algorithm). On Stop: write the session
folder's live `transcript.md`, run one VAD-chunked `finalPass()` over the whole buffer, overwrite with
the clean version, then (off-main) index it + auto-title/tag (see Unified session store below).

> **Unified session store (Prompt 1):** EVERY session saves as a folder
> `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/` (`transcript.md` + `session.json`, plus the media it
> produced — `audio.m4a`, and `screen.mp4` when the screen was recorded). This replaces the old
> audio-only flat `transcript-….md`. Legacy flat files are migrated once on launch
> (`SessionStore.migrateLegacyFlatFiles`): non-destructive (one full backup to
> `~/Desktop/Transcripts_backup_<stamp>` first), copy-then-verify-then-remove, idempotent (re-run =
> no-op). Export (HTML/PDF/TXT/RTF) is available for any saved session.

## Pause, auto-pause & capture resilience — Sources: CaptureControl / AppModel / AudioCaptureMic / AudioCaptureProcessTap / ScreenRecorder
**A session must survive everything except the user pressing Stop.** All three features below share
one idea: the SESSION (sink, streamer, timeline, session folder) is long-lived, and the CAPTURE
underneath it is disposable and replaceable.
- **Pause (⌥⌘P / button / menu row).** `isPaused` + `pauseReason ∈ {manual, silence}`; the session
  stays `isRecording` and `status` becomes `.paused`. Pausing CLOSES the `CaptureGate`s — capture
  keeps running (so the level is still measured), but its samples are dropped. **Paused time is
  therefore absent from the audio**, which is why every other timestamp is measured on
  `SessionClock` (wall clock minus accumulated pause): the HUD timer, ⌥⌘B bookmarks, and screen-
  recording frames (`ScreenRecorder.setPaused(_:totalPaused:)`, which also stops encoding frames).
  Without that, a 5-minute pause would push every later marker 5 minutes past the audio it names —
  and the video would drift 5 minutes ahead of its own transcript.
- **Pre-roll is replayed ONLY on an automatic resume.** The gate retains ≤1 s while closed. An
  auto-resume flushes it (the word that triggered the resume would otherwise be clipped); a manual
  resume — and stopping from a paused state — DISCARDS it. Audio captured during a pause the user
  asked for must never reach the session.
- **Auto-pause / auto-resume** (`autoPauseEnabled` default ON, `autoPauseSeconds` default 30).
  `SilenceMonitor` runs on the 12 Hz HUD tick over `max(micGate.level, systemGate.level)` — the raw
  block RMS measured BEFORE the gate, which is what makes hearing audio return while paused possible.
  Silence is `rms < 0.004` (a live mic's room tone is ~0.001–0.003, speech ~0.02–0.15), so normal
  gaps between sentences never trip it. Only a `.silence` pause auto-resumes; a manual pause is the
  user's decision. Status bar counts down ("auto-pausing in 8s") then explains itself.
- **Capture recovery.** `handleSystemStreamStopped` used to call `stopRecording()` — that is what made
  "I plugged in a monitor / muted the browser" look like "it just stopped transcribing". It now calls
  `recoverSystemCapture`, which tears the backend down, waits 400 ms for the device transition to
  settle, and re-runs `startSystem` (tap first, SCK fallback) into the SAME gate; the session, sink,
  streamer and timeline never notice. Only after **4 consecutive failures** does it finalize, and then
  with `pendingStopMessage` so the finished session says why instead of showing a bare "Idle".
- **Watchdog** (`StallMonitor`, 3 s stall / 6 s cooldown, per source). A live capture delivers buffers
  continuously — zero-filled when nothing plays — so "no buffers at all" is the one unambiguous signal
  that a source died silently. Mic → `mic.forceRestart`; system → `recoverSystemCapture`. Each backend
  ALSO self-heals internally (see the source map), so the watchdog is the second net, not the first.
- **Alive-but-silent net.** The failure a callback watchdog CANNOT see: capture delivering, every
  buffer digital silence. `updateCaptureHealth` therefore also recovers the system source after 15 s
  of `recentAllZero` while NOT paused — bounded to 2 rebuilds per session, 45 s apart, because
  genuinely silent audio is byte-identical to a deaf stream. This is the layer that covers the SCK
  backend (which has no internal self-heal) and anything the tap's own restarts didn't fix.
- **Mute is not a failure.** Output mute/volume sit downstream of both capture paths (measured — see
  Gotchas), so muting changes nothing about capture. Muting the SOURCE app (a browser tab) really does
  produce silence; that is exactly the case auto-pause handles gracefully.
- **Non-regression:** an OPEN gate forwards the exact array it was handed, so with no pause and no
  device change a session is byte-identical to pre-pause behavior. `--selftest-pause` asserts that
  passthrough plus every decision above; the full sweep asserts nothing else moved.

## Screen recording — Sources: ScreenRecorder / AppModel / SessionViewer / DocumentBuilder
**The screen recording and the transcript are ONE document.** That is the whole design constraint: any
screen recorder can write an `.mp4`; the reason to do it inside Said is that every `[mm:ss]` in the
transcript points at a frame, and every click in the Viewer moves the video.
- **Start it** with ⌥⌘S, the *Record screen + audio* control (invite canvas, toolbar, menu-bar popover),
  or by leaving *Record the screen with every session* on in Settings. `toggleScreenRecording()` sets the
  flag for this session and applies `screenAudioSource` as a ONE-SHOT `sourceOverride` (default Mic +
  System) — a screen recording never silently inherits a mic-only pick, and never changes the user's
  persisted source. During a session it stops the session, so one key both starts and ends it.
- **One clock.** Video PTS = `SessionClock` time (wall clock − paused time), the same clock the audio
  gate, bookmarks and segment timestamps use. Paused stretches are absent from the video, the audio AND
  the transcript, so all three stay aligned no matter how many times the session is paused.
- **One audio stream.** `ScreenRecorder` is a `SampleReceiver`. The session's own 16 kHz mono samples —
  post-gate, post-mixer, i.e. exactly what is transcribed — are encoded straight into the video's AAC
  track. No second capture (no extra permission, no drift), and crucially no post-hoc remux: muxing a
  multi-GB screen recording at save time would rewrite the whole file.
- **Stream topology.** The recorder owns a SEPARATE video-only `SCStream`; `AudioCaptureSystem` went back
  to its verified audio-only 2×2 config, and the Core Audio process tap stays the default audio backend
  even while recording the screen (previously visual capture forced the weaker SCK audio path).
- **Sparse frames are correct.** ScreenCaptureKit only delivers changed frames, so a static screen writes
  nothing. Two consequences are handled: the FIRST accepted frame is stamped at 0 (else playback opens on
  black while SCK warms up), and `finish(endingAt:)` ends the session at the true session length (else a
  recording that ends on a still frame would be shorter than its own transcript).
- **Dropped, never blocked.** If the encoder isn't ready, the frame is dropped — a dropped frame just
  holds the previous one on screen, whereas blocking would stall the SCK queue. Only the first frame
  waits (≤100 ms) for the encoder to come up.
- **A dead capture doesn't kill the session.** If the recorded window closes or the display is unplugged,
  `handleScreenStopped` finalizes the video, keeps the audio + transcript running, and says so in the
  status bar. The transcript is the thing you can't re-create.
- **Failure at START is fatal, by design.** The recorder is started BEFORE audio capture, so a missing
  Screen Recording grant fails the whole start cleanly instead of leaving a running session with a
  silently dead video.
- **In the Viewer**: the video sits above the transcript (collapsible), and ONE player bar drives either
  engine — `AVPlayer` when the session has a video, `AVAudioPlayer` when it's audio-only. Every seek
  entry point (line, bookmark, chapter, `[mm:ss]` citation) goes through `goTo`, so both behave
  identically. Encrypted sessions (Feature C4) decrypt to a temp file for playback, like audio does.
- **Library**: a *Screen recordings* smart collection, `has:screen` search token, and row thumbnails
  generated from the video (a poster frame ~10% in; skipped for encrypted sessions rather than writing
  plaintext to disk for a listing row).

## Unified store, Library & full-text search (Prompt 1 — Sources: SessionStore / TitleGenerator / SearchIndex / LibraryWindow / DocumentBuilder / AppModel)
- **One layout for all sessions** — folders with `transcript.md` + `session.json` (+ `audio.m4a` /
  `screen.mp4`). `AppModel.startFlow` always `makeSessionFolder(date:)`. Migration on launch (see Data
  flow). NOTHING here touches capture / streaming / `finalPass` / hotkeys / signing.
- **Auto title + tags** — after `finalPass`, `SessionStore.ensureTitle(dir:)` runs OFF the save path
  (`Task.detached`): on-device via `TitleGenerator` (FoundationModels, `#available(macOS 26)`) → a ≤8-word
  title + ≤5 lowercased/deduped tags, stored in `session.json` via `writeSessionJSON` (transcript.md never
  re-rendered). Unavailable AI / empty transcript → deterministic fallback title (first words / date),
  empty tags. Saving NEVER fails or blocks on titling. Migrated/legacy sessions are titled lazily by the
  `TitleBackfill` actor (serial, 300 ms apart) when the Library first lists them.
- **Library window** (`WindowManager.showLibrary`, manual NSWindow like Transcript/Settings; reachable from
  the menu-bar popover and the Transcript toolbar). Lists sessions newest first (title/date/source, screen
  badge, snippet, tags); tag + date-range filters; Open (`transcript.md`) / Reveal in Finder /
  Delete-to-Trash (`NSWorkspace.recycle`, never hard-delete). Live-refreshes via `.transcriberSessionSaved`.
- **Cross-session search** (`SearchIndex`, in-app, on-device, NO Spotlight) — tokenized case-insensitive
  inverted index over each `transcript.md`. Built from
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
  Text-only (multimodal image input is absent in the macOS 26 SDK).
- **Capture coverage (B)** — *highest regression risk; all gated off by default.*
  - **Import** (`Importer`/`AudioFileIO`): drag-drop or Import… of `.mp3/.m4a/.wav/.mp4/.mov` → a full
    session folder (audio decode → `transcribeSamples` + finalPass; a video import is copied in and
    recorded as `meta.videoFile`, so it plays against the transcript). Opens in the Viewer.
  - **Mic + System** (`AudioSource.micPlusSystem` + `AudioMixer`): both captures resample to 16 kHz mono
    and feed an `AudioMixer` (sum × 0.85 + hard limit) into the ONE shared `SampleSink`; the existing
    single `StreamingTranscriber`/`finalPass` run UNCHANGED downstream. The capture sources
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
- `--selftest-screenrec [out.mp4]` — the screen-recording ENCODER, headlessly (no ScreenCaptureKit, no
  permission): synthetic BGRA frames + synthetic 16 kHz audio → one `.mp4`; asserts a video track AND an
  audio track, the requested duration (frames stop early, `finish(endingAt:)` must still end at the true
  length), and that an out-of-order frame is rejected rather than written.
- `--selftest-screenrec-live [seconds]` — LIVE probe: records the real main display for N seconds while
  feeding synthetic audio through the same `SampleReceiver` path. Needs the Screen Recording grant, so
  run the BUNDLE binary: `./Said.app/Contents/MacOS/Said --selftest-screenrec-live 8`.
- `--selftest-doc` — synthetic segments + frame events → prints merged Markdown; asserts ordering.
- `--selftest-export [session-folder]` — builds HTML + PDF (synthesises a session if none). Runs a main
  run loop so WKWebView can render the PDF.
- `--selftest-migrate [dir]` — synthesises legacy flat `.md` files, migrates, and asserts each became
  `<name>/transcript.md` + `session.json`, bytes preserved, a backup exists, and a 2nd run is a no-op.
- `--selftest-index [dir]` — synthesises sessions, builds `SearchIndex`, runs
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
  `--selftest-bookmarks` (persist + reload from session.json; legacy → empty).
- **Pause / resilience:** `--selftest-pause` (pure, no audio hardware) — an OPEN `CaptureGate` is a
  byte-identical passthrough; a CLOSED one records nothing yet still measures level + delivery;
  pre-roll caps at 1 s, flushes on an auto-resume and replays NOTHING on a manual one; auto-pause
  fires only at the threshold (and never on the gaps between sentences), auto-resume only for an
  automatic pause, disabled ⇒ inert; `StallMonitor` respects the cooldown; `SessionClock` excludes
  paused time so a bookmark after a pause matches the recorded audio length. `--retag [dir] [--force]`
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
  terms and writes NO cache file). All write only to temp dirs.
- `--retag [dir] [--force]` — maintenance utility (NOT a self-test): fills missing tags on titled-but-
  untagged sessions (keeps the title; skips near-empty `[BLANK_AUDIO]` transcripts) via `generateTags`.
  `--force` regenerates tags even on already-tagged sessions. Defaults to `~/Desktop/Transcripts`.
- `--selftest-sysaudio [seconds]` — LIVE diagnostic (NOT headless; needs the Screen Recording grant, so
  run the BUNDLE binary: `./Transcriber.app/Contents/MacOS/Transcriber --selftest-sysaudio 30`). Prints,
  twice a second, the captured RMS / peak / exact-zero % alongside the default output device's live
  mute + volume, plus the `recentAllZero` verdict the status-bar warning uses. This is the tool for
  "system audio recorded nothing" reports — it separates "the OS handed us digital silence" from
  "the app broke". See the system-audio findings under Gotchas.
- `--selftest-processtap [seconds]` — the SAME probe through the Core Audio process tap. Run it back
  to back with `--selftest-sysaudio` against one source to compare backends; with a windowless source
  (`afplay tone.wav &`) SCK reads 100% zeros and the tap reads real audio. Set
  `TRANSCRIBER_PROBE_OUT=/tmp/cap.wav` on either probe to dump the captured samples as 16 kHz mono
  WAV, then feed that file to `--selftest` to prove capture → transcription end to end.
Test clips were made with `say` + `afconvert` (`/tmp/transcriber_test.wav`, `/tmp/tr_long_48k_stereo.wav`).
The encoder self-tests pass headlessly; the LIVE capture path (real SCStream video) needs a real screen +
Screen Recording grant + on-screen content — use `--selftest-screenrec-live` from the app bundle, or the app.

## Status — all DONE & user-verified
- [x] Menu-bar + Dock app launches (opens the control window on launch).
- [x] WhisperKit file transcription, model download + offline caching.
- [x] Streaming pipeline (resample, rolling-window dedup) + full-quality final pass.
- [x] Live **mic** transcription (user-verified, incl. via AirPods mic).
- [x] Live **system-audio** transcription (user-verified, incl. while listening on AirPods).
- [x] Global hotkey ⌥⌘T; auto-save timestamped `.md` to `~/Desktop/Transcripts/`.
- [x] On-device AI summary (Apple Intelligence) via the Summarize button.
- [~] **Screen recording (replaces Visual Capture)** — the screenshot/slide feature was REMOVED (its
      four files, the ⌥⌘S grab, the OCR pass, the interleaved image timeline, `FrameEvent`, and the
      macOS-27 slide-chat hook) and replaced by real screen recording: ⌥⌘S / *Record screen + audio*
      records the screen AND the audio into one session (`screen.mp4`, H.264 + AAC), on the transcript's
      own pause-compressed clock, with the session's own audio muxed in live. Settings pick target
      (display / window / app), quality (720p·15 / 1080p·24 / 1440p·30) and the audio source; a live
      preview card shows what's being captured; the Session Viewer plays the video above the transcript
      with click-to-seek from lines, bookmarks, chapters and AI citations; the Library gained a *Screen
      recordings* collection, a `has:screen` token and video poster thumbnails. Video imports now keep
      their video and play the same way. The process tap stays the audio backend during screen capture
      (previously visual capture forced the weaker SCK path). **Build green; `--selftest-screenrec`
      (encoder: video+audio tracks, true duration, out-of-order rejection) passes, and the whole prior
      sweep is unchanged** (doc / migrate / index / export / import / pause / align / calendar / packs /
      vocab / bookmarks / mix / audio-save / srt / redact / retention / encrypt, plus file + streaming
      transcription byte-for-byte). **AWAITING human smoke-tests:** a real ⌥⌘S recording (display, then a
      single window / app), video+transcript sync after a ⌥⌘P pause, click-to-seek in the Viewer, closing
      a recorded window mid-session (audio must continue), file size at each quality, and a video import
      playing back.
- [x] **Unified session store + Library + full-text search** (Prompt 1) — all sessions save as folders;
      legacy flat `.md` migrate non-destructively (backup + idempotent); auto title/tags on-device with
      fallback; Library lists/sorts/filters with Open/Reveal/Delete-to-Trash + live refresh; keyword search
      across transcripts with ranked, timestamped snippets. `--selftest-migrate`/`-index`/`-title`
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
- [~] **Stage 2 — Generation Studio / Vertical Packs / Privacy & Compliance** —
      Feature A: unified `@Generable` Generation Studio (meeting/clinical/interview/sales/study/creator
      templates) decoding to typed values, cached in `meta.generatedArtifacts`, export incl. flashcard/
      quiz CSV; audio clip + audiogram export; the 3 summary styles + Stage-1 custom modes unified into
      the Studio (identical output via the existing `Intelligence` path/cache). Feature B: Legal/Medical/
      Education/Finance-Sales packs (bundled JSON via `Bundle.module`) merging vocab (empty ⇒ no-op
      preserved) + surfacing templates; `EntitlementProvider` seam grants all (commerce NOT built).
      Feature C: retention auto-delete-to-Trash + per-session Keep + manual purge; non-destructive
      on-device redaction (Viewer Verbatim/Cleaned/Redacted switch + redacted export); compliance panel;
      optional AES-GCM encryption-at-rest seam (OFF = byte-identical passthrough, ON = no plaintext at
      rest + in-memory SearchIndex + optional Touch ID). Feature D (multimodal slide chat) was REMOVED
      with the screenshot feature — chat is text-only. **Build green; ALL self-tests pass** — the 6
      remaining new ones (generate/audiogram/packs/redact/retention/encrypt) AND the entire prior suite
      unchanged (default session.json omits the new keys; file + stream transcription text identical).
      **AWAITING human smoke-tests** (see the Stage-2 checklist: run each Studio template + audiogram,
      enable Medical/second pack, redact a PII session, retention sweep with a Keep, optional encryption
      round-trip + Touch ID, full Stage-0/1 regression sweep).
- [~] **Pause / auto-pause / capture resilience** — ⌥⌘P pause+resume (session stays open, paused time
      excluded from audio AND every timestamp via `SessionClock`); auto-pause after 30 s of silence with
      automatic resume + 1 s pre-roll (pre-roll replayed only on an AUTO resume — never after a manual
      pause or a stop); mid-session device changes and torn-down streams are RECOVERED instead of ending
      the session (mic engine rebuilt on config/input-device change; process-tap aggregate rebuilt on
      output-device change, device-list change, or a 3 s callback stall; AppModel re-runs the whole
      capture start on failure, finalizing only after 4 consecutive failures — with the reason shown).
      **Build green; `--selftest-pause` (25 assertions) passes and the whole prior sweep is unchanged.**
      **USER-VERIFIED via GUI:** manual pause/resume; auto-pause with a custom (5 s) timeout; and
      recovery from a mid-session default-OUTPUT-device switch (USB Audio → MacBook Pro Speakers →
      back), which is what prompted the work. Two bugs found and fixed during that verification:
      (1) the "auto-pausing in Ns" countdown was gated on ≥5 s of quiet, so it never appeared at
      timeouts ≤5 s — it now tracks the final 8 s of whatever is set; (2) a device change rebuilt only
      the aggregate around a surviving tap, which left the tap alive but deaf — see the process-tap
      finding under Gotchas, the single most important thing in this feature.
      **AWAITING human smoke-tests:** auto-resume when sound returns after a real muted call/video;
      ⌥⌘P from another app; the same device switch on Mic and Mic+System (only System Audio has been
      exercised); AirPods connect/disconnect mid-recording; a bookmark dropped after a long pause
      landing at the right place in playback.

## Stage 2 — Generation Studio / Vertical Packs / Privacy & Compliance
**All additive, all OFF or neutral by default. With defaults untouched a session's `transcript.md` is
byte-identical and `session.json` semantically identical to post-Stage-1 (new optional keys absent).
No new SPM deps — everything is a system framework. Non-regression anchors unchanged: capture / streaming
algorithm / finalPass / diarization / hotkeys / signing.**
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
- **D — Multimodal Slide Chat: REMOVED** along with the screenshot feature it depended on (see the Screen
  recording section). Chat is text-only; the `TRANSCRIBER_MACOS27` flag in `build_app.sh` is now inert.
- **Out of scope (explicit)**: server-side FoundationModels routing / Private Cloud Compute / BYOK cloud
  (leaves the device — kept out to preserve the on-device moat), payment / license-key / StoreKit commerce
  (only the entitlement seam exists), full video-clip compositing (audiograms only), cross-session
  voiceprints (Stage 1), reasoning over the screen recording's pixels (chat uses the transcript).

## Stage 1 — Diarization / Multilingual / Calendar capture / Cleanup + custom modes
**All additive, all OFF or neutral by default — with defaults untouched, a session's transcript.md is
byte-identical and session.json semantically identical to pre-Stage-1 (new optional keys are simply
absent).** Non-regression anchors: the capture layer / streaming algorithm / finalPass / hotkeys /
signing are untouched; diarization + cleanup run as post-saves off the save
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
  **MEASURED on macOS 26.5.2 (2026-08-04) with `--selftest-sysaudio`, so don't re-guess these:**
  - **Muting the speaker / dropping output volume to 0 does NOT affect capture.** SCK's tap sits
    UPSTREAM of the output device's mute and volume — a 0.1-amplitude tone read a constant 0.0707 RMS
    through mute, through 10% volume, and through volume 0, with Chrome AND QuickTime as the source.
    A user reporting "can't transcribe when the speaker is off" has a DIFFERENT root cause; reproduce
    with the probe rather than accepting the stated trigger.
  - Source-app window hidden or minimized → also does NOT affect capture.
  - **A windowless process IS dropped by the SCK path** — this is why the process tap now exists and
    is the default. `afplay` playing a 40 s tone at full volume produced 100% exact zeros on SCK while
    the stream stayed alive delivering zero-filled buffers: `SCContentFilter(display:excludingWindows:)`
    scopes audio to processes with windows on `content.displays.first`, so background/CLI audio is
    silently lost. **Head-to-head on the same source at the same moment: SCK 100% zeros, process tap
    0.0707 RMS real audio.** If a report smells like "system audio recorded nothing", check whether the
    SCK fallback was in use (toggle off, or tap creation failed — both NSLogged).
  - **Multi-display is a second SCK trap**: the filter is built from `content.displays.first`, whose
    order is NOT guaranteed to be the main display. Plug in an external monitor and the SCK path can
    scope audio to the wrong screen — a strong candidate for "it used to work before I got a monitor".
    The process tap has no notion of displays, so it's immune.
  - Note that **exact digital zeros are ALSO what genuinely-silent/paused playback produces**, so zeros
    alone don't prove a capture bug — correlate against the probe's mute/volume columns.
  - **A process tap does NOT follow a mid-session change of the default OUTPUT device — the tap
    itself must be re-created.** USER-REPORTED AND USER-VERIFIED FIXED (2026-08-11): switching
    USB Audio → MacBook Pro Speakers while recording stopped transcription; switching back restored
    it. All devices involved are 48 kHz stereo, so a format change was NOT the trigger, and the
    session never ended — callbacks kept arriving the whole time. That is the signature: **the tap
    stayed alive but stopped hearing the audio engine.** Rebuilding only the aggregate around a
    surviving tap (the original implementation, chosen to avoid losing samples) does not fix it.
    Two consequences, both now shipped: `restartCapture` rebuilds the WHOLE chain including the tap,
    and a callback-only watchdog is BLIND to this failure by construction — it needs a second signal
    (callbacks arriving with no nonzero samples). If this is ever re-investigated, discriminate with
    `--selftest-processtap 40` while flipping the output device: "no data" rows = the aggregate
    died; ~100% zeros rows = the tap went deaf. Different bugs, different fixes.
- Recording looks fine but the transcript comes back `[BLANK_AUDIO]` → the status bar now shows
  "no system audio for Ns" (replacing "Listening") once `SampleSink.recentAllZero()` has held for ≥8 s,
  so a dead capture is visible DURING the session. Exact-zero (not "quiet") is the trigger, so a live
  mic's noise floor never fires it, and for Mic+System a working mic keeps it quiet.
- Recording "stopped by itself" mid-session → check the log before assuming a crash. `[Recover]` /
  `[ProcessTap] … rebuilt` / `[Mic] rebuilt` lines mean a device change was absorbed and the session
  continued; a session only ends on its own after 4 consecutive failed reconnects, and then the
  status bar carries the reason. `[Pause] paused (auto — silence)` means it auto-paused, not stopped.
- Transcript looks like it skipped time → an auto-pause dropped a silent stretch, by design. Session
  timestamps are RECORDED time, not wall-clock: a 40-minute call with 10 minutes of silence saves ~30
  minutes of audio, and every `[mm:ss]`, bookmark, and video frame lines up with that audio. Turn auto-pause
  off in Settings if wall-clock alignment matters more than the dead air.
- Auto-pause never fires on a live mic in a noisy room → correct: the threshold (RMS 0.004) is above a
  typical noise floor but a loud fan/AC can sit above it. Raise the silence threshold in
  `AudioActivity` rather than the timeout if this ever needs tuning.
- Hotkey does nothing → app not running. (⌥⌘P is a no-op unless a session is live.)
- "App doesn't open" / "permission on but denied" → almost always a **stale running instance** (Quit first)
  or a **signature change** (use the stable identity; `tccutil reset` if needed).
- First run "hangs" → model is downloading (needs internet once, then offline).
- Summary unavailable → Apple Intelligence off / device ineligible / model still downloading (macOS 26 only).
- Screen recording produced no video → the recorded window/app was closed (the recorder falls back to the
  main display when the target is already gone at start, and logs it), or Screen Recording isn't granted
  (same grant + quit-and-relaunch flow as system audio). A recording with zero frames writes no file at
  all rather than leaving a 0-byte stub.
- Screen recording looks short / ends on a frozen frame → correct: ScreenCaptureKit only delivers frames
  when pixels change, so a static screen writes nothing and the last frame is held to the end. The file's
  DURATION is still the true session length (`finish(endingAt:)`).
- "The video and the transcript are out of sync" → they're measured on the same pause-compressed clock,
  so check whether the session was paused (that time is cut from both, by design). A mid-session video
  restart is NOT possible — if the capture died, the video simply ends early and the transcript continues.
- Screen recordings are big → ~1–3 GB/hour at 1080p·24. Settings ▸ Screen Recording ▸ Quality drops it to
  720p·15 for long captures.
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
