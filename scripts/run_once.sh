#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
WATCH_SCRIPT="${WATCH_SCRIPT:-$ROOT_DIR/scripts/watch_x_to_feishu.sh}"

if [[ -z "${1:-}" ]]; then
  echo "usage: $0 <x_handle_without_at>" >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

ACCOUNT="$1" "$WATCH_SCRIPT"
