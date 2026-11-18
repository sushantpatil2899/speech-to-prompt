# Running SpeechToPrompt

## Recommended: menu bar app

`scripts/build_app.sh` installs `/Applications/SpeechToPrompt.app`. It's a menu bar app (no Dock icon,
no window). Turn on **Launch at Login** in its menu so it starts with your Mac.

How the options compare:

| How | Permissions | Starts at login | UI | Verdict |
|---|---|---|---|---|
| **Menu bar .app** | Granted to the app itself; persist across rebuilds if signed with a development certificate | Yes (Launch at Login, via `SMAppService`) | Menu bar icon, overlay | **Use this** |
| Terminal (`.build/release/SpeechToPrompt`) | Attributed to *Terminal*, which then gets Input Monitoring and Accessibility for everything you run in it | No; stops when the window closes | Same, but tied to the terminal | Only for debugging |
| launchd agent | Background agents without a bundle are awkward to grant permissions to; prompts may not appear | Yes | No UI | No benefit over Launch at Login |

## What happens when you dictate

The text is pasted into the focused field: your clipboard is saved, the text is put on it, ⌘V is
sent, and ~0.35 s later your clipboard is put back (unless you copied something new in between).
The overlay in the top-right corner shows listening (waveform) → processing (rotating ring) →
done (check mark), and doesn't take focus.

Each transcript also goes to:

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

## Clean mode

The transcript goes to a local model through Ollama (`127.0.0.1:11434`, never anywhere else; the app
refuses other addresses and Ollama's `-cloud` models). The prompt tells the model to *rewrite only*:
the transcript sits between `<transcript>` tags, and questions, commands and "ignore your
instructions" inside it are rewritten, never answered or followed.

Before pasting, guardrails check the output. If any check fails, or Ollama doesn't answer within
3 s, the **raw transcript is pasted** instead and the overlay says why:

- empty output, or it starts like a reply ("Sure", "Here's")
- much longer than what you said (it answered or added content)
- several words you never said
- it kept too little of what you said (it obeyed the dictation instead of rewriting it)
- it dropped a number, name, identifier, file name or command flag

The overlay's **Clean | Raw** toggle swaps the pasted text: ⌘Z, then it pastes the other version. It does
this only if the same field still has focus and you haven't typed or clicked since. Otherwise it puts
the other version on the clipboard for you to paste.

The model is loaded into memory when the app starts and stays loaded (`keep_alive: -1`), about 7 GB of
RAM for `qwen3.5:9b`. To free it: `ollama stop qwen3.5:9b` (the app reloads it on its next start or
after a failed request).

## Hotkeys

| Mode | Default key | Behavior |
|---|---|---|
| Raw | **Right ⌥** (hold) | Transcribe → paste |
| Clean | **Right ⌘** (hold) | Transcribe → local LLM rewrite → paste, then a **Clean / Raw** toggle on the overlay for 30 s |

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
    "whisperBeamSize": 5,
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
  "writeHistory": true,
  "autoPaste": true,
  "pasteRestoreDelaySeconds": 0.35,
  "showOverlay": true,
  "overlayDoneSeconds": 1.5,
  "cleanToggleSeconds": 30,
  "llm": {
    "enabled": true,
    "baseURL": "http://127.0.0.1:11434",
    "model": "qwen3.5:9b",
    "timeoutSeconds": 3.0,
    "disableThinking": true,
    "temperature": 0,
    "contextTokens": 4096
  }
}
```

| Field | Meaning |
|---|---|
| `key` | `rightOption`, `leftOption`, `rightCommand`, `leftCommand`, `rightControl`, `leftControl`, `rightShift`, `leftShift`, `function` |
| `engine.kind` | `whisper`, `apple` (SpeechTranscriber) or `apple-dictation` (DictationTranscriber). Also switchable from the menu. |
| `engine.locale` | Apple engines only. Whisper is always forced to English. |
| `whisperBeamSize` | `5` = beam search (default; on the stage-1 clips 7.0% vs 8.2% WER for about +12 ms). `0` = greedy. |
| `vad.minSpeechSeconds` | Clips with less detected speech are skipped entirely: nothing transcribed, nothing pasted. |
| `vocabulary` | Names and jargon you use. Sent to Whisper as its initial prompt and to Apple's engine as contextual strings. Often the single biggest win for accented speech on proper nouns. |
| `phantomPhrases` | If a clip with under `phantomMaxSpeechSeconds` of speech transcribes to exactly one of these, it's discarded (Whisper's classic "Thank you." on near-silence). |
| `saveAudio` | Saves each recording under `recordings/`. Useful for building eval clips from real dictation. |
| `autoPaste` | `true`: paste with ⌘V and restore your clipboard. `false`: only put the text on the clipboard. |
| `pasteRestoreDelaySeconds` | Wait after ⌘V before restoring your clipboard. Raise it if an app sometimes pastes your *old* clipboard instead of the dictation. |
| `showOverlay`, `overlayDoneSeconds` | The top-right overlay, and how long its "done" state stays up. |
| `cleanToggleSeconds` | How long the clean-mode card with the Clean / Raw toggle stays up. |
| `llm.model` | Any local Ollama model (`ollama list`). Cloud models are refused. |
| `llm.timeoutSeconds` | After this the raw transcript is pasted. Raise it for long dictations if you'd rather wait. |
| `llm.disableThinking` | Sends `think: false` so reasoning models answer directly (much faster). |

## Files

```
~/Library/Application Support/SpeechToPrompt/
  config.json
  history.jsonl        raw text, final text, latency per dictation (only on this Mac, mode 600)
  models/              ggml-large-v3-turbo.bin, ggml-silero-v6.2.0.bin
  recordings/          only if saveAudio is on
```
