#!/bin/bash
# dictate installer: build, install to /usr/local/bin, set up LaunchAgent.
set -e
cd "$(dirname "$0")"

echo "==> Building (first build takes a few minutes)..."
swift build -c release

BIN="$(pwd)/.build/release/dictate"

echo "==> Installing binary to /usr/local/bin..."
sudo mkdir -p /usr/local/bin
sudo cp "$BIN" /usr/local/bin/dictate

echo "==> Installing LaunchAgent..."
PLIST=~/Library/LaunchAgents/com.user.dictate.plist
mkdir -p ~/Library/LaunchAgents
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.user.dictate</string>
    <key>ProgramArguments</key>
    <array><string>/usr/local/bin/dictate</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/tmp/dictate.err</string>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/com.user.dictate 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"

echo ""
echo "==> Done. dictate is running and will start at login."
echo "    Logs: /tmp/dictate.err"
echo ""
echo "    First launch downloads the ~480 MB model — wait for 'Model loaded' in the log."
echo ""
echo "    Then grant permissions to /usr/local/bin/dictate:"
echo "      System Settings → Privacy & Security → Microphone"
echo "      System Settings → Privacy & Security → Accessibility"
echo "      System Settings → Privacy & Security → Input Monitoring"
echo "    (add via '+' → Cmd+Shift+G → /usr/local/bin/dictate)"
echo ""
echo "    If the Fn key does nothing:"
echo "      System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing"
echo ""
echo "    Usage: tap Fn → speak → tap Fn. Ctrl+Fn discards. ✦ = recording."
