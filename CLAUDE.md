# Said

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

> Status: everything through **Stage 2** is shipped and human-verified — the unified store, Library
> and search; chat & intelligence, capture coverage, output & accuracy, UX & trust; Stage 1
> (diarization / multilingual / calendar capture / cleanup + custom modes); Stage 2 (Generation
> Studio / vertical packs / privacy & compliance) and screen recording. The pause /
> capture-resilience work is built and partly verified.
>
> **Phases 1 and 2 are built and self-tested, awaiting human smoke-tests.**
> **Phase 1** made the package **`SaidKit` (macOS + iOS) + `Said` (the macOS app)**: every macOS
> assumption in the shared code is an injectable seam, sessions have a stable `id` and can be handed
> over as a `.said` bundle, and the app carries the settled violet/amber/ink identity.
> **Phase 2** restored the frame/OCR timeline to `SaidKit` and taught the Mac to RENDER it — the Mac
> still has no way to capture a frame; see **Frame timeline** for the four rules that keep it that
> way. **Phase 3 builds the iPhone app**, which is the only thing that will ever capture frames, and
> is written against THIS FILE — see **Design system** for the visual contract and the iOS screen
> inventory. The user iterates with Claude from here.

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

**Calendar-aware capture (bot-free)** — optional: Said watches your calendar (read on-device
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
audio in a single session: a `screen.mp4` in the session folder, plus the usual live transcript.
**With more than one display connected it asks which screen to record before it starts** — named the
way your Displays settings names them ("Built-in Retina Display", "MSI MAG342CQ") — and records the
one you pick, so a recording never silently lands on the laptop screen while you present on the
monitor. Return accepts the highlighted default; Cancel cancels the recording. With one display, or
with a window/app chosen in Settings, it doesn't ask (and the asking can be turned off there). Choose
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
movable (the transcript + `session.json` [+ `audio.m4a` / `source.*` for playback] [+ `screen.mp4` when
the screen was recorded]). **The transcript is named after its session** — `2026-09-01 14-32 Standup
with Priya.md` — so it still says what it is once you've dragged it out of the folder, emailed it or
dropped it in a notes app. Before the on-device title exists it is `<date> <time> Transcript.md`, and
it renames itself the moment the title is generated. Sessions recorded before this change keep the
old `transcript.md` name and open exactly as they always did.

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

## Design system (SOURCE for any visual work, Mac or iOS)
Reference artifact: **`Design/Said-iPhone-Screens.html`** — the ten iPhone screens drawn on this
identity. It is a picture, not a build input: it is in no target's `resources:`, referenced by
neither `Package.swift` nor `build_app.sh`, and cannot end up inside `Said.app`. **This section is
the contract; the HTML is the illustration.** Tokens live in `Sources/SaidKit/Theme.swift`.

**Identity.** The name is **Said** with an amber full stop — `Said.` The mark is two quote-blobs
side by side on a violet ground: the left white, the right amber. Geometry, proportional to the
icon's edge: **blob 27%, gap 7%, corner radius 50% 50% 50% with the fourth corner at 3%** (the
tail). `Scripts/GenerateIcon.swift` draws exactly this (`shape=doc`, the default) and renders every
size natively rather than downscaling from 1024 — **there is no simplified small variant**, because
the same drawing works down to 16pt.

**The blob is the recurring primitive.** One shape, everywhere, at every scale: the app icon, the
record button, list avatars, bullets, the scrubber thumb, the camera shutter, the toggle knob.

**Palette.** oklch alongside the sRGB hex so future colours are derived in that space, not eyeballed.

| Token | oklch | Hex |
|---|---|---|
| violet (primary interactive) | 0.52 0.20 288 | `0x6949D2` |
| violet pressed | 0.42 0.19 288 | `0x4F2BAC` |
| violet deep (recording ground) | 0.30 0.14 288 | `0x2F166E` |
| violet tint | 0.90 0.07 288 | `0xDBD7FF` |
| violet tint ink | 0.35 0.15 288 | `0x3B2282` |
| amber (live / current speaker) | 0.78 0.13 68 | `0xEEA753` |
| amber pressed | 0.63 0.12 68 | `0xB87A2B` |
| amber tint | 0.92 0.07 78 | `0xFFE0B0` |
| amber mark (highlight) | 0.88 0.11 78 | `0xFFCF82` |
| amber ink (text on amber) | 0.25 0.06 68 | `0x341B00` |
| amber ink 2 | 0.45 0.10 68 | `0x794900` |
| ink | 0.22 0.03 288 | `0x1A1828` |
| ink pressed | 0.15 0.03 288 | `0x0B0917` |
| ink deep | 0.19 0.03 288 | `0x131220` |
| paper | 0.96 0.022 288 | `0xF1F0FF` |
| paper 2 | 0.975 0.015 288 | `0xF6F5FF` |
| card | — | `0xFFFFFF` |
| rule / hairline | 0.88 0.05 288 | `0xD5D3F7` |
| text 2 | 0.50 0.05 288 | `0x615F7F` |
| text 3 | 0.60 0.04 288 | `0x7F7D97` |

**Speaker slots** — eight hues at the same L/C, rotated in oklch so no chip fights another, cycling
past 8. **Speaker 1 is violet and speaker 2 is amber, so a two-person recording reads as the brand.**

| Slot | Light | Dark |
|---|---|---|
| 1 violet | `0x6851C3` | `0xB3A9FF` |
| 2 amber | `0xA54E00` | `0xEEA753` |
| 3 teal | `0x00828F` | `0x17D0D8` |
| 4 pink | `0xA43687` | `0xEE95D1` |
| 5 green | `0x227E00` | `0x89CC7B` |
| 6 rust | `0xB63325` | `0xFF9685` |
| 7 blue | `0x006AC5` | `0x73BDFF` |
| 8 olive | `0x796B00` | `0xC4BC4F` |

**Type roles.** Serif for transcript body. System UI for chrome. **Monospace for timestamps, counts,
eyebrow labels and uppercase section rules** — the mono face now carries labels, not just times.
Structure is unchanged from the Mac pass; only the roles widened. No bundled font files.

**Component vocabulary.** Cards are **stickers**: solid fill, generous radius, a **hard offset
shadow (`0 3px 0` in the rule colour)** — never a soft blur. Primary buttons carry a **4px pressed
edge** in their own darker tone. Chips are pill-shaped and colour-coded **by meaning, not by state
alone**. Radii sit at `windowRadius 14` / `controlRadius 11` / `cardRadius 12` / `rowRadius 8`.

**THE ONE RULE — amber marks whoever is speaking.** In the live transcript, in the session view, on
speaker chips, on citation chips. **Nothing else may compete for amber.** The old record RED is
gone: the record dot, Stop, the meter, "Listening" and the timer are all amber now.

Two consequences, both decisions rather than accidents:
- **Paused is no longer amber.** It was, and amber now means live — the two states cannot share a
  colour. Paused renders in the muted ink/text family, so a held session reads as *quieted*, which
  is what it is, and never competes with live amber or with violet's "this is interactive".
- **`ok` (the "On-device · offline" badge) uses the amber TINT / ink-2 tones**, not full-strength
  amber. It is a permanent badge; at full strength it would compete with a live indicator.
- **Selection stays the SYSTEM accent** (Finder/Mail behaviour). Brand violet is for brand and AI
  surfaces, never for "this row is selected". `summaryEdge`'s pink→indigo→teal gradient is **removed**
  — solid violet. One accent gradient in a three-colour identity is one too many.

**iOS screen inventory** (Phase 2 builds these; one line each on why):
1. **First run** — mic only, one claim. The Mac walks three grants; iPhone needs one to be useful, so the screen spends its space on the promise. Camera is asked for at the first slide capture; Notifications and Calendar move to Settings.
2. **Library** — the single root, with a three-part dock: Library / record / Ask.
3. **Source sheet** — three characters, not three rows: *this room*, *a talk with slides*, *something already recorded*.
4. **Recording** — violet-deep ground; older turns fade back, the live one carries an amber blob and an amber caret.
5. **Camera slide capture** — recording never pauses; the amber timestamp is where the frame lands.
   *"Same Vision pass, same event on the timeline" is true again as of Phase 2, which restored
   `FrameEvent` and `SlideOCR` to SaidKit and taught the Mac to render them.*
6. **Session view** — amber gist card on top, violet task stickers inline where they were said, slide cards on the timeline, one ink player bar across all tabs.
7. **Generation sheet** — grouped by recency first, then built-ins, then enabled packs.
8. **Ask** — the answer in a violet card, then the receipts: amber citation chips, sources as quotes.
9. **Settings** — grouped stickers; **every toggle with a real consequence states what it costs** (a download, a second stored copy, a battery hit) in the line underneath.
10. **Send** — a session is a thing you can hand over: AirDrop a `.said`, or save as Markdown/SRT/PDF.

**Ask occupies the dock's right third on iPhone.** This settles the placement question the Mac
redesign left open — **the Mac should follow the phone** when that redesign is implemented.

**Three constraints that shaped the iOS design — recorded so nobody re-litigates them from the mockups:**
- **Phone-call audio is not capturable.** iOS exposes no API for it and Apple's own call recording is
  Phone-app only. The iPhone sources are *this room*, *a talk with slides*, and *something already
  recorded*. **"Record a call" must not appear in any copy.**
- **Speaker names are not live.** Diarization is a batch pass after stop and names are entered by
  hand; the live view shows `Speaker 1`. Cross-session voiceprint enrollment stays deferred (the hook
  comment in `Diarizer.swift` remains the marker).
- **Screen recording on iPhone is out of scope for Phase 2.** ReplayKit via a broadcast upload
  extension would make it possible, but that is a separate process with its own lifecycle, not a port
  of the Mac's ScreenCaptureKit path. **Camera slide capture is how OCR reaches the iOS timeline.**

## Target & stack
- **TWO TARGETS** (Phase 1). `Package.swift` declares `platforms: [.macOS(.v14), .iOS("18.0")]`:
  - **`SaidKit`** (`Sources/SaidKit`, library product) — the cross-platform core: session store &
    document model, transcription, diarization, on-device intelligence, generation, export, privacy,
    capture primitives, `Theme`. Depends on WhisperKit + FluidAudio ONLY. **It must never acquire an
    AppKit / ScreenCaptureKit / KeyboardShortcuts dependency**; `Scripts/verify_ios_build.sh` is the
    gate that enforces that.
  - **`Said`** (`Sources/Said`, executable) — the macOS app: windows, menu bar, hotkeys, screen and
    system-audio capture, and the whole headless `--selftest-*` suite (which tests SaidKit through
    its PUBLIC API on purpose — the existing suite is the regression proof for the split).
  - `.iOS("18.0")` uses the STRING form deliberately: the `.v18` enum case needs
    swift-tools-version 6.0, and bumping the tools version would switch the package into Swift 6
    language mode (strict concurrency) — a behaviour change this refactor must not make.
- Apple Silicon, **macOS 14+ deployment target** (raised from 13 in Stage 1 — FluidAudio's platform
  floor is macOS 14; the app is built & run on macOS 26, so the bump is functionally harmless).
  **iOS 18+** is the new floor: every dependency is satisfied well below it and nothing in the
  product serves a device that can't reach it. On-device AI stays gated at **macOS 26 / iOS 26**.
  SwiftUI + AppKit. NOTE: the floor bump surfaced `onChange(of:perform:)` deprecation WARNINGS in
  pre-existing view code — left as-is on purpose (presentation files are non-regression territory).
- Built with **Swift Package Manager** — there is **no selected Xcode**, only Command Line Tools, but
  full **Xcode IS installed** at `/Applications/Xcode.app`. `Scripts/build_app.sh` points the build at
  it via `DEVELOPER_DIR` (needed because a dependency uses the `#Preview` macro plugin from Xcode).
  The iOS gate needs Xcode too (`xcodebuild`), and sets `DEVELOPER_DIR` the same way.
- On-device STT: **WhisperKit** (Argmax, CoreML). Model downloads once (~150 MB for base.en), then offline.
- On-device speaker diarization: **FluidAudio 0.15.2** (FluidInference; Pyannote segmentation +
  WeSpeaker embeddings, CoreML/ANE; zero transitive package deps). Models download once, anonymously.
- Meeting detection: **EventKit** (system framework, no SPM entry; optional Calendar permission).
- Global hotkey: **KeyboardShortcuts** (sindresorhus).
- System audio: a **Core Audio process tap** (macOS 14.2+, default) with **ScreenCaptureKit** as the
  fallback. Screen recording owns a SEPARATE video-only `SCStream` → AVAssetWriter (H.264 + AAC).
  Microphone: **AVAudioEngine**.
- On-device AI summary: Apple **FoundationModels** (Apple Intelligence, macOS 26 / iOS 26).
- `.said` session bundles: **AppleArchive** + **System** (`FilePath`), LZFSE. System frameworks —
  no new SPM dependency. Deliberately NOT `ditto`/`zip`: those need `Process`, which does not exist
  on iOS, and this code is shared.
- App Sandbox **disabled on macOS** (personal tool — avoids entitlement friction for TCC + audio).
  iOS sandboxing is Phase 2's concern.

## Build & run
```sh
Scripts/setup_signing.sh      # ONCE: create the stable self-signed identity (so TCC grants persist)
Scripts/make_icon.sh          # ONCE (or when changing the icon): regenerate Resources/AppIcon.icns
Scripts/build_app.sh          # swift build -c release, assemble + sign + de-quarantine Said.app
open ./Said.app               # or run ./Said.app/Contents/MacOS/Said to see logs

Scripts/verify_selftests.sh   # the full headless sweep, ENDING with the iOS gate (SKIP_IOS=1 to skip)
Scripts/verify_ios_build.sh   # the gate on its own: does SaidKit still compile for iPhone?
```
- After `open`, allow **~1–2 s** for LaunchServices; the Transcript window opens on launch.
- **Fully Quit before relaunching** (menu-bar ▸ Quit, or `pkill -f Said.app`) — otherwise `open`
  just re-activates the running instance instead of starting fresh.
- Pinned exact dependency versions live in `Package.swift`. WhisperKit/KeyboardShortcuts APIs drift
  across versions — read the pinned tag's source before changing API calls.
- **`Scripts/verify_ios_build.sh` is a HARD GATE, not a convenience.** It builds the `SaidKit` scheme
  for `generic/platform=iOS` through `xcodebuild` (SPM alone does not cross-compile to iOS reliably)
  and fails loudly on any error. A green macOS build and a green self-test sweep say NOTHING about
  whether the core still compiles for iPhone — one stray `import AppKit` in `SaidKit` and Phase 2 is
  broken with no other signal. It is wired in as the last step of `verify_selftests.sh`.
  It needs the `SaidKit` **library product** in `Package.swift` — that is what makes SPM generate a
  `SaidKit` scheme for `xcodebuild` to build.

## Source map — TWO TARGETS
The split (Phase 1) is the single most important structural fact about this tree. **Before adding a
file, decide which target it belongs in**, by one rule: *does it import AppKit, ScreenCaptureKit or
KeyboardShortcuts, or does it exist only to draw a macOS window?* If yes → `Sources/Said`. If no →
`Sources/SaidKit`. When in doubt, put it in `SaidKit` and let `verify_ios_build.sh` tell you if you
were wrong.

### `Sources/SaidKit/` — the cross-platform core (macOS + iOS)
- `Platform.swift` — **the portability seams.** `SessionLocation` (C1: the session root provider —
  `~/Desktop/Transcripts` on macOS, the app container's Documents on iOS, injectable for tests);
  `SessionTrash` (C2: how a session is destroyed — macOS injects `FileManager.trashItem`, iOS removes
  directly, and the UN-INJECTED macOS default THROWS rather than hard-deleting); `SaidAppInfo`
  (name/version/platform, stamped into `.said` manifests).
- `PlatformUI.swift` — **the ONE AppKit/UIKit `#if` in SaidKit, on purpose.** Both branches are real
  implementations of the same contract: `PlatformFont`/`PlatformColor` typealiases,
  `PlatformColor.dynamic(light:dark:)` (macOS `NSColor(name:)` block / iOS `UIColor(dynamicProvider:)`),
  `dynamicColor`/`dynamicWhite` (the primitives every `Theme` token is built from), and
  `NSAttributedString.saidRTFData()` (macOS keeps AppKit's non-throwing `rtf(from:)` so RTF output is
  byte-identical; UIKit has no `rtf(...)`, so iOS uses the throwing `data(from:)`).
- `SessionBundle.swift` — the `.said` format (see its own section below).
- `SlideOCR.swift` (Phase 2) — a thin, stateless Vision wrapper: `recognize` + perspective
  correction + PNG encoding. **NOT the old `SlideOCR`** — that file was deleted with Visual
  Capture and this one was written fresh and deliberately smaller. It reads images; it never
  captures them, and it never decides when a frame should be taken.
- `Theme.swift` — design tokens (see **Design system**). Imports SwiftUI ONLY; resolution goes
  through `PlatformUI`, so Phase 2's iOS UI uses these same tokens.
- `SessionPaths.swift` — the transcript's name and the single resolver for it (see **Transcript file
  name**). No transcript path is composed anywhere else.
- Everything else that was portable, unchanged in behaviour: `DocumentBuilder` · `SessionStore` ·
  `SessionIO` · `SearchIndex` · `TitleGenerator` · `Intelligence` · `Summarizer` · `Generation` ·
  `GenerationTemplates` · `Packs` (+ `Packs/*.json`) · `Entitlements` · `Retention` · `Redaction` ·
  `Subtitles` · `Exporter` · `SpeakerAlignment` · `Diarizer` · `AudioSupport` · `AudioFile` ·
  `AudioCaptureMic` · `TranscriptionEngine` · `Importer` · `ClipExporter` · `Notifier` ·
  `CalendarMonitor` · `Cleanup` (+ `CustomSummaryMode`) · `CaptureControl`.

### `Sources/Said/` — the macOS app
`Main` (dispatcher + the whole `SelfTest` suite) · `SaidApp` (was `TranscriberApp`) · `AppModel` ·
`WindowManager` · `MenuContent` · `MenuCommands` (`SaidCommands`) · `MainWindow` · `TranscriptCanvas` ·
`TranscriptComponents` · `Materials` (NSVisualEffectView) · `SettingsView` · `LibraryWindow` ·
`SessionViewer` · `AskWindow` · `OnboardingWindow` · `Shortcuts` · `Sharing` (NSSharingServicePicker) ·
`ScreenRecorder` · `AudioCaptureSystem` · `AudioCaptureProcessTap` · `SysAudioProbe`.

### Classification notes (things that could have gone either way)
- **`CaptureControl` → SaidKit.** Not named in the Phase 1 prompt, but it is pure (gate / silence /
  stall / session clock) and Phase 2 needs all of it. It self-tests headlessly on both platforms.
- **`AudioCaptureMic` → SaidKit.** The AVAudioEngine tap → `Resampler16k` → `SampleReceiver` chain is
  identical on both platforms. Its ONE platform difference is the input-route listener, a real
  two-branch seam: macOS uses a CoreAudio `kAudioHardwarePropertyDefaultInputDevice` listener, iOS
  uses `AVAudioSession.routeChangeNotification`. A comment marks where `AVAudioSession` CONFIGURATION
  attaches on iOS — deliberately not added (Phase 2).
- **`Exporter` → SaidKit.** `WKWebView.createPDF` exists on iOS; `NSRect` became `CGRect`; fonts and
  the RTF call route through `PlatformUI`. `Sharing` (NSSharingServicePicker) has no iOS equivalent
  and stays in `Said`.
- **`ClipExporter` → SaidKit, with NO seam.** Its caption burn-in used `NSFont`/`NSColor`/
  `NSGraphicsContext`; it now uses **CoreText** (`CTFramesetter`), which draws identically on both
  platforms against the same `CGContext`. Geometry, size, weight, colour, centring and tail
  truncation are unchanged. *Prefer this move — CoreGraphics/CoreText instead of a `#if` — wherever
  it is available.*
- **`Theme` → SaidKit** despite being presentation: Phase 2's UI needs the same tokens, and the
  light/dark resolver is a legitimate two-branch seam.
- **Image currency in SaidKit is `CGImage`** (and `Data` for PNG bytes) — there is no `NSImage`
  anywhere in the core. Any `NSImage` conversion happens in `Said`, at the view boundary.
- **`SelfTest` stays in `Said`** and tests SaidKit through its public API. Deliberate: the existing
  headless suite is what proves the split was inert, so it must not be rewritten.
- **`FrameChangeDetector` / `SlideChat` / `ScreenCapture` do not exist** — the screenshot feature was
  removed and replaced by real screen recording (see that section). Any prompt or note referring to
  them is stale. **`SlideOCR` DOES exist again as of Phase 2**, but as a new, smaller file serving
  the iPhone's slide capture — see "Frame timeline". `FrameChangeDetector` specifically stays dead:
  it decided when to auto-grab a changing screen, and nothing auto-grabs anything any more.

### File-by-file (behavioural detail; paths are relative to the target above)
- `Main.swift` — `@main AppMain`. Dispatches CLI self-test modes (below) else runs the SwiftUI app.
  Contains `SelfTest` (file / streaming / summary verifiers).
- `SaidApp.swift` (was `TranscriberApp.swift`) — `SaidApp: App` (a single `MenuBarExtra` scene, `.window` style),
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
- `Theme.swift` (SaidKit) — design tokens: the violet/amber/ink identity, the 8 speaker slots,
  radii, metrics, fonts. See **Design system** for the values and the amber rule. Light/dark
  resolution goes through `PlatformUI`, so it imports SwiftUI ONLY and compiles for iOS.
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
- `SessionPaths.swift` — `legacyTranscriptName` · `existingTranscript(in:)` · `transcriptURL(in:)` /
  `transcriptURL(in:for:)` · `isSessionFolder(_:)` · `transcriptFileName(for:)` · `renameTranscript(in:toMatch:)`
  · `safeFileComponent`/`exportFilename`. See **Transcript file name** for the rules and why they are these.
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
- `Exporter.swift` — single-file HTML (base64-embedded images) + PDF (via `WKWebView.createPDF`,
  which exists on iOS too). RTF fonts/colours and the RTF serialization route through
  `PlatformUI`; `NSRect` became `CGRect`. No AppKit import.
- `SessionBundle.swift` (Phase 1) — the `.said` format: `SessionBundleManifest`,
  `write(sessionDir:to:)`, `read(bundle:into:)` (→ `SessionImportOutcome.imported` /
  `.alreadyPresent`), `findSession(id:in:)`. AppleArchive + LZFSE; staging dirs on both sides so
  the manifest never lands in a real session folder and encrypted files are decrypted on the way
  in / re-encrypted on the way out. See its own section above.
- `Platform.swift` (Phase 1) — `SessionLocation` (C1 root provider), `SessionTrash` (C2 delete
  contract; macOS default THROWS if nothing injected), `SaidAppInfo` (name/version/platform).
- `PlatformUI.swift` (Phase 1) — the ONE AppKit/UIKit seam: `PlatformFont`/`PlatformColor`,
  `PlatformColor.dynamic`, `dynamicColor`/`dynamicWhite`, `NSAttributedString.saidRTFData()`.
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
> `~/Desktop/Transcripts/<yyyy-MM-dd HH-mm-ss>/` (the transcript `.md` + `session.json`, plus the media
> it produced — `audio.m4a`, and `screen.mp4` when the screen was recorded). **The transcript has no
> fixed name** — see "Transcript file name" below; `transcript.md` throughout this document means
> "the session's transcript", and is still the literal name for every session recorded before that
> change. This replaces the old
> audio-only flat `transcript-….md`. Legacy flat files are migrated once on launch
> (`SessionStore.migrateLegacyFlatFiles`): non-destructive (one full backup to
> `~/Desktop/Transcripts_backup_<stamp>` first), copy-then-verify-then-remove, idempotent (re-run =
> no-op). Export (HTML/PDF/TXT/RTF) is available for any saved session.

## Transcript file name — Sources: SessionPaths / DocumentBuilder / SessionStore
**A transcript is named after the session that produced it.** `transcript.md` was unambiguous in
code and meaningless out of it: the moment a file left its folder — shared, AirDropped, dropped in a
notes app — it was one of N identical `transcript.md`s. The name is now
`2026-09-01 14-32 Standup with Priya.md`: **date first** so a pile of them sorts chronologically, the
title after it so you can read what it is. Before the on-device title exists the body is the word
`Transcript`; `SessionStore.ensureTitle` renames the file when the title arrives.

- **`SessionPaths` is the ONE resolver.** Nothing composes `dir + "transcript.md"` any more — reads
  go through `SessionPaths.transcriptURL(in:)`, writes through `transcriptURL(in:for:)`, and "is this
  a session folder?" through `isSessionFolder(_:)`. That is what makes the name a detail rather than
  a contract: **the folder is the identity; the file inside it is just named well.**
- **Resolution is `transcript.md` first**, then the single `*.md` in the folder. Every pre-existing
  session therefore resolves in one `stat` and behaves EXACTLY as it did — the legacy name is a fast
  path, not a fallback that costs anything.
- **Nothing on disk is migrated, deliberately.** A mass rename of an existing library is a
  destructive-shaped operation that buys nothing a reader can't already resolve. Old sessions keep
  `transcript.md`, and `writeSession` re-renders IN PLACE when a folder already uses that name, so a
  diarization pass on a 2025 session doesn't leave two transcripts behind.
- **The rename rides on `ensureTitle`** — the moment a session stops being anonymous — and inherits
  that function's laziness for free: an already-titled session returns before the rename, so merely
  listing the Library never renames anything. A collision at the destination is LEFT ALONE rather
  than resolved with a `(2)` suffix; the file staying put costs nothing.
- **Legacy flat-file migration still writes `transcript.md`.** Those are pre-existing sessions whose
  bytes are copied verbatim and verified; `--selftest-migrate` asserts that name and keeps doing so.
- **`SessionIO` encrypts every `.md` in the folder** rather than a fixed name — otherwise
  encryption-at-rest would silently skip the one file that holds the words.
- **One sanitizer.** `SessionPaths.safeFileComponent` / `exportFilename` is what names both the
  transcript and every export/share; `Sharing.exportFilename` delegates to it. It strips
  `/ \ : ? % * | " < >` + newlines, collapses whitespace runs, refuses to author a hidden file, caps
  at 120 chars, and falls back to `Transcript`.
- `--selftest-doc`'s third case is the proof (14 assertions): untitled/titled/unsafe/blank naming, a
  second write leaving exactly one file, the rename preserving bytes and being idempotent, and a
  legacy `transcript.md` folder still resolving and re-rendering in place.

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
- **Which screen is ASKED, not assumed.** `.mainDisplay` means "whatever has the menu bar", which on
  a docked laptop is routinely the wrong screen — and the failure is silent and only discovered after
  the recording. `AppModel.resolveScreenTarget` therefore prompts (`ScreenTargetPrompt`, an NSAlert
  with a popup of `ScreenRecorder.availableDisplays()`) and pins the answer as `.display(id)` for that
  session. Four rules keep it from becoming friction: it asks **only** when there are 2+ displays and
  no explicit window/app target (a window pick IS the answer); the default is preselected so Return
  reproduces the old behaviour; the answer is a ONE-SHOT `screenTargetOverride`, so it never rewrites
  the persisted setting; and an unattended calendar auto-start skips it entirely (`skipScreenTargetPrompt`)
  — nobody is at the keyboard, and a modal left unanswered would mean the meeting is simply not
  recorded. It is an NSAlert rather than a sheet because ⌥⌘S is global: the question can arrive while
  another app is frontmost and the Said window may not be open. Asked BEFORE the model prepares and
  long before T0, so the session clock never runs while the dialog is open. `sessionScreenTarget`
  records what was actually captured, so `meta.targetLabel` names the screen the session really used.
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

## Frame timeline — slides on the transcript (Phase 2 — Sources: DocumentBuilder / SlideOCR / SearchIndex / Exporter / SessionViewer / LibraryWindow)
**The Mac RENDERS frames. It never captures them.** A frame on a Mac arrived in a `.said` bundle
from a phone. This is not a restoration of Visual Capture — read the four rules before touching it.

**Why it exists.** Removing the screenshot feature in favour of real screen recording was right *for
a Mac*: continuous video is a strictly better answer to "capture what was on screen". That reasoning
does not transfer to a phone. There is no screen to record in a lecture theatre — the slides are on
a wall across the room, and video of that wall is large, shaky and unsearchable. A handful of stills
with OCR'd text is the right shape, and **the OCR text landing in the search index — so a session is
findable by a phrase that was only ever on a slide and never spoken — is the actual differentiator.**
The moment iPhone writes frames, the Mac must read them, or a `.said` sent Mac-ward silently drops
the slides. That is the one promise the format exists to make.

**The four rules. Without them the cut feature re-grows:**
1. **Render, never capture.** No ⌥⌘S grab (that key is screen recording), no capture settings, no
   auto-detect, no periodic sampling, no frame capture on video import. Decode, display, index,
   export. `--selftest-frames` and the smoke checklist both police this.
2. **`FrameEvent` stays three fields** — `time`, `imagePath`, `text`. No dimensions, no capture mode,
   no change score, no thumbnail path, no source enum.
3. **`FrameChangeDetector` stays dead.** It existed to decide when to auto-grab a changing screen. On
   a phone the shutter is a finger; there is nothing to detect. `dHash` / `hamming` / the settle
   state machine were NOT resurrected.
4. **Video XOR frames, never both** — enforced, not merely documented (below).

**The model** (`DocumentBuilder.swift`, beside `TranscriptSegment` because it is the same kind of
thing). `FrameEvent.time` is on `SessionClock`'s pause-compressed timeline, like bookmarks and
screen-recording frames, which is what makes a frame line up with the audio it was taken during.
`SessionDoc.frames` is `decodeIfPresent ?? []` and **encoded only when non-empty**, so every session
the Mac records still writes a `session.json` with no `frames` key.

- **The legacy hazard.** Real sessions on disk carry a `frames` array written by the removed feature,
  whose elements were `{sessionTime, imagePath, ocrText}`. That does not decode into today's
  `{time, imagePath, text}` (`time` is non-optional, so it throws). `SessionDoc.init(from:)`
  therefore decodes `frames` **defensively**: a mismatched array yields `[]` and a readable session,
  never an error that makes an old session unopenable. Asserted with a hand-built fixture.
- **The invariant lives in `SessionDoc.visual`** — a validating accessor returning
  `VisualTimeline{.none,.video,.frames}` — rather than only at the write path. The write path can be
  bypassed (a hand-edited `session.json`, a bundle from a future build, a legacy folder), whereas
  every display path has to come through this. **Video wins** if both are somehow present, since it
  is the larger artifact with the continuous timeline, and the condition is logged rather than
  silently resolved. `writeSession` also touches `visual` so a bad session is noisy at write time too.
- **`images/`**, created lazily on first frame write; `slide-0001.png`, zero-padded, monotonic.
  `makeSessionFolder` did NOT regain a `withImages:` parameter. Frame images route through
  `SessionIO`, so at-rest encryption stays transparent.

**`SlideOCR`** (SaidKit) — **a new file, not the old one.** Deliberately smaller: a stateless Vision
wrapper that Phase 3's camera composes. `recognize(cgImage:fast:)` (`.accurate` by default, `.fast`
for a live pre-shutter read-out) joins lines with `" · "` and returns **nil, never `""`**, so
`FrameEvent.text` stays honestly absent. Plus `correctingPerspective(of:)` (`VNDetectRectangles` →
`CIPerspectiveCorrection`) which **returns the original unchanged when no plausible quad is found —
a capture is never lost to a failed correction** — and `pngData(from:)`. `CGImage`/`Data` currency
throughout; no `NSImage`. No camera, no `AVCaptureSession`, no UI: that is Phase 3.

**Transcript, search, export.**
- Markdown interleaves frames by time, matching the removed feature's output exactly so transcripts
  already on disk still parse: `![03:12](images/slide-0004.png)` followed by a `<details>` block of
  OCR text. **On a tie, text comes before the frame.** With no frames the output is byte-identical —
  `--selftest-doc`'s case-1 md5 is unchanged from pre-Phase-2 and proves it.
- **The `[mm:ss]` anchor lives in the image's ALT TEXT, not leading the line, and that is fine.**
  `SearchIndex.extractSnippets` calls `firstTimestamp(in:)` *before* it skips `![` lines, so a hit in
  the OCR text below still carries the frame's timestamp. Verified rather than assumed: **the
  existing tokenizer needed no change and no second index was added.**
- **OCR text does NOT feed auto-titling.** `plainText` includes it (so it is indexed), but a slide's
  bullet points are not what a session is *about*, and a title generated from them reads worse than
  one generated from speech. Left as-is deliberately.
- HTML/PDF export embeds frames as base64 data URIs with the OCR text beneath, styled on the
  **current** identity tokens (violet/amber/ink) rather than the pre-rebrand greys the surrounding
  export CSS still uses. `Subtitles` (SRT/VTT) ignores frames entirely — a subtitle track is speech.

**Mac display.** Viewer frame cards inline at their timestamp — image, mono `[mm:ss]`, collapsible
OCR text — seeking through the existing `goTo`, with **no second seek path**. `activeSegmentID` now
resolves against the merged timeline, so seeking to a frame's time scrolls to the frame card rather
than the speech line before it. Library rows get a first-frame thumbnail (same skip-if-encrypted rule
as the video poster frame) and a slide count, plus a `has:slides` search token.

**`.said` needs no format change and `formatVersion` STAYS 1.** `images/` already round-tripped
(`stageDecrypted` copies directories recursively, `installPayload` recreates them); adding frames
changes the archive's *contents*, not its *structure*. A Phase-1-era Mac reading a Phase-3 iPhone
bundle extracts everything correctly and simply doesn't render the frames — **degradation, not
corruption**. Bumping the version would make old builds refuse the file, which is strictly worse.
`--selftest-bundle` asserts frames survive as data (element for element) and as files (every
`imagePath` resolves).

## Session identity & the `.said` bundle (Phase 1 — Sources: DocumentBuilder / SessionStore / SessionBundle / AppModel / SessionViewer)
**A session is a thing you can hand over.** Until there is an account, moving a session between
devices is a TRANSFER, not a sync — so the thing being moved is one obvious file.

- **`SessionMeta.id: UUID?`** — a stable identity that survives export, import, and being carried
  between devices. **Additive and invisible by default:** `decodeIfPresent` on the way in and
  (synthesized) `encodeIfPresent` on the way out, so a `session.json` written before this field
  existed decodes unchanged AND **is not rewritten merely by being read**.
  - New sessions get one at creation. `AppModel` mints `sessionID` once at start, so the live save
    and the final save write the SAME id. Imports mint one too.
  - Pre-existing folders are backfilled **lazily**, on the exact `ensureTitle` pattern: off the save
    path, `writeSessionJSON` ONLY (never re-renders `transcript.md`), serialized behind the same
    post-save `Task.detached` chain (index → **ensureSessionID** → ensureTitle → Diarization →
    Cleanup) so it cannot race the other passes' read-modify-write. Legacy sessions pick one up via
    the `TitleBackfill` actor when the Library first lists them. `ensureSessionID` on a session that
    already has an id is a complete no-op — no write, no notification.
  - **Why now:** retrofitting an identity onto thousands of existing folders later is strictly worse
    than adding it while the schema is already being touched. Nothing in Phase 1 reads it except the
    bundle's collision rule.
- **`.said` = one session, whole**: `transcript.md`, `session.json`, `audio.m4a`, `screen.mp4`/
  `source.*`, `images/` if present, plus a root `manifest.json`
  (`formatVersion` / `sessionID` / `createdAt` / `producedBy`). Archived with **AppleArchive + LZFSE**
  (system framework; NOT `ditto`/`zip`, which need `Process` — absent on iOS).
- **Encryption interaction.** Export stages the folder through `SessionIO.readData`, which
  transparently strips the `TRENC1` wrapper, so **a bundle always contains plaintext** — an export
  only the origin Mac's Keychain could open would be useless. Import writes back through
  `SessionIO.writeData`, so files are re-encrypted iff the RECEIVING device has encryption on.
  The manifest carries no encryption flag and doesn't need one: `SessionIO` detects the prefix.
- **Collision rule — deterministic.** If a session with the same `sessionID` is already in the store:
  **do not import, do not duplicate** — say "Already in your library" and reveal the existing
  session. Double-clicking the same `.said` twice is therefore idempotent. If the id is absent or
  unknown, a new folder is created with the normal `makeSessionFolder` naming, the incoming id is
  KEPT, and the session is indexed.
- **Mac wiring.** Export: "Send session… (.said)" in the Session Viewer's existing Export menu (the
  menu was not restructured). Import: `AppDelegate.application(_:open:)` → `AppModel.importFiles`,
  which routes a `.said` to `SessionBundle.read` instead of the audio/video `Importer` path;
  everything else about that flow is unchanged. UTI: an **exported** type `com.nikhil.said.session`
  (extension `said`, conforming to `public.data` + `public.archive`) plus a `CFBundleDocumentTypes`
  entry at `LSHandlerRank: Owner`, in the Info.plist assembled by `build_app.sh`. Adding the document
  type does NOT disturb the designated requirement (verified before/after).
- `--selftest-bundle` is the proof: byte-identical `transcript.md`, every `session.json` field,
  `images/` at the same relative path, the id, the collision rule, and an encrypted session exporting
  to a bundle that opens with the key removed entirely.

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

## UI redesign (presentation only — Sources: SaidKit/Theme · Said/MainWindow / TranscriptComponents / TranscriptCanvas / MenuContent)
- **One UI state** drives the window: `AppModel.uiState ∈ {idle, downloading, recording, summary}`, derived
  from `showingSummary`, `isRecording`, and `status.isPreparing`. Titlebar, canvas, and status bar all swap
  per state. Reference mockup: `Design/Said-Mac-Redesign.html` (the layout pass; its RED/indigo palette is superseded by the violet/amber identity in **Design system** — only the structure still applies).
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
- **`.said` document type** — Phase 1 added an exported UTI (`com.nikhil.said.session`) +
  `CFBundleDocumentTypes` entry so the Mac claims `.said` files. Verified NOT to disturb the
  designated requirement (captured `codesign -d -r-` before and after: identical).
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
  act stale: `tccutil reset ScreenCapture com.said.mac` (and `Microphone`), then re-grant.
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
  deployment-target bump; zero package dependencies). **VERIFIED at the tag for Phase 1: its manifest
  already declares BOTH `.macOS(.v14)` AND `.iOS(.v17)`, so the existing pin satisfies the iOS floor
  as-is — NO bump was needed and none was made.** Verified at the tag:
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
- `--selftest-doc` — THREE cases. Case 1 (segments only) is byte-for-byte the pre-Phase-2 output, so
  its md5 stays exactly comparable; case 2 adds frames and asserts they merge by time, that a tie
  puts text before the frame, and that the OCR block appears only when there is OCR text; case 3 is
  the transcript FILE NAME on disk (see **Transcript file name**) — untitled / titled / unsafe-title /
  blank-title naming, a second write leaving exactly one transcript, the rename preserving bytes and
  being idempotent, and a legacy `transcript.md` folder still resolving and re-rendering in place.
  Temp dirs only. The description used to claim "frame events" while none existed — it is accurate
  again as of Phase 2.
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
- **Phase 2 (visual timeline):** `--selftest-frames [dir]` — headless (Core Graphics draws the
  slides, so no camera and no permissions): a synthetic slide OCRs to its own words; a skewed
  photograph of it detects + perspective-corrects and reads no worse than the skew (`>=` rather than
  a strict `>`, because Vision often reads a moderate skew perfectly and a strict improvement would
  be flaky); a featureless image returns the ORIGINAL unchanged rather than nil, a crash, or a
  garbage crop; `FrameEvent`s round-trip through `session.json` and an EMPTY array writes no
  `frames` key; a legacy old-shape `{sessionTime, ocrText}` array decodes to `[]` with the session
  still readable; the video-XOR-frames invariant resolves to video and logs; frames interleave into
  the markdown by time; a phrase only ever on a slide is found by `SearchIndex` and the hit carries
  the frame's `[mm:ss]`; and HTML export embeds the image with the OCR text on current tokens.
- **Phase 1 (cross-platform core):**
  - `--selftest-bundle [dir]` — synthesizes a session (segments, an `images/` frame, a real
    `audio.m4a`, bookmarks, speaker names) with an id; exports to `.said`; imports into a FRESH root
    and asserts `transcript.md` is byte-identical, every `session.json` field matches, `images/`
    round-trips at the same relative path, the id survived, and `manifest.json` did NOT leak into the
    session folder. Then re-imports into the SAME root and asserts the collision rule fires (reports
    `.alreadyPresent`, points at the existing folder, creates no duplicate). Then repeats the export
    with `SessionIO` encryption ON via the `overrideKey` hook, DROPS the key entirely, and asserts the
    bundle still opens as readable plaintext with its id intact. Temp dirs only.
  - `--selftest-portability` — the root provider returns `~/Desktop/Transcripts` by default on macOS,
    honours injection, and resets; `DocumentBuilder.makeSessionFolder` follows it; the trash seam is
    NOT injected in the CLI binary and the un-injected macOS path **refuses rather than hard-deleting**
    (the victim file is asserted to still exist); an injected handler receives the URL; and
    `Bundle.module` resolves `Packs/*.json` from SaidKit.
  - `--selftest-theme` — every `Theme` token resolves to a concrete colour in BOTH appearances (via
    `NSAppearance.performAsCurrentDrawingAppearance`), the eight speaker slots are pairwise distinct
    in both, slot 9 cycles back to slot 1, and slot 0 / negative slots are clamped rather than
    crashing.
  - **`Scripts/verify_ios_build.sh`** — not a `--selftest` mode but the same kind of gate, and the
    LAST step of `verify_selftests.sh`. See "Build & run".
- **Removed modes.** `--selftest-capture`, `--selftest-ocr` and `--selftest-slidechat` no longer
  exist — they tested the screenshot/OCR/slide-chat feature that was replaced by real screen
  recording. `verify_selftests.sh` was still calling all three (i.e. it was failing); Phase 1 removed
  them and added `--selftest-screenrec`, which had never been wired in.
- `--retag [dir] [--force]` — maintenance utility (NOT a self-test): fills missing tags on titled-but-
  untagged sessions (keeps the title; skips near-empty `[BLANK_AUDIO]` transcripts) via `generateTags`.
  `--force` regenerates tags even on already-tagged sessions. Defaults to `~/Desktop/Transcripts`.
- `--selftest-sysaudio [seconds]` — LIVE diagnostic (NOT headless; needs the Screen Recording grant, so
  run the BUNDLE binary: `./Said.app/Contents/MacOS/Said --selftest-sysaudio 30`). Prints,
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
- [x] **Screen recording (replaces Visual Capture)** — the screenshot/slide feature was REMOVED (its
      four files, the ⌥⌘S grab, the OCR pass, the interleaved image timeline, `FrameEvent`, and the
      macOS-27 slide-chat hook) and replaced by real screen recording. **Phase 2 later restored the
      MODEL half of that — `FrameEvent`, `SlideOCR`, the interleaved timeline — for the iPhone, and
      the Mac renders frames but still cannot capture them; see "Frame timeline". The ⌥⌘S grab, the
      auto-detect and `FrameChangeDetector` stayed dead.** The screen recording itself: ⌥⌘S / *Record screen + audio*
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
      transcription byte-for-byte). **HUMAN-VERIFIED:** a real ⌥⌘S recording (display, then a single
      window / app), video+transcript sync after a ⌥⌘P pause, click-to-seek in the Viewer, closing a
      recorded window mid-session (audio continued), file size at each quality, and a video import
      playing back.
- [~] **The screen recording asks which screen** — with two or more displays, ⌥⌘S (and an
      every-session screen recording) prompts with the real display names and records the one picked,
      as a one-shot override that leaves the persisted target alone. Silent when there is one display,
      when a window/app is the configured target, when the Settings toggle is off, or for an
      unattended calendar auto-start. **Build green; the display naming was verified against the live
      `NSScreen` list** (built-in + external, main correctly marked). **AWAITING human smoke-test:**
      the prompt on ⌥⌘S with the monitor attached, recording the external monitor and confirming the
      video is that screen, Cancel cancelling cleanly, Return-only reproducing the old behaviour, and
      a single-display Mac never seeing the dialog.
- [x] **Meaningful transcript file names** — the transcript is named after its session
      (`2026-09-01 14-32 Standup with Priya.md`) instead of a fixed `transcript.md`, renaming itself
      when the on-device title lands. `SessionPaths` is the one resolver; no path is composed by hand
      anywhere (Mac app, SaidKit, self-tests, the in-progress iOS app). Nothing on disk is migrated —
      an old session keeps `transcript.md`, resolves in one `stat`, and re-renders in place. **Build
      green on both platforms; the full 47-mode sweep + the iOS gate + the 16 iOS unit tests pass**,
      with `--selftest-doc` gaining a 14-assertion naming case and its case-1 md5 untouched.
      **AWAITING human smoke-test:** a real session's file name before and after the title lands, a
      pre-existing session still opening / searching / exporting, and a `.said` round trip.
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
- [x] **Prompt 2 — Chat & Intelligence / Capture / Output / UX & trust** — per-session chat (cites
      `[mm:ss]`) + cross-session Ask + summary suite (styles/action-items/chapters, cached); audio/video
      import; Mic+System mixer (off by default, single-source byte-identical); save-audio + clickable
      transcript playback; SRT/VTT + txt/rtf + share/Obsidian; custom-vocab biasing (empty = no-op); live
      bookmarks; onboarding; Recent menu; done notifications; on-device badge; the Session Viewer.
      **Build green; ALL self-tests pass** (9 new + all prior incl. streaming/file transcription unchanged).
      **Adversarial multi-agent review done** (15 confirmed findings, 0 false-positives) → 13 fixed incl.
      the mixer PCM-reordering race (append inside the lock), session.json last-writer-wins (Viewer merges
      only its owned fields + atomic write), import error-status clobber, slider-scrub vs playback, derived-cue
      overlap, 3-digit-minute timestamps, citation markdown. 2 left by design (transient 2nd import model,
      singleton observer token). **HUMAN-VERIFIED** (live mic / live system / Mic+System / playback-seek /
      real file & video import / bookmarks / Notifications prompt / Notes-Obsidian share).
- [x] **Stage 1 — Diarization / Multilingual / Calendar capture / Cleanup + custom modes** — FluidAudio
      0.15.2 pinned (deployment target raised 13→14, its platform floor); speaker labels + per-session
      rename + colors; multilingual models + detect-once "Auto" + `*.en` guard; calendar prompt/auto-start
      through the existing startFlow with one-shot source override + title seeding; non-destructive
      per-segment cleanup + Verbatim/Cleaned Viewer switch; custom summary modes (authored in Settings,
      cached namespaced). **Build green; ALL self-tests pass** — the 7 new ones
      (diarize/align/detect/multilingual/calendar/cleanup/custom-summary) AND the entire prior suite
      unchanged (file + stream output text identical to pre-build). One prompt bug found & fixed during
      self-test (cleanup model echoed the literal "N|" format token → clearer instructions + defensive
      parser strip). **HUMAN-VERIFIED** (live 2-speaker diarization + rename persistence, speaker-model
      first download, live multilingual + Auto indicator, `*.en` guard UX, calendar prompt/auto-start/
      denial, cleaned-view toggle on a real filler-heavy recording, custom mode end-to-end, full
      regression sweep).
- [x] **Stage 2 — Generation Studio / Vertical Packs / Privacy & Compliance** —
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
      **HUMAN-VERIFIED** (each Studio template + audiogram, Medical/second pack enabled, a PII session
      redacted, a retention sweep with a Keep, encryption round-trip + Touch ID, full Stage-0/1
      regression sweep).
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
- [~] **Phase 2 — the visual timeline (render-only on Mac).** Restored the frame/OCR model to
      SaidKit so Phase 3's iPhone slide capture has something to write into, and taught the Mac to
      read it: `FrameEvent` (three fields) on `SessionDoc`, a new and smaller `SlideOCR`, markdown
      interleaving that matches the removed feature's output exactly, HTML/PDF export on current
      tokens, Viewer frame cards with click-to-seek through the existing `goTo`, Library thumbnails
      + slide counts + `has:slides`. **The Mac gained no way to capture a frame**, `FrameChangeDetector`
      stayed dead, and video-XOR-frames is enforced in `SessionDoc.visual` rather than merely
      documented. **Byte-identical defaults proven:** `--selftest-doc`'s case-1 md5 is unchanged from
      pre-build, a session with no frames writes no `frames` key, and the whole prior suite passes.
      `--selftest-frames` (29 assertions) passes; `--selftest-bundle` and `--selftest-doc` gained new
      cases with their old assertions intact; the iOS gate is green.
      **AWAITING human smoke-tests:** see the Phase 2 checklist — a normal session unchanged, a ⌥⌘S
      screen recording still correct after a pause, frames rendering at the right timestamps with
      working click-to-seek, a slide-only phrase found by search, HTML/PDF export carrying the
      images, the pre-existing library intact (especially any session with a leftover `frames`
      array), and no capture path anywhere on the Mac.
- [~] **Phase 1 — cross-platform core, rebrand, session identity.** The package is split into
      `SaidKit` (cross-platform) + `Said` (macOS executable); every macOS assumption in the shared
      code is an injectable seam (session root, delete-to-Trash, light/dark colour resolution,
      platform fonts, RTF serialization, mic route-change); `Scripts/verify_ios_build.sh` compiles
      SaidKit for `generic/platform=iOS` and is wired in as the last step of the sweep. Added
      `SessionMeta.id` (additive, lazily backfilled) and the `.said` session bundle (AppleArchive,
      export + import + a deterministic collision rule + an exported UTI). Rebranded: `SaidApp`,
      the violet/amber/ink palette (**amber = live**, the record red is gone), a regenerated icon,
      the vendored `Design/` screens, and this file's Design system section.
      **Build green on BOTH platforms; the designated requirement is byte-identical before/after
      (`identifier "com.said.mac" and certificate leaf = H"191d047d…"`), so TCC grants persist;
      `--selftest-doc` md5 unchanged and `--selftest` / `--selftest-stream` transcript text
      byte-identical (only the elapsed-time figure differs, which is not deterministic); the 3 new
      modes pass and the whole prior suite is unchanged.**
      **AWAITING human smoke-tests:** see the Phase 1 checklist — launch + no permission re-prompt on
      mic and system audio, a real end-to-end recording, the palette in both light and dark across
      every window, amber-as-live, speaker 1 violet / speaker 2 amber, a `.said` round trip through
      Finder (including the second double-click saying "already in your library"), the pre-existing
      library intact, and an encrypted round trip.

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
- **B — Vertical Packs**: `Packs.swift` + `Entitlements.swift`. Bundled `Sources/SaidKit/Packs/*.json`
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
- **Phase-1 decisions:**
  - **The macOS session folder STAYS at `~/Desktop/Transcripts`** and is deliberately **not** renamed
    to `~/Desktop/Said`. Renaming buys a cosmetic win and costs a migration of every existing session
    folder plus every stored path. If it is ever wanted it is a small, separate, **opt-in** migration
    on the existing `--selftest-migrate` pattern. Not now.
  - **`CFBundleIdentifier` stays `com.said.mac`** and the signing identity stays
    `"Transcriber Local Signing"`. (The Phase 1 prompt said the id was `com.nikhil.transcriber`; it
    is not — the rebrand commit before Phase 1 already moved it. What matters is that TCC binds
    grants to the SIGNATURE, so the id and identity that exist today are the ones that must not
    move. `codesign -d -r-` output was captured before and after and is identical.)
  - **UserDefaults keys are untouched** — including the NSWindow autosave name
    `"TranscriberMainWindow"`, which IS a UserDefaults key (`NSWindow Frame TranscriberMainWindow`);
    renaming it would silently discard every saved window position. The SearchIndex cache folder
    `Application Support/Transcriber` is likewise kept: a stored path, not a user-visible string.
  - **`SelfTest` deliberately stayed in `Said`** rather than moving with the code it tests, so the
    existing headless suite could act as the untouched regression proof for the split.
  - **Prefer CoreGraphics/CoreText over a platform `#if`.** `ClipExporter`'s caption burn-in moved
    from AppKit to CoreText and needed no seam at all. Only reach for `PlatformUI` when the platforms
    genuinely disagree (a concrete font class for RTF; appearance-resolved colour).
- **Phase 1 — explicitly OUT OF SCOPE** (do not infer any of this from the vendored screens): any iOS
  UI, `AVAudioSession` configuration, ReplayKit / iPhone screen recording, camera capture, accounts,
  sync, CloudKit, StoreKit or any commerce (`EntitlementProvider` still grants everything), and the
  `~/Desktop/Said` folder rename. Phase 2 builds the iOS app on top of what Phase 1 produced.

## Leftover scaffolding (candidate cleanup)
- `debugLog()` writes to `<FileManager.temporaryDirectory>/transcriber_launch.log` + NSLog on every launch, and `AppDelegate` logs a
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
- **"Deleting a session does nothing / throws."** SaidKit's `SessionTrash` default REFUSES on macOS
  (`SessionTrashError.noTrashImplementation`) — by design, because "never a hard delete on macOS" is
  a user-facing promise and a silent `removeItem` is exactly what that promise exists to prevent.
  The real implementation is injected in `AppModel.onLaunch`. If deletes fail, that injection didn't
  run (a self-test binary, or a code path that bypassed launch). Self-tests inject their own.
- **"My transcript isn't called `transcript.md` any more."** Correct — it is named after the session
  (`2026-09-01 14-32 Standup with Priya.md`), and it RENAMES itself once the on-device title lands, so
  a file whose name you noted seconds after saving can have a better one a moment later. The folder is
  the stable identity; anything holding a path to the file should re-resolve through `SessionPaths`.
  Sessions recorded before the change keep `transcript.md` and are never touched.
- **A `.said` won't import / "already in your library".** The collision rule is deterministic and
  keyed on `SessionMeta.id`: same id ⇒ never import, never duplicate, reveal the existing session.
  That is correct behaviour, not a failure. A bundle with no id, or an unknown one, always imports.
- **`swift build` fails with `'v18' is unavailable`.** `Package.swift` uses `.iOS("18.0")` (the string
  form) precisely to avoid this — `.v18` needs swift-tools-version 6.0. Don't "fix" it by bumping the
  tools version: that switches the package into Swift 6 language mode.
- **`verify_ios_build.sh` says "does not contain a scheme named SaidKit".** The `SaidKit` **library
  product** was removed from `Package.swift`. SPM generates schemes from products, not targets.
- **A stale resource bundle in the build dir.** After the rename, `.build/…/release/` can still hold
  a `Transcriber_Transcriber.bundle` from a pre-split build, and `build_app.sh` copies *every*
  `*.bundle` it finds. Harmless but it ships dead weight — `rm -rf` it (or clean the build dir).
  The live one is `Said_SaidKit.bundle` (SPM names it `<package>_<target>`).
- **`--selftest` output differs from a saved baseline.** Compare the transcript TEXT, not the whole
  line: the `RESULT (0.28s):` timing figure is wall-clock and changes with a warm vs cold model.
  `--selftest-doc`'s md5 has no such component and IS exactly comparable.
