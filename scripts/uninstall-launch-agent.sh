#!/usr/bin/env bash
set -euo pipefail

AGENT_LABEL="local.loop.menubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"

launchctl bootout "$GUI_DOMAIN" "$AGENT_PLIST" >/dev/null 2>&1 || true
rm -f "$AGENT_PLIST"
pkill -x Loop >/dev/null 2>&1 || true

echo "Disabled Loop LaunchAgent"
