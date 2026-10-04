#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG_DIR="$HOME/Library/Application Support/CleanSpace"
LOG_DIR="$HOME/Library/Logs/CleanSpace"
INSTALL_DIR="$CONFIG_DIR/bin"
PLIST="$HOME/Library/LaunchAgents/com.cleanspace.daemon.plist"
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
swift build -c release --product CleanSpaceDaemon
cp .build/arm64-apple-macosx/release/CleanSpaceDaemon "$INSTALL_DIR/CleanSpaceDaemon"
chmod 755 "$INSTALL_DIR/CleanSpaceDaemon"
printf '{"enabled":true,"minimumAgeDays":14,"maximumItemsPerRun":80}\n' > "$CONFIG_DIR/daemon.json"
sed -e "s#__DAEMON_PATH__#$INSTALL_DIR/CleanSpaceDaemon#g" -e "s#__LOG_PATH__#$LOG_DIR/launchd.log#g" -e "s#__ERROR_LOG_PATH__#$LOG_DIR/launchd-error.log#g" Resources/com.cleanspace.daemon.plist.template > "$PLIST"
UID_VALUE="$(id -u)"
launchctl bootout "gui/$UID_VALUE/com.cleanspace.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
echo "CleanSpace daemon installed: every 24 hours; cache age threshold: 14 days"
