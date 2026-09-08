# Said

Live, **100% on-device** transcription for macOS. Press ⌥⌘T anywhere and Said writes down what it
hears — from your microphone, from your Mac's audio, or both at once. The transcript streams into a
window as you speak, and when you stop it's saved, searchable, and playable.

**Nothing leaves your Mac.** No cloud, no account, no API key. After a one-time model download it
works entirely offline, including on a plane.

---

## What it does

**Record** — ⌥⌘T from any app. Choose *Mic*, *System Audio* (calls, videos, anything playing), or
*Mic + System* for both sides of a conversation. ⌥⌘P pauses; ⌥⌘B drops a bookmark. Recording survives
device changes — plug in headphones, switch to AirPods, mute the browser — and auto-pauses through
long silences so dead air never reaches the transcript.

**Record the screen** — ⌥⌘S captures the screen *and* the audio as one session. One video, one
transcript, one timeline: every `[mm:ss]` points at a frame, and clicking a line seeks the video.

**Find it again** — the Library lists every session with an auto-generated title and tags, and
full-text search covers every word you've ever recorded, ranked, with timestamped snippets.

**Play it back** — the Session Viewer plays the audio or video against a clickable transcript, with
bookmarks and chapters as jump points.

**Who said what** — optional on-device speaker diarization labels each speaker; rename them per
session and the names become searchable.

**Ask it things** *(needs Apple Intelligence)* — summaries in three styles, action items, chat with a
single session, or Ask across all of them. Every answer cites a clickable `[mm:ss]`.

**Get it out** — SRT, VTT, TXT, RTF, HTML, PDF, the system share sheet, or an Obsidian vault. A whole
session exports as a single `.said` file you can hand to someone.

**Other things it does** — imports audio and video files, transcribes 90+ languages (or auto-detects),
biases toward your own jargon with a custom vocabulary, optionally cleans up filler words, redacts PII,
auto-deletes old sessions, and encrypts everything at rest behind Touch ID.

---

## Requirements

- **Apple Silicon Mac, macOS 14 or later.**
- **Apple Intelligence features** — summaries, chat, Ask, the Generation Studio — additionally need
  **macOS 26** on Apple Intelligence-capable hardware. Everything else works without it; those
  features simply explain themselves and stay disabled.
- **Xcode** installed at `/Applications/Xcode.app` to build (one dependency needs its macro plugin).
  Not needed to run.
- Internet **once**, to download the transcription model (~150 MB for the default). Offline after that.

---

## Build and run

```sh
Scripts/setup_signing.sh    # ONCE — creates a stable local signing identity
Scripts/build_app.sh        # build + assemble + sign Said.app
open ./Said.app
```

`setup_signing.sh` matters: macOS ties privacy permissions to an app's code signature, so without a
stable identity every rebuild would ask you to grant Microphone and Screen Recording again. Run it
once and your grants persist across rebuilds.

**Fully quit before relaunching** (menu bar ▸ Quit, or `pkill -f Said.app`) — otherwise `open` just
re-activates the running copy.

## Permissions

| For | Permission | Note |
|---|---|---|
| Microphone | Microphone | Prompted on first use. |
| System audio, screen recording | Screen Recording | **Quit and relaunch after granting** — a running app doesn't pick up a fresh grant. |
| Calendar-aware capture *(optional)* | Calendar | Only ever requested if you turn the feature on. |
| Notifications *(optional)* | Notifications | Silently skipped if denied. |

The App Sandbox is deliberately disabled — this is a personal tool, and sandboxing it would add
entitlement friction around audio capture for no benefit.

## Where your recordings live

`~/Desktop/Transcripts/<date-time>/` — one self-contained, movable folder per session: the
transcript + `session.json`, plus `audio.m4a` and `screen.mp4` when they exist.

The transcript is named after its session — `2026-09-01 14-32 Standup with Priya.md` — so the file
still says what it is once it has been dragged out of its folder. Until the on-device title lands
it is `<date> <time> Transcript.md`, and it is renamed when the title arrives. Sessions recorded
before this change keep their `transcript.md`; nothing on disk was migrated.

---

## Project layout

Two targets, because the core is shared with an iPhone app that is not built yet:

- **`Sources/SaidKit/`** — the cross-platform core (macOS + iOS): session store, document model,
  transcription, diarization, on-device intelligence, generation, export, privacy, design tokens.
  It must never acquire an AppKit, ScreenCaptureKit or KeyboardShortcuts dependency.
- **`Sources/Said/`** — the macOS app: windows, menu bar, hotkeys, screen and system-audio capture,
  and the headless self-test suite.

`Design/` holds reference artifacts — the settled visual identity and the iPhone screens. It is not a
build input and never ships inside the app.

## Verifying a build

```sh
Scripts/verify_selftests.sh   # 46 headless self-tests, ending with the iOS compile gate
Scripts/verify_ios_build.sh   # just the gate: does SaidKit still compile for iPhone?
```

The iOS gate is a hard gate, not a convenience: a green macOS build says nothing about whether the
shared core still compiles for iPhone, and one stray `import AppKit` in `SaidKit` would break the
iOS app with no other signal.

Individual tests run straight off the binary, e.g.:

```sh
.build/release/Said --selftest /tmp/transcriber_test.wav
```

See [CLAUDE.md](CLAUDE.md) for the architecture, the design system, pinned-dependency API notes, and
the reasoning behind the decisions — including the ones that were later reversed.

---

## Status

The macOS app is complete and in daily use. The iPhone app is not built yet; Phase 1 made the core
capable of supporting one.

**Sharing it:** `Said.app` is signed with a local identity, so it runs on the machine that built it.
Giving it to someone else needs Developer ID signing and notarization, or macOS will block it.
