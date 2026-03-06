#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
ACCOUNTS_FILE="${ACCOUNTS_FILE:-$ROOT_DIR/accounts.txt}"
WATCH_SCRIPT="${WATCH_SCRIPT:-$ROOT_DIR/scripts/watch_x_to_feishu.sh}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-2}"
DAILY_MAX_POST_AGE_HOURS="${DAILY_MAX_POST_AGE_HOURS:-24}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ ! -f "$WATCH_SCRIPT" ]]; then
  echo "watch script not found: $WATCH_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$ACCOUNTS_FILE" ]]; then
  echo "accounts file not found: $ACCOUNTS_FILE" >&2
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  handle="$(printf '%s' "$line" | sed 's/#.*$//' | xargs)"
  if [[ -z "$handle" ]]; then
    continue
  fi

  echo "[run_daily_snapshot] checking @$handle"
  if ! ACCOUNT="$handle" \
    FORCE_SEND=1 \
    MAX_POSTS_PER_RUN=1 \
    ENFORCE_RECENCY=1 \
    MAX_POST_AGE_HOURS="$DAILY_MAX_POST_AGE_HOURS" \
    "$WATCH_SCRIPT"; then
    echo "[run_daily_snapshot] failed @$handle" >&2
  fi
  sleep "$SLEEP_BETWEEN"
done < "$ACCOUNTS_FILE"
