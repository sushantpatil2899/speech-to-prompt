# Running SpeechToPrompt

## Recommended: menu bar app

`scripts/build_app.sh` installs `/Applications/SpeechToPrompt.app`. It's a menu bar app (no Dock icon,
no window). Turn on **Launch at Login** in its menu so it starts with your Mac.

How the options compare:

| How | Permissions | Starts at login | UI | Verdict |
|---|---|---|---|---|
| **Menu bar .app** | Granted to the app itself; persist across rebuilds if signed with a development certificate | Yes (Launch at Login, via `SMAppService`) | Menu bar icon, overlay (stage 2) | **Use this** |
| Terminal (`.build/release/SpeechToPrompt`) | Attributed to *Terminal*, which then gets Input Monitoring and Accessibility for everything you run in it | No; stops when the window closes | Same, but tied to the terminal | Only for debugging |
| launchd agent | Background agents without a bundle are awkward to grant permissions to; prompts may not appear | Yes | No UI | No benefit over Launch at Login |

## Watching what it does (stage 1)

Stage 1 doesn't paste yet. Each transcript goes to:

1. **The unified log.** Watch it live:

   ```bash
   log stream --level info --predicate 'subsystem == "local.SpeechToPrompt"'
   ```

   Each dictation logs the text, any note (VAD skip, phantom phrase), and a latency line such as
   `keyUp→audioStopped 9 ms · audioStopped→vadDone 11 ms · vadDone→sttDone 420 ms · total since keyUp 440 ms`.
2. **The menu:** "Copy last: …" shows the latest transcript and copies it to the clipboard.
3. **`~/Library/Application Support/SpeechToPrompt/history.jsonl`:** one JSON line per dictation,
   with per-stage latency. Summarize it with:

   ```bash
   python3 tools/latency_report.py
   ```

## Hotkeys

| Mode | Default key | Behavior |
|---|---|---|
| Raw | **Right ⌥** (hold) | Transcribe → (stage 2) paste |
| Clean | **Right ⌘** (hold) | Transcribe → (stage 3) LLM rewrite → paste. In stage 1 it behaves like raw. |

- **Hold:** recording starts the instant the key goes down and stops on release. Presses shorter than
  0.2 s are ignored (accidental taps).
- If you press any other key while holding (e.g. Right ⌘ + C), the recording is cancelled and the
  shortcut works normally.
- **Esc** cancels a recording.
- **Toggle** (`"behavior": "toggle"`): tap to start, tap again to stop. Holding longer than 0.35 s still
  works like hold.
- Recordings stop on their own after 120 s.

## Configuration

`~/Library/Application Support/SpeechToPrompt/config.json` is created with defaults on first launch.
Menu → **Open Config File** to edit it, then **Reload Config**. Any field you leave out takes its default.

```json
{
  "rawHotkey":   { "key": "rightOption",  "behavior": "hold" },
  "cleanHotkey": { "key": "rightCommand", "behavior": "hold" },
  "minHoldSeconds": 0.2,
  "tapMaxSeconds": 0.35,
  "maxRecordingSeconds": 120,
  "engine": {
    "kind": "whisper",
    "locale": "en-IN",
    "whisperModel": "ggml-large-v3-turbo.bin",
    "whisperBeamSize": 0,
    "whisperTemperatureFallback": true,
    "whisperThreads": 0
  },
  "vad": {
    "enabled": true,
    "minSpeechSeconds": 0.3,
    "threshold": 0.5,
    "padSeconds": 0.25,
    "sileroModel": "ggml-silero-v6.2.0.bin"
  },
  "vocabulary": ["Ollama", "SpeechAnalyzer", "Raghav"],
  "phantomPhrases": ["thank you", "thanks for watching", "…"],
  "phantomMaxSpeechSeconds": 1.5,
  "saveAudio": false,
  "writeHistory": true
}
```

| Field | Meaning |
|---|---|
| `key` | `rightOption`, `leftOption`, `rightCommand`, `leftCommand`, `rightControl`, `leftControl`, `rightShift`, `leftShift`, `function` |
| `engine.kind` | `whisper`, `apple` (SpeechTranscriber) or `apple-dictation` (DictationTranscriber). Also switchable from the menu. |
| `engine.locale` | Apple engines only. Whisper is always forced to English. |
| `whisperBeamSize` | `0` = greedy (fastest). `5` = beam search: a bit more accurate, slower. Compare with the eval. |
| `vad.minSpeechSeconds` | Clips with less detected speech are skipped entirely: nothing transcribed, nothing pasted. |
| `vocabulary` | Names and jargon you use. Sent to Whisper as its initial prompt and to Apple's engine as contextual strings. Often the single biggest win for accented speech on proper nouns. |
| `phantomPhrases` | If a clip with under `phantomMaxSpeechSeconds` of speech transcribes to exactly one of these, it's discarded (Whisper's classic "Thank you." on near-silence). |
| `saveAudio` | Saves each recording under `recordings/`. Useful for building eval clips from real dictation. |

## Files

```
~/Library/Application Support/SpeechToPrompt/
  config.json
  history.jsonl        raw text, final text, latency per dictation (only on this Mac, mode 600)
  models/              ggml-large-v3-turbo.bin, ggml-silero-v6.2.0.bin
  recordings/          only if saveAudio is on
```
