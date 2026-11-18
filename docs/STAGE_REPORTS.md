# Stage reports

Each stage ends with a check you run on your Mac. Send back what the "Send me" list asks for, and
we move on only once the stage works.

## Stage 1: hotkey → record → VAD → transcribe → print, plus the engine comparison

### Build

Full Xcode is not required; the Command Line Tools are enough.

```bash
scripts/setup.sh --eval
```

```bash
scripts/make_signing_cert.sh
```

```bash
scripts/build_app.sh --open
```

`make_signing_cert.sh` is a one-time step (skip it if you have an Apple Development certificate).
It lets macOS keep the app's permissions across rebuilds; see [PERMISSIONS.md](PERMISSIONS.md).

If `swift build` fails, send me the first ~30 lines of errors. This code was written without access
to a Mac, so a first-build fix or two is expected, mainly in the Apple Speech calls.

### Check the app

1. Grant Microphone and Input Monitoring when asked (see [PERMISSIONS.md](PERMISSIONS.md)).
   The menu bar icon should become a microphone; menu → Permissions shows ✓ for both.
2. In a terminal, start the log stream:

   ```bash
   log stream --level info --predicate 'subsystem == "local.SpeechToPrompt"'
   ```

3. Hold **Right ⌥**, say a sentence, release. The transcript and a latency line appear in the log.
4. Try each of these:
   - Hold Right ⌥ for under 0.2 s → nothing happens.
   - Hold Right ⌥ and say nothing for 2 s → log says "skipped: … of speech".
   - Hold Right ⌘ and press C → recording cancelled, and ⌘C still copies.
   - Hold, then press Esc → cancelled.
   - Menu → Speech Engine → Apple SpeechTranscriber (en-IN): the first time it may download Apple's model.
     Then dictate again.
5. Latency summary:

   ```bash
   python3 tools/latency_report.py
   ```

### Engine comparison

```bash
build/dictate-cli locales
```

```bash
build/dictate-cli record --prompts eval/prompts.txt --out eval/clips
```

```bash
eval/.venv/bin/python eval/compare.py eval/clips
```

The report opens as `eval/reports/<timestamp>.html`: per-engine WER with dropped and invented words
counted separately, output on silence and noise clips, and latency.

To list every error per clip (which words get dropped, invented or misheard):

```bash
eval/.venv/bin/python eval/errors.py --engines whisper,apple-en-IN
```

Optional runs that are worth a look:

```bash
eval/.venv/bin/python eval/compare.py eval/clips --engines whisper,whisper-beam5,whisper-nofallback
```

```bash
eval/.venv/bin/python eval/compare.py eval/clips --no-vad --engines whisper,apple-en-IN
```

```bash
eval/.venv/bin/python eval/compare.py eval/clips --vocab "PostgreSQL,Kubernetes,OAuth,Priya,Raghav,Indiranagar"
```

### Send me

- Any build errors.
- The output of `build/dictate-cli locales` (is en-IN supported for both Apple engines?).
- The summary table that `compare.py` prints (and the HTML if something looks odd).
- The output of `tools/latency_report.py`.
- Anything that felt wrong: missed key presses, clipped first words, slow start.

Then we pick the default engine and move to stage 2 (paste + overlay).

## Stage 2: paste into the focused field, overlay

### Build

```bash
git pull
```

```bash
scripts/build_app.sh --open
```

On launch macOS asks for **Accessibility** ("SpeechToPrompt would like to control this computer").
Allow it under System Settings → Privacy & Security → Accessibility. Menu → Permissions should now
show ✓ for all three.

### Check

1. **TextEdit:** click into a document, hold Right ⌥, speak, release. The text appears at the cursor.
   Meanwhile, in the top-right corner: a waveform that moves with your voice, then a rotating ring,
   then a green check with the start of the text, fading after about 1.5 s.
2. **Claude desktop app:** the same, in the message box.
3. **Clipboard restore:** copy something distinctive (a sentence, or an image from Preview),
   dictate, then press ⌘V yourself: your original clipboard should paste, not the dictation.
   If you use a clipboard manager, the dictated text shouldn't appear in its history.
4. **Focus:** right after a paste, keep typing; the keystrokes should go to the same field
   (the overlay must never take focus). Also try with the target app in full screen.
5. **Nothing to paste into** (click the desktop first): nothing breaks, and menu → "Copy last"
   still has the text.
6. **Silence:** hold the key without speaking → overlay says "No speech detected", nothing is pasted.
7. **Clean key (Right ⌘):** pastes the raw transcript for now; the overlay says cleanup comes in stage 3.
8. **Latency:**

   ```bash
   python3 tools/latency_report.py --since 2026-11-18
   ```

   The `pasted` row is the paste step; `total_from_keyUp` is now key release → text pasted.

### Send me

- The `latency_report.py` output.
- Whether the clipboard came back every time (any app where it didn't?).
- Any app where the paste didn't land, or landed somewhere else.
- How the overlay looks and feels: size, position, animation. A screenshot helps.
