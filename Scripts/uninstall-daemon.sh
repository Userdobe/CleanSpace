#!/bin/bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.cleanspace.daemon.plist"
launchctl bootout "gui/$(id -u)/com.cleanspace.daemon" 2>/dev/null || true
rm -f "$PLIST"
echo "CleanSpace daemon disabled. Logs and configuration were kept at ~/Library/Logs/CleanSpace and ~/Library/Application Support/CleanSpace."
