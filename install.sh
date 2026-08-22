#!/bin/bash
# dictate installer. Usage: ./install.sh [install|uninstall]
set -e
cd "$(dirname "$0")"

# ---- every filesystem location, in one place -------------------------------
BIN=/usr/local/bin/dictate                            # binary
PLIST="$HOME/Library/LaunchAgents/com.user.dictate.plist"
LOG="$HOME/Library/Logs/dictate.log"                  # stderr log
CACHE="$HOME/Library/Application Support/FluidAudio"  # ~480 MB model cache
LABEL=com.user.dictate

uninstall() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sudo rm -f "$BIN"
    rm -f "$PLIST" "$LOG"
    rm -rf "$CACHE"   # ~480 MB model
    echo "Removed:"
    echo "  $BIN"
    echo "  $PLIST"
    echo "  $LOG"
    echo "  $CACHE"
    echo "System is as if dictate never existed."
}

case "${1:-install}" in
install)
    echo "==> Building (first build takes a few minutes)..."
    swift build -c release

    echo "==> Installing binary to $BIN ..."
    sudo mkdir -p "$(dirname "$BIN")"
    sudo cp .build/release/dictate "$BIN"

    echo "==> Installing LaunchAgent..."
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"

    echo ""
    echo "==> Done. dictate is running and will start at login."
    echo "    Log:   $LOG   (delete anytime; recreated on next launch)"
    echo "    Cache: $CACHE  (model, ~480 MB; deleting re-downloads)"
    echo ""
    echo "    First launch downloads the model — wait for 'Model loaded' in the log."
    echo "    Grant permissions to $BIN:"
    echo "      System Settings → Privacy & Security → Microphone / Accessibility / Input Monitoring"
    ;;
uninstall) uninstall ;;
*) echo "usage: $0 [install|uninstall]" >&2; exit 2 ;;
esac
