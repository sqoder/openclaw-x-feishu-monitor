#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REALTIME_TEMPLATE="$ROOT_DIR/launchd/com.openclaw.x-feishu.monitor.plist.template"
DAILY_TEMPLATE="$ROOT_DIR/launchd/com.openclaw.x-feishu.monitor.daily.plist.template"
REALTIME_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.realtime.plist"
DAILY_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.daily.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.plist"
REALTIME_INTERVAL_SECONDS="${REALTIME_INTERVAL_SECONDS:-180}"
DAILY_HOUR="${DAILY_HOUR:-8}"
DAILY_MINUTE="${DAILY_MINUTE:-0}"

mkdir -p "$ROOT_DIR/logs"
mkdir -p "$HOME/Library/LaunchAgents"

sed \
  -e "s|__ROOT_DIR__|$ROOT_DIR|g" \
  -e "s|__INTERVAL_SECONDS__|$REALTIME_INTERVAL_SECONDS|g" \
  "$REALTIME_TEMPLATE" > "$REALTIME_PLIST"

sed \
  -e "s|__ROOT_DIR__|$ROOT_DIR|g" \
  -e "s|__DAILY_HOUR__|$DAILY_HOUR|g" \
  -e "s|__DAILY_MINUTE__|$DAILY_MINUTE|g" \
  "$DAILY_TEMPLATE" > "$DAILY_PLIST"

launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor.realtime" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor.daily" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$LEGACY_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$REALTIME_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$DAILY_PLIST" >/dev/null 2>&1 || true

launchctl bootstrap "gui/$UID" "$REALTIME_PLIST"
launchctl bootstrap "gui/$UID" "$DAILY_PLIST"

launchctl enable "gui/$UID/com.openclaw.x-feishu.monitor.realtime"
launchctl enable "gui/$UID/com.openclaw.x-feishu.monitor.daily"

launchctl kickstart -k "gui/$UID/com.openclaw.x-feishu.monitor.realtime"

echo "Installed realtime: $REALTIME_PLIST"
echo "Installed daily:    $DAILY_PLIST"
echo "Realtime interval: ${REALTIME_INTERVAL_SECONDS}s"
echo "Daily schedule: ${DAILY_HOUR}:$(printf '%02d' "$DAILY_MINUTE") (UTC+8 local machine time)"
echo "Check realtime: launchctl print gui/$UID/com.openclaw.x-feishu.monitor.realtime"
echo "Check daily:    launchctl print gui/$UID/com.openclaw.x-feishu.monitor.daily"
