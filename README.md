# dictate — offline push-to-talk dictation for macOS

One binary, one dependency. Tap § → speak → tap again → text at your cursor.
Local transcription with Parakeet TDT v3 (0.6B) on Apple Silicon via Core ML
([FluidAudio](https://github.com/FluidInference/FluidAudio)). No cloud, no Python.

- **Tap-toggle**: § tap starts recording (✦ blinks in menu bar), second tap transcribes.
- **Double-tap §** (<0.5 s between taps) types a literal `§` instead — the key stays usable for writing.
- **Ctrl+§** discards the utterance without typing.
- **~instant**: one ANE inference pass per utterance (~100–300 ms).
- **Private**: audio lives in RAM only; nothing is ever written to disk.
- **Offline after first run** (model download, ~480 MB).

## Install

```bash
./install.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`). The script builds,
installs to `/usr/local/bin/dictate`, and registers a LaunchAgent (starts at login,
auto-restarts).

Then grant permissions to `/usr/local/bin/dictate` (System Settings → Privacy &
Security): **Microphone**, **Accessibility**, **Input Monitoring**.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.user.dictate
rm ~/Library/LaunchAgents/com.user.dictate.plist /usr/local/bin/dictate
rm -rf ~/Library/Application\ Support/FluidAudio   # model cache
```

## Notes

- The § hotkey is keycode 10 (`kVK_ISO_Section`) — ISO keyboards only. On ANSI
  layouts, change `HOTKEY` to 50 (the backtick/grave key) in `Sources/dictate/main.swift`.
- Modifier combos other than Ctrl pass through untouched (Shift+§ = °, etc.).
- Utterances shorter than half a second are ignored.
- FluidAudio is pinned via `Package.resolved` — don't delete it.
- Audio buffer is unbounded; dictate per utterance.
- Debug key events: `DICTATE_DEBUG=1 .build/release/dictate`.
- Works as a plain CLI too: `swift build -c release && .build/release/dictate`.
