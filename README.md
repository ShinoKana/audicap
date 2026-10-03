# Audicap

Audicap is a free, open-source (MIT) macOS menu-bar app that shows live captions for whatever your Mac is playing — Zoom, Google Meet, Teams, YouTube, or any other app — using on-device speech recognition (Apple's `SpeechAnalyzer`), with automatic per-sentence language switching for mixed-language meetings. Requires macOS 26+ on Apple Silicon.

- **What**: a menu-bar app that captures your Mac's system audio and overlays live captions, recognized on-device, switching languages sentence by sentence.
- **For whom**: people in meetings or videos that mix languages (e.g. Japanese/English/Chinese) or have accented speech, who want captions without a meeting bot joining the call.
- **Requirements**: macOS 26 or later, Apple Silicon.

[中文说明](README.zh.md)

Audicap listens to your Mac's system audio (no virtual audio driver, no meeting bot) and shows the text in a floating transparent overlay; other meeting participants see nothing. It keeps a transcript and audio file per meeting, which you can optionally process into a full, speaker-labeled record afterwards.

## Who it's for

Use Audicap if your meetings mix languages — for example Japanese, English and Chinese in the same call, or accented English — and you want live captions without adding a bot to the meeting.

If your meeting is in a single language, two more polished options already exist: macOS's built-in Live Captions, or [livesub-macos (JaSub)](https://github.com/ultima6-tw/livesub-macos), which also has more refined translation output. If what you actually need is cloud meeting notes or summaries rather than live captions, Otter or Granola are a different kind of tool — see the comparison table below.

## Install (prebuilt)

1. Download the zip from the [GitHub Releases page](../../releases), unzip it, and move `Audicap.app` to `/Applications`.
2. **First launch**: this build is not notarized, so macOS will block it. Either right-click the app → Open, or go to System Settings → Privacy & Security → "Open Anyway". Alternatively, clear the quarantine flag yourself:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Audicap.app
   ```
3. Grant **Screen Recording** when asked (and **Microphone** if you enable it). Quit and reopen the app after granting — macOS only applies the permission on relaunch, not immediately. The menu-bar icon's menu shows current permission status and has a "Check permissions…" item if you need to jump back to System Settings.
   Note: because this build is ad-hoc signed (no paid Apple Developer certificate), its signature identity changes with every release. **After updating**, if captions stay empty: System Settings → Privacy & Security → Screen Recording, remove the old Audicap entry, reopen Audicap, grant again, then quit and reopen once more (macOS applies the change on relaunch).
4. **Requirements**: macOS 26+, Apple Silicon. This is the only configuration tested so far — Intel Macs are untested.

**Recording consent**: Audicap will transcribe whatever audio it captures, including other people's voices in a call. You are responsible for getting consent where the law requires it before recording or transcribing a conversation.

**License**: MIT.

## Languages

11 selectable languages: Japanese, English, Mandarin (Simplified), Mandarin (Traditional), Cantonese, Korean, French, German, Spanish, Italian, Portuguese.

Pick one language, or in Auto mode pick up to 5 at once — Apple limits each app to 5 reserved language models at a time (`AssetInventory.maximumReservedLocales`). In Auto mode each selected language runs its own recognizer in parallel, and the result is chosen per sentence by confidence (see Features below). The default Auto set is Japanese + English + Mandarin (Simplified).

**Testing status**: Japanese, English and Mandarin (Simplified) have been tested on real meetings. The other 8 languages have only been tested with synthetic speech — in those tests they recognized correctly and did not steal results away from the ja/en/zh lanes, but they have not yet been tried on a real meeting. Accented speech is the hardest case for language arbitration (see Limitations); if a meeting is in English only, choose English alone rather than Auto mode.

## Features

- **System-audio captions** in a borderless, draggable overlay; at most 4 lines by default (wrapped lines and translations count).
- **Per-sentence language arbitration**: each language lane scores its result; the winner is chosen by confidence, with a penalty when a lane's output is in the wrong writing system (kana / Han / Hangul / Latin). If the best candidate is still unsure (< 0.80) and some lanes haven't answered, it waits up to 2 s longer — one lane often ends a sentence ~1.8 s earlier than the others.
- **On-device translation** (Apple Translation framework), shown under the original in a second color and excluded from copy.
- **Optional live cloud correction**: sentence-bounded 4–20 s chunks + their audio go to `gemini-2.5-flash-lite` via OpenRouter (~$0.01/hour). A language hint is sent only when every sentence in the chunk agrees and is ≥ 0.85 confident; otherwise the model transcribes what it hears.
- **Optional microphone lane**: your own voice goes to the transcript only, not the overlay. Bound to the built-in mic so Bluetooth headphones don't drop into call-quality mode.
- **Transcript panel** that updates in place; select-to-copy; timestamps stripped on copy.
- **Archive per meeting**: `.txt` (raw recognition, append-only), `.md` (final text, corrected lines marked ✎), `.wav` (16 kHz mono).
- **Post-meeting processing (optional)**: when you stop a recording longer than 5 minutes, Audicap asks whether to run an external script that produces a full transcript and speaker labels. The script is not in this repo; see Limitations below.
- **Menu-bar status menu**: shows current state, Screen Recording and Microphone permission status, a "Check permissions…" item, and a "Show log file" item.
- Global hotkey `⌥⌘A` to start/stop.

## Common questions

**Is there a free Mac app for live captions in Zoom without a meeting bot?**
Yes — that is what Audicap does. It captures system audio with ScreenCaptureKit, so it works with any app, and nothing joins the call as a participant.

**Can it caption a meeting that switches between Japanese, English and Chinese?**
Yes. In Auto mode it runs one recognizer per selected language in parallel (up to 5, an Apple limit) and picks the best result for every sentence, so a meeting can move between languages without changing settings.

**Does it work offline / does audio leave my Mac?**
Recognition and translation run on-device by default. Two optional features send audio to the cloud: live correction (Gemini via OpenRouter) and the post-meeting full transcript; the post-meeting step asks for confirmation every time.

**Does it work on Windows, Linux or iPhone?**
No to all three. Capture (ScreenCaptureKit) and recognition (`SpeechAnalyzer`, macOS 26) are Apple desktop-only APIs. It also can't become an iPhone app: iOS doesn't let an app capture another app's audio, which is what this relies on.

## How it compares (as of September 2026)

Based on public docs and repos; details may have changed.

| Tool | Audio | Recognition | Live overlay | Language handling |
|---|---|---|---|---|
| **Audicap** | System audio + optional mic | On-device (SpeechAnalyzer), optional cloud correction | Yes | Up to 5 languages in parallel, chosen per sentence |
| macOS Live Captions (built-in) | System audio | On-device | Yes | One language at a time |
| MacWhisper | Files, system audio (Pro) | On-device Whisper | Secondary; mainly file transcription | Chosen per file |
| Otter.ai | Meeting bot by default; desktop capture available | Cloud | Yes | One language per meeting |
| Granola | System audio | Cloud notes | No (notes, not captions) | — |
| NotchLive | System audio / mic | On-device Whisper | Yes | Set in settings |
| [livesub-macos (JaSub)](https://github.com/ultima6-tw/livesub-macos) | System audio | On-device SpeechAnalyzer | Yes | Source language picked manually |
| [MeetingMind](https://github.com/thxjune/MeetingMind) | System audio | On-device SpeechAnalyzer | Yes | English-oriented |
| [subtitles](https://github.com/daformat/subtitles) | System audio | On-device Parakeet | Yes | Picked once in settings |
| [swift-speech-lanes](https://github.com/ivan-magda/swift-speech-lanes) | Files | Parallel SpeechAnalyzer lanes | No (library) | One winning lane per file |

## Limitations

- **macOS 26 or later only.** `SpeechAnalyzer` is new in macOS 26.
- **At most 5 languages at once.** Apple allows each app to reserve 5 language models (`AssetInventory.maximumReservedLocales`). Audicap releases unused ones when you change the selection. Right after switching, the first few seconds may be missed while the model loads.
- **More languages = more chances to pick the wrong one.** Accented English is the hard case: in tests, English read by a Japanese voice scored only 0.18 on the English lane and was won by the Japanese lane. If a meeting is essentially English-only, choose English alone.
- The purple "screen sharing" indicator stays on while capturing (a ScreenCaptureKit requirement). A Core Audio process tap would avoid it but caused crackling playback on macOS 26.4.
- The `.wav` archive contains system audio only; the microphone lane is recognized but not recorded.
- Where recordings are saved is set in Settings → Transcript (default `~/Documents/Audicap`). The post-meeting script is external (default `~/whisper-job/_pipeline/audicap_post.sh`, receives the folder via `AUDICAP_DIR`); the feature is skipped if the script is missing.

## Troubleshooting

- **Captions stay empty**: open the menu-bar menu and check the Screen Recording / Microphone permission status. If not granted, use "Check permissions…" to jump to System Settings, grant Screen Recording (and Microphone if used), then quit and reopen Audicap.
- **After updating to a new build**: because releases are ad-hoc signed, each one has a different signing identity, so a previously granted permission may stop working. Remove the old Audicap entry under System Settings → Privacy & Security → Screen Recording, reopen Audicap, and grant again.
- **Repeated permission prompts**: Audicap stops retrying capture once it detects permission is missing (retrying would just reprompt indefinitely without succeeding, since macOS only applies a permission change on relaunch). Grant the permission, then relaunch the app.
- **Logs**: the menu has a "Show log file" item. Logs are written to `~/Library/Logs/Audicap/audicap.log`.

## Reporting bugs and feedback

Bug reports and feedback are welcome — especially "it didn't work on my Mac", since so far it has only been tested on one machine. Please [open an issue](../../issues/new/choose) with your macOS version, Mac model, the recognition-language setting, and the permission status shown in the menu-bar menu. Reports about languages other than Japanese/English/Chinese in real use are particularly useful.

If you attach the log (menu-bar menu → "Show log file"), read it first: it can contain fragments of what was said. Paste only the relevant lines and remove anything private.

## Build from source

Requires macOS 26 and Xcode Command Line Tools (SDK 26+).

1. **Create a self-signed code-signing certificate named `AudicapDev`**: Keychain Access → Certificate Assistant → Create a Certificate, type "Code Signing". macOS ties the Screen Recording permission to the signing identity; with ad-hoc signing every rebuild counts as a new app and asks again.
2. Run in your own terminal:
   ```sh
   ./deploy.sh
   ```
   It compiles, signs and verifies in a temporary directory, and only then installs to `~/Applications/Audicap.app` (the previous build is kept as `Audicap.app.prev`). `codesign` needs keychain access — click "Always Allow" the first time.
3. Grant **Screen Recording** (and **Microphone** if you enable it) when first launched.
4. Optional cloud correction: paste an OpenRouter API key in Settings. It is stored in UserDefaults on your Mac, not in the code.

To build your own distributable zip instead of installing locally, use `./release.sh <version>` (e.g. `./release.sh 0.1.0`) — it ad-hoc signs the app so it needs no keychain access, and writes a zip under `build/`.

## Files

| File | Contents |
|---|---|
| `AudicapApp.swift` | App: capture, overlay, transcript panel, settings, archive, post-meeting prompt |
| `Recognizer.swift` | Parallel multi-language SpeechAnalyzer lanes and per-sentence arbitration; writing-system check |
| `CloudCorrect.swift` | Live cloud correction and language-hint rule (`cloudLangHint`) |
| `Refine.swift` | Audio archive (`TapeRecorder`); retired whisper refinement path |
| `speechprobe.swift` | Benchmark CLI: feed a wav to SpeechAnalyzer, print per-lane latency/confidence; `speechprobe release` frees reserved language models |
| `tests/` | Unit tests for the language-hint and writing-system rules (run instructions at the top of each file) |
| `bundle/Info.plist`, `AppIcon.icns` | Used to assemble the app bundle on first install |
| `deploy.sh` | Build, sign, verify, install |
| `release.sh` | Build an ad-hoc-signed distributable zip |
| `LICENSE` | MIT license text |

## Design notes

Each of these came from a measurement; the code comments have the details.

- **Streaming recognition uses SpeechAnalyzer, not Whisper.** On the same material SpeechAnalyzer streams at 60–97× real time vs ~3× for whisper large-v3-turbo, adds ~8 MB of memory instead of 1.5 GB, rarely drops short replies ("はい", "Yes"), and does not hallucinate on silence. Whisper-style full-context transcription is more accurate, so the complete record is made after the meeting.
- **Cloud correction sends audio, not just text.** Text-only correction can't hear the speaker and often "fixes" correct words.
- **The recognizer's text is not sent along with the audio.** When it was, the model repeated it back before its own transcription, so every sentence appeared twice.
- **Chunks follow sentence boundaries, not fixed seconds.** The recognizer's final results land on pauses; fixed-length cuts split words.

## Roadmap

- Windows / Linux port (would need a different capture layer and recognizer).
- Configurable archive location and bundled post-meeting pipeline.
