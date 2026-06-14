# Transcriber

A macOS **menu-bar app** for live, **100% on-device** speech-to-text. Hit a global hotkey, speak (or
play a video), and watch the transcript appear live. Everything runs locally via
[WhisperKit](https://github.com/argmaxinc/WhisperKit) — after a one-time model download it works
fully offline.

- Shows in the **Dock** and the **menu bar** (waveform icon).
- Transcribe the **microphone** or the Mac's **system audio** (switchable).
- Global hotkey toggles recording from any app (default **⌥⌘T**).
- Floating, auto-scrolling transcript window with Copy / Clear.
- **Summarize** button — an on-device AI summary of the transcript via Apple Intelligence
  (Foundation Models, macOS 26). Also fully local; no cloud, no API key.
- On stop: saves a timestamped Markdown transcript to `~/Desktop/Transcripts/`, then replaces it
  with a cleaner full-quality re-transcription.

## Requirements
- Apple Silicon Mac, macOS 13+ (developed/tested on macOS 26).
- **Xcode installed** (the build uses its toolchain for one dependency's preview macro — the build
  script finds it automatically at `/Applications/Xcode.app`). Only the Command Line Tools are needed
  at runtime.

## Build & run
```sh
./Scripts/build_app.sh        # resolves deps, builds, assembles + ad-hoc-signs Transcriber.app
open ./Transcriber.app        # launches into the menu bar
```
On launch it shows the **Transcript window** (a control surface: source picker + Start/Stop) and adds a
**waveform icon to the menu bar**, and shows a **Dock icon** (right-click ▸ Options ▸ Keep in Dock to pin it).

Notes / gotchas:
- Give it **~1–2 seconds** after `open` — LaunchServices has some startup overhead.
- If you rebuild or relaunch, **fully quit the running copy first** (menu bar ▸ Quit, or
  `pkill -f Transcriber.app`). Otherwise `open` just re-activates the existing instance instead of
  starting fresh, so you won't see a new window.
- You can confirm it launched by checking `cat /tmp/transcriber_launch.log`.
- To see live logs, run the binary directly: `./Transcriber.app/Contents/MacOS/Transcriber`.

The first time you Start, the chosen model downloads (~150 MB for base.en) — you'll see a
"Downloading model…" status. After that it's cached and works offline.

## Using it
1. Click the **waveform** icon in the menu bar.
2. Pick a **source** — *Mic* or *System Audio*.
3. Press **Start** (or the global hotkey **⌥⌘T** from anywhere). The icon fills in while recording.
4. Open **Open Transcript Window** to watch the live transcript; **Copy**/**Clear** as needed.
5. Press the hotkey again (or **Stop**) to finish. It saves to `~/Desktop/Transcripts/`, runs a
   final full-quality pass ("Finalizing…"), and overwrites the file with the cleaner version.
6. **Settings** lets you re-bind the hotkey and choose the model (base.en / small.en / large-v3-turbo).

## Permissions (first-run, one-time)
This is a personal tool, so the **App Sandbox is disabled** to keep entitlements simple.

| Feature | Permission | What to do |
|---|---|---|
| **Microphone** | Microphone | macOS prompts on first mic use — click **Allow**. (System Settings ▸ Privacy & Security ▸ Microphone) |
| **System Audio** | Screen Recording | Required by ScreenCaptureKit (no video is recorded). Enable **Transcriber** under System Settings ▸ Privacy & Security ▸ **Screen Recording**, then **quit and relaunch** — a freshly-granted Screen Recording permission doesn't apply to the already-running app. |
| **Global hotkey** | usually none | Uses Carbon hotkeys (no special permission). If it ever does nothing, confirm the app is running; some setups may ask for Input Monitoring / Accessibility. |

> **TCC note:** the app is ad-hoc code-signed with a stable bundle id (`com.nikhil.transcriber`).
> Keep `Transcriber.app` at a fixed path. Rebuilding changes its code signature, so macOS may ask you
> to re-grant Screen Recording after a rebuild.

## How it works (brief)
- `AudioCaptureMic` (AVAudioEngine) and `AudioCaptureSystem` (ScreenCaptureKit) both convert audio to
  **16 kHz mono Float32** and push it into one shared `SampleSink`.
- A single `StreamingTranscriber` consumes the sink: it re-transcribes from the last confirmed
  timestamp each pass and confirms all but the trailing segments, so live text grows without
  duplication.
- On stop, one non-streaming full-quality WhisperKit pass (VAD-chunked) produces the final transcript.

See [CLAUDE.md](CLAUDE.md) for architecture, pinned-dependency API notes, and design decisions.

## Self-tests (no mic/permissions)
```sh
BIN=.build/release/Transcriber   # or the debug path
"$BIN" --selftest /tmp/transcriber_test.wav            # one-shot file transcription
"$BIN" --selftest-stream /tmp/tr_long_48k_stereo.wav   # streaming pipeline + final pass
```
