# dictate — offline push-to-talk dictation for macOS

One binary, one dependency. Tap Fn/Globe → speak → tap again → text at your cursor.
Local transcription with Parakeet TDT v3 (0.6B) on Apple Silicon via Core ML
([FluidAudio](https://github.com/FluidInference/FluidAudio)). No cloud, no Python.

- **Tap-toggle**: Fn tap starts recording (✦ blinks in menu bar), second tap transcribes.
- **Ctrl+Fn** discards the utterance without typing.
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
Security): **Microphone**, **Accessibility**, **Input Monitoring**. If the Globe
key does nothing: Keyboard settings → "Press 🌐 key to" → **Do Nothing**.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.user.dictate
rm ~/Library/LaunchAgents/com.user.dictate.plist /usr/local/bin/dictate
rm -rf ~/Library/Application\ Support/FluidAudio   # model cache
```

## Notes

- No error handling by design: failures crash loudly instead of silently misbehaving.
- FluidAudio is pinned via `Package.resolved` — don't delete it.
- Audio buffer is unbounded; dictate per utterance.
- Works as a plain CLI too: `swift build -c release && .build/release/dictate`.
