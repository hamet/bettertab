#!/bin/bash
# bettertab — build & install
set -u

NAME=bettertab
SRC="$(dirname "$0")/main.swift"
BIN="./$NAME"
DEST=/usr/local/bin/$NAME
PLIST="$HOME/Library/LaunchAgents/com.user.$NAME.plist"

echo "==> compiling"
swiftc -O -o "$BIN" "$SRC" || { echo "build failed"; exit 1; }

# Stable ad-hoc signature so the Accessibility grant survives rebuilds.
echo "==> signing (ad-hoc)"
codesign -s - -f "$BIN" >/dev/null 2>&1

if [ "${1:-}" = "--build-only" ]; then
    echo "==> done: $BIN"
    exit 0
fi

if [ -f "$PLIST" ]; then
    echo "==> unloading LaunchAgent"
    launchctl unload "$PLIST" 2>/dev/null
fi

echo "==> installing to $DEST (sudo)"
sudo mkdir -p /usr/local/bin
sudo cp "$BIN" "$DEST"

if [ -f "$PLIST" ]; then
    echo "==> loading LaunchAgent"
    launchctl load "$PLIST"
else
    echo "==> LaunchAgent not installed; to autostart:"
    echo "    cp com.user.$NAME.plist ~/Library/LaunchAgents/"
    echo "    launchctl load ~/Library/LaunchAgents/com.user.$NAME.plist"
fi

echo "==> done"
echo "    Grant Accessibility to $DEST:"
echo "    System Settings > Privacy & Security > Accessibility > + (Cmd+Shift+G -> /usr/local/bin)"
