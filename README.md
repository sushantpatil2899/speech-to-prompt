# SpeechToPrompt

Personal push-to-talk dictation for macOS. Hold a key, speak, and the text goes into whatever field
has focus (mostly the Claude desktop app). Everything runs on your Mac; no audio or text leaves it.

- **Raw mode** (hold Right ⌥): transcribe and paste. Target: under 1.5 s from key release.
- **Clean mode** (hold Right ⌘): transcribe, have a local LLM rewrite it into a concise message, paste.
  Target: under 4 s.

## Status

| Stage | What | State |
|---|---|---|
| 1 | Hotkeys, recording, VAD gate, transcription (whisper.cpp / Apple SpeechAnalyzer), engine comparison | **Built, waiting for your verification on a Mac** |
| 2 | Paste into the focused field (clipboard save/restore), overlay | next |
| 3 | Local LLM cleanup (Ollama), rewrite-only prompt, guardrails and fallback, raw/clean toggle | |
| 4 | Context from the Claude desktop app (investigate Accessibility first) | |
| 5 | Chrome extension | later |

## Quick start (macOS 26, Apple Silicon, Xcode 26)

```bash
scripts/setup.sh --eval
```

```bash
scripts/build_app.sh --open
```

`setup.sh` installs cmake if needed, builds whisper.cpp with Metal into `Vendor/whisper.xcframework`,
downloads the Whisper large-v3-turbo and Silero VAD models, and (with `--eval`) creates `eval/.venv`.
Then follow [docs/STAGE_REPORTS.md](docs/STAGE_REPORTS.md).

## Docs

- [docs/PERMISSIONS.md](docs/PERMISSIONS.md): which permissions, which process, and why signing matters
- [docs/RUNNING.md](docs/RUNNING.md): menu bar app vs terminal vs launchd, logs, hotkeys, config reference
- [docs/STAGE_REPORTS.md](docs/STAGE_REPORTS.md): what to run and send back after each stage

## Layout

```
Package.swift
Sources/
  DictateCore/      pure Swift, unit-tested (also on Linux): config, hotkey state machine,
                    VAD gate, transcript cleanup, latency timer, history log, WAV
  DictateKit/       macOS: audio recorder, STT engines (whisper.cpp, Apple), Silero VAD,
                    event-tap hotkeys, permissions
  SpeechToPrompt/   the menu bar app
  dictate-cli/      record eval clips; run the app's pipeline on files
Tests/DictateCoreTests
eval/               prompts.txt, compare.py (engine comparison report), metrics.py
tools/              latency_report.py
scripts/            setup.sh, build_app.sh
Resources/          Info.plist, entitlements
```

## Design notes

- **Swift for the app.** SpeechAnalyzer, CGEventTap, AVAudioEngine, the overlay panel and the
  Accessibility API are native macOS APIs, and a single signed `.app` holds all the permissions.
  **Python** is used only for the eval and report scripts.
- **The speech engine sits behind `STTEngine`.** whisper.cpp (`no_context`, i.e. no conditioning on
  previous text; English forced; non-speech tokens suppressed) or Apple SpeechTranscriber /
  DictationTranscriber (streamed while you speak).
- **One VAD gate (Silero, via whisper.cpp) in front of every engine.** Clips with less than 0.3 s of
  speech are dropped before transcription. Short clips that come out as a known hallucination
  ("Thank you.") are discarded.
- **The eval runs the app's own pipeline** (`dictate-cli transcribe`), so its numbers are what the app does.

Run the tests:

```bash
swift test
```

```bash
python3 -m unittest discover -s eval
```
