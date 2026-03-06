# OpenClaw X -> Feishu Monitor

Reusable monitor for X (Twitter) accounts with Feishu push notifications.

## Features

- Monitor new posts from specific X accounts (new-only by default)
- Push to Feishu via `openclaw message send --channel feishu`
- Structured output: author, publish time, post type, original text + translation, summary
- Publish time is normalized to China time (`UTC+8`)
- Supports media push (images/videos)
- Supports batch polling for multiple accounts

## Prerequisites

- macOS / Linux
- Installed tools: `openclaw`, `jq`, `curl`, `python3`
- Feishu channel already configured in OpenClaw

Quick check:

```bash
openclaw --version
jq --version
python3 --version
```

## Quick Start

```bash
cd openclaw-x-feishu-monitor
cp .env.example .env
```

Edit `.env` (at least set `FEISHU_TARGET`):

```dotenv
FEISHU_TARGET=ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
STATE_DIR=.state
```

Edit `accounts.txt` (one handle per line, no `@`):

```text
OpenAI
AnthropicAI
cursor_ai
openaidevs
sama
```

Single-account test (dry run):

```bash
DRY_RUN=1 ./scripts/run_once.sh OpenAI
```

Batch run:

```bash
./scripts/run_batch.sh
```

## Scheduled Run (macOS launchd)

Install (default interval 300s):

```bash
./scripts/install_launchd.sh
```

Custom interval:

```bash
INTERVAL_SECONDS=180 ./scripts/install_launchd.sh
```

Check service status:

```bash
launchctl print gui/$UID/com.openclaw.x-feishu.monitor
```

Uninstall:

```bash
./scripts/uninstall_launchd.sh
```

## Key Configs

Common `.env` values:

- `FEISHU_TARGET`: Feishu receiver id (required when `DRY_RUN=0`)
- `STATE_DIR`: state/cache directory
- `ENFORCE_RECENCY=1`: push only recent posts
- `MAX_POST_AGE_HOURS=24`: recency window
- `ENABLE_TRANSLATION=1`: translation enabled
- `ENABLE_ANALYSIS=1`: summary enabled
- `ENABLE_DEEP_MEDIA_ANALYSIS=0`: deep model analysis disabled by default
- `ALLOW_JINA_FALLBACK=1`: fallback fetch source when primary fails

## Push Format

```text
[AI圈最新消息]
1. Author
2. Publish time (China time, UTC+8)
3. Post type
4. Original text + Chinese translation
5. Summary
```

## Troubleshooting

- No messages: run `DRY_RUN=1 ./scripts/run_once.sh OpenAI`
- 401/auth errors: verify OpenClaw Feishu channel setup
- Rate limit/cooldown: wait for cooldown recovery
- launchd no output: check `logs/runner.log` and `logs/launchd.err.log`

## License

MIT
