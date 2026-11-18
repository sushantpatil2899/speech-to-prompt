# macOS permissions

Everything runs inside **one process: `SpeechToPrompt.app`**. macOS grants privacy permissions per app
(identified by its bundle ID `local.SpeechToPrompt` plus its code signature), so all grants go to that app.

| Permission | Needed by | Used for | From stage |
|---|---|---|---|
| **Microphone** | SpeechToPrompt.app | Recording while a hotkey is held (AVAudioEngine) | 1 |
| **Input Monitoring** | SpeechToPrompt.app | Seeing the modifier-only hotkeys (a listen-only `CGEventTap`: it can't block or change keystrokes) | 1 |
| **Accessibility** | SpeechToPrompt.app | Posting ⌘V / ⌘Z, and reading the focused text field (raw/clean toggle) and, in stage 4, the Claude window | 2 |
| Speech Recognition | SpeechToPrompt.app, *only if macOS asks* | Apple's SpeechAnalyzer engine. On-device; macOS may or may not prompt for it. Whisper doesn't need it. | 1 |
| Screen Recording | SpeechToPrompt.app, *only if stage 4 falls back to OCR* | Reading the Claude window as pixels | 4 (maybe) |

For the eval tools, which you run from a terminal: **Microphone for your terminal app** (Terminal, iTerm, …).
macOS attributes a command-line tool's microphone use to the terminal that launched it, so
`dictate-cli record` asks on behalf of Terminal.

## Granting them

On first launch the app asks for Microphone and Input Monitoring. You can also use
**menu bar icon → Permissions**: each line shows ✓/✗, and clicking one asks or opens the right page of
**System Settings → Privacy & Security**.

- **Input Monitoring:** after switching it on, the app picks it up within about 2 seconds; the menu bar
  icon changes from `mic.slash` to `mic`. If it doesn't, quit and reopen the app. macOS sometimes only
  applies this grant at launch.
- **Accessibility:** needed from stage 2. Switch on SpeechToPrompt under Privacy & Security → Accessibility.

## Why the code signature matters

macOS remembers a grant for a specific code identity. `scripts/build_app.sh` signs the app with your
**Apple Development** certificate if you have one, and that identity stays the same across rebuilds,
so the grants persist. Without a certificate the app is signed *ad hoc*: every rebuild has a new
identity, and you'd have to turn the permissions off and on again after each build.

To get a free certificate: Xcode → Settings → Accounts → add your Apple ID → select the team
("Personal Team") → Manage Certificates → **+** → Apple Development.

## If a permission seems stuck

Remove the app from the list and grant it again, or reset it from the terminal:

```bash
tccutil reset ListenEvent local.SpeechToPrompt
```

```bash
tccutil reset Accessibility local.SpeechToPrompt
```

```bash
tccutil reset Microphone local.SpeechToPrompt
```

## Known limitation: secure input

While a password field is focused, or any app turns on "Secure Keyboard Entry" (Terminal can, under its
menu), macOS hides keystrokes from every event tap, so the hotkeys won't fire. This is by design.

## What leaves the machine

Nothing at runtime: the app makes no network requests in stage 1. (From stage 3 it talks to Ollama at
`127.0.0.1` only.) One-time downloads happen in `scripts/setup.sh` (whisper.cpp source from GitHub,
model files from Hugging Face) and, for the Apple engine, macOS downloads the speech model for your
locale from Apple the first time.
