#!/usr/bin/env bash
set -euo pipefail

LEGACY_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.plist"
REALTIME_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.realtime.plist"
DAILY_PLIST="$HOME/Library/LaunchAgents/com.openclaw.x-feishu.monitor.daily.plist"

launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor.realtime" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/com.openclaw.x-feishu.monitor.daily" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$LEGACY_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$REALTIME_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$DAILY_PLIST" >/dev/null 2>&1 || true
rm -f "$LEGACY_PLIST" "$REALTIME_PLIST" "$DAILY_PLIST"
echo "Uninstalled: com.openclaw.x-feishu.monitor.{realtime,daily}"
