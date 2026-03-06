#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT_DIR/launchd/com.openclaw.x-feishu.monitor.plist.template"
PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.plist"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-300}"

mkdir -p "$ROOT_DIR/logs"
mkdir -p "$HOME/Library/LaunchAgents"

sed \
  -e "s|__ROOT_DIR__|$ROOT_DIR|g" \
  -e "s|__INTERVAL_SECONDS__|$INTERVAL_SECONDS|g" \
  "$TEMPLATE" > "$PLIST"

launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/com.openclaw.x-feishu.monitor"
launchctl kickstart -k "gui/$UID/com.openclaw.x-feishu.monitor"

echo "Installed: $PLIST"
echo "Interval: ${INTERVAL_SECONDS}s"
echo "Check: launchctl print gui/$UID/com.openclaw.x-feishu.monitor"
