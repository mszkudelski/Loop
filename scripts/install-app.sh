#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Loop}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-$APP_NAME}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.marekszkudelski.loop}"
AGENT_LABEL="${AGENT_LABEL:-$BUNDLE_IDENTIFIER}"
LEGACY_AGENT_LABEL="local.loop.menubar"
APP_BUNDLE="$APP_NAME.app"
SOURCE_APP="$ROOT/dist/$APP_BUNDLE"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_BUNDLE"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LEGACY_AGENT_PLIST="$HOME/Library/LaunchAgents/$LEGACY_AGENT_LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

APP_NAME="$APP_NAME" \
EXECUTABLE_NAME="$EXECUTABLE_NAME" \
BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
"$ROOT/scripts/build-app.sh"

launchctl bootout "$GUI_DOMAIN" "$AGENT_PLIST" >/dev/null 2>&1 || true
if [[ "$AGENT_LABEL" != "$LEGACY_AGENT_LABEL" ]]; then
  launchctl bootout "$GUI_DOMAIN" "$LEGACY_AGENT_PLIST" >/dev/null 2>&1 || true
  rm -f "$LEGACY_AGENT_PLIST"
fi
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP"

# Register the installed bundle before launching it. Starting the Mach-O binary
# directly can leave macOS without the app's bundle identity and make its menu
# bar item inherit another foreground app's Menu Bar permission.
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
/usr/bin/mdimport "$INSTALLED_APP" >/dev/null 2>&1 || true

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$INSTALLED_APP</string>
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
