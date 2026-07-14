#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Loop}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-$APP_NAME}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-local.loop.menubar}"
AGENT_LABEL="${AGENT_LABEL:-$BUNDLE_IDENTIFIER}"
APP_BUNDLE="$APP_NAME.app"
SOURCE_APP="$ROOT/dist/$APP_BUNDLE"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_BUNDLE"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$EXECUTABLE_NAME"
GUI_DOMAIN="gui/$(id -u)"

APP_NAME="$APP_NAME" \
EXECUTABLE_NAME="$EXECUTABLE_NAME" \
BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
"$ROOT/scripts/build-app.sh"

launchctl bootout "$GUI_DOMAIN" "$AGENT_PLIST" >/dev/null 2>&1 || true
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>/tmp/$AGENT_LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$AGENT_LABEL.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$AGENT_PLIST"
launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PLIST"
launchctl kickstart -k "$GUI_DOMAIN/$AGENT_LABEL"

echo "Installed $INSTALLED_APP"
echo "Installed LaunchAgent $AGENT_PLIST"
