#!/usr/bin/env bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ACCOUNT="${ACCOUNT:-OpenAI}"
FEISHU_TARGET="${FEISHU_TARGET:-}"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw/twitter-watch}"
ACCOUNT_LC="$(printf '%s' "$ACCOUNT" | tr '[:upper:]' '[:lower:]')"
STATE_FILE="$STATE_DIR/${ACCOUNT_LC}.last_status"
MAX_MEDIA="${MAX_MEDIA:-6}"
MAX_POSTS_PER_RUN="${MAX_POSTS_PER_RUN:-5}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_SEND="${FORCE_SEND:-0}"
ALLOW_JINA_FALLBACK="${ALLOW_JINA_FALLBACK:-0}"
ENABLE_TRANSLATION="${ENABLE_TRANSLATION:-1}"
ENABLE_ANALYSIS="${ENABLE_ANALYSIS:-1}"
ENABLE_DEEP_MEDIA_ANALYSIS="${ENABLE_DEEP_MEDIA_ANALYSIS:-0}"
DEEP_ANALYSIS_TIMEOUT="${DEEP_ANALYSIS_TIMEOUT:-45}"
DEEP_ANALYSIS_MAX_MEDIA_ITEMS="${DEEP_ANALYSIS_MAX_MEDIA_ITEMS:-3}"
ENABLE_AI_RELEVANCE_FILTER="${ENABLE_AI_RELEVANCE_FILTER:-1}"
ENFORCE_RECENCY="${ENFORCE_RECENCY:-1}"
MAX_POST_AGE_HOURS="${MAX_POST_AGE_HOURS:-24}"
ENABLE_THREAD_MERGE="${ENABLE_THREAD_MERGE:-1}"
SENT_CACHE_MAX_LINES="${SENT_CACHE_MAX_LINES:-600}"
BOOTSTRAP_ON_EMPTY_STATE="${BOOTSTRAP_ON_EMPTY_STATE:-1}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
HTTP_MAX_TIME="${HTTP_MAX_TIME:-12}"
COOLDOWN_FILE="$STATE_DIR/${ACCOUNT_LC}.cooldown_until"
SENT_CACHE_FILE="${SENT_CACHE_FILE:-$STATE_DIR/${ACCOUNT_LC}.sent_cache}"

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw CLI not found in PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found in PATH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in PATH" >&2
  exit 1
fi
if [[ "$DRY_RUN" != "1" && -z "$FEISHU_TARGET" ]]; then
  echo "FEISHU_TARGET is required when DRY_RUN=0" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

send_text() {
  local msg="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN][TEXT]\n%s\n' "$msg"
    return 0
  fi
  openclaw message send \
    --channel feishu \
    --target "$FEISHU_TARGET" \
    --message "$msg" >/dev/null 2>&1 || return 1
}

send_media() {
  local url="$1"
  local caption="$2"

  if [[ -z "$url" || "$url" == "null" ]]; then
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN][MEDIA] %s\n%s\n' "$caption" "$url"
    return 0
  fi

  openclaw message send \
    --channel feishu \
    --target "$FEISHU_TARGET" \
    --message "$caption" \
    --media "$url" >/dev/null 2>&1
}

run_agent_timeout() {
  local prompt="$1"
  local timeout_sec="$2"
  python3 - "$prompt" "$timeout_sec" <<'PY'
import subprocess
import sys

prompt = sys.argv[1]
timeout_sec = int(sys.argv[2] or "45")

try:
    p = subprocess.run(
        ["openclaw", "agent", "--agent", "main", "--message", prompt],
        capture_output=True,
        text=True,
        timeout=timeout_sec,
    )
    out = (p.stdout or "").strip()
    if out:
        print(out)
except Exception:
    pass
PY
}

tweet_id_to_time() {
  local tid="$1"
  python3 - "$tid" <<'PY'
import sys
from datetime import datetime, timedelta, timezone

tid = (sys.argv[1] or "").strip()
if not tid.isdigit():
    raise SystemExit(0)

try:
    ts_ms = (int(tid) >> 22) + 1288834974657
    dt_utc = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    dt_cn = dt_utc.astimezone(timezone(timedelta(hours=8)))
    print(f"{dt_cn.strftime('%Y-%m-%d %H:%M:%S UTC+8')}")
except Exception:
    pass
PY
}

tweet_id_to_epoch() {
  local tid="$1"
  python3 - "$tid" <<'PY'
import sys

tid = (sys.argv[1] or "").strip()
if not tid.isdigit():
    raise SystemExit(0)
try:
    ts_ms = (int(tid) >> 22) + 1288834974657
    print(int(ts_ms / 1000))
except Exception:
    pass
PY
}

translate_with_google() {
  local text="$1"
  if [[ -z "$text" ]]; then
    return 0
  fi
  local enc
  enc="$(python3 - "$text" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1] or ""))
PY
)"
  local raw
  raw="$(curl -k -L --silent --show-error --max-time 10 "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t&q=${enc}" || true)"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  python3 - "$raw" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
    parts = []
    for row in data[0]:
        if isinstance(row, list) and row and isinstance(row[0], str):
            parts.append(row[0])
    out = "".join(parts).strip()
    if out:
        print(out)
except Exception:
    pass
PY
}

translate_with_mymemory() {
  local text="$1"
  if [[ -z "$text" ]]; then
    return 0
  fi
  local enc
  enc="$(python3 - "$text" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1] or ""))
PY
)"
  local raw
  raw="$(curl -k -L --silent --show-error --max-time 10 "https://api.mymemory.translated.net/get?q=${enc}&langpair=auto|zh-CN" || true)"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  python3 - "$raw" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
    out = ((data.get("responseData") or {}).get("translatedText") or "").strip()
    if out:
        print(out)
except Exception:
    pass
PY
}

translate_to_zh() {
  local text="$1"
  if [[ -z "$text" ]]; then
    return 0
  fi

  local out=""
  local prompt="请把下面这条 X 帖子翻译成简体中文，只输出翻译文本，不要解释：${text}"
  out="$(run_agent_timeout "$prompt" 18 2>/dev/null || true)"
  out="$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "$out" || "$out" == *"All models failed"* || "$out" == *"cooldown"* ]]; then
    out="$(translate_with_google "$text" 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(translate_with_mymemory "$text" 2>/dev/null || true)"
  fi

  if [[ -z "$out" ]]; then
    out="翻译服务暂时不可用，先附原文供你查看。"
  fi

  printf '%s' "$out"
}

is_ai_relevant() {
  local account="$1"
  local text="$2"
  local url="$3"
  local card_title="$4"
  local card_desc="$5"
  python3 - "$account" "$text" "$url" "$card_title" "$card_desc" <<'PY'
import re
import sys

account, text, url, card_title, card_desc = [x or "" for x in sys.argv[1:]]
blob = " ".join([text, card_title, card_desc, url]).lower()

positive = {
    "ai","artificial intelligence","llm","model","models","agent","agents",
    "gpt","claude","anthropic","openai","cursor","copilot","codex",
    "deepmind","gemini","transformer","inference","training","fine-tune",
    "benchmark","api","release","launch","reasoning","multimodal",
    "token","prompt","eval","research","paper","safety"
}
negative = {
    "happy birthday","wedding","my son","my daughter","baby","nicu","family",
    "vacation","football","soccer","baseball","nba","nfl","politics",
    "election","war","department of war","campaign"
}

score = 0
for k in positive:
    if k in blob:
        score += 1
for k in negative:
    if k in blob:
        score -= 2

# 核心官方账号略放宽阈值
core = {"openai", "openaidevs", "anthropicai", "cursor_ai"}
if account.lower() in core:
    need = 0
else:
    need = 1

print("1" if score >= need else "0")
PY
}

priority_level() {
  local account="$1"
  local text="$2"
  python3 - "$account" "$text" <<'PY'
import sys

account = (sys.argv[1] or "").lower()
text = (sys.argv[2] or "").lower()

high_accounts = {"openai","openaidevs","anthropicai","cursor_ai","sama","gdb","demishassabis"}
high_kw = {"release","launch","now available","api","gpt","claude","opus","sonnet","cursor","model","shipping"}
mid_kw = {"research","paper","benchmark","reasoning","agent","coding","safety","training"}

if account in high_accounts or any(k in text for k in high_kw):
    print("高")
elif any(k in text for k in mid_kw):
    print("中")
else:
    print("低")
PY
}

is_recent_post() {
  local status_id="$1"
  local status_ts="$2"
  local now_ts
  now_ts="$(date +%s)"

  if [[ -z "$status_ts" || ! "$status_ts" =~ ^[0-9]+$ ]]; then
    status_ts="$(tweet_id_to_epoch "$status_id" 2>/dev/null || true)"
  fi
  if [[ -z "$status_ts" || ! "$status_ts" =~ ^[0-9]+$ ]]; then
    echo "0"
    return 0
  fi

  local age_limit=$((MAX_POST_AGE_HOURS * 3600))
  local delta=$((now_ts - status_ts))
  if [[ "$delta" -le "$age_limit" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

hash_text() {
  local s="$1"
  python3 - "$s" <<'PY'
import hashlib, re, sys
txt = (sys.argv[1] or "").lower()
txt = re.sub(r'https?://\S+', ' ', txt)
txt = re.sub(r'[^a-z0-9\u4e00-\u9fff ]+', ' ', txt)
txt = re.sub(r'\s+', ' ', txt).strip()
print(hashlib.sha1(txt.encode('utf-8')).hexdigest())
PY
}

is_sent_recently() {
  local sid="$1"
  local url="$2"
  local text="$3"
  [[ -f "$SENT_CACHE_FILE" ]] || { echo "0"; return 0; }
  local thash
  thash="$(hash_text "$text")"
  if rg -F -m1 "\"id\":\"$sid\"" "$SENT_CACHE_FILE" >/dev/null 2>&1; then
    echo "1"; return 0
  fi
  if [[ -n "$url" ]] && rg -F -m1 "\"url\":\"$url\"" "$SENT_CACHE_FILE" >/dev/null 2>&1; then
    echo "1"; return 0
  fi
  if rg -F -m1 "\"thash\":\"$thash\"" "$SENT_CACHE_FILE" >/dev/null 2>&1; then
    echo "1"; return 0
  fi
  echo "0"
}

mark_sent() {
  local sid="$1"
  local url="$2"
  local text="$3"
  local now_ts
  now_ts="$(date +%s)"
  local thash
  thash="$(hash_text "$text")"
  printf '{"ts":%s,"id":"%s","url":"%s","thash":"%s"}\n' "$now_ts" "$sid" "$url" "$thash" >> "$SENT_CACHE_FILE"
  tail -n "$SENT_CACHE_MAX_LINES" "$SENT_CACHE_FILE" > "${SENT_CACHE_FILE}.tmp" && mv "${SENT_CACHE_FILE}.tmp" "$SENT_CACHE_FILE"
}

parse_with_python() {
  local mode="$1"
  local account="$2"
  local raw_file="$3"

  python3 - "$mode" "$account" "$raw_file" <<'PY'
import html
import json
import re
import sys
from datetime import datetime, timezone

mode = sys.argv[1]
account = sys.argv[2]
raw_file = sys.argv[3]

with open(raw_file, "r", encoding="utf-8", errors="ignore") as f:
    raw = f.read()


def to_local_time(created_at: str) -> str:
    if not created_at:
        return ""
    try:
        from datetime import timedelta

        dt = datetime.strptime(created_at, "%a %b %d %H:%M:%S %z %Y")
        cn = dt.astimezone(timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M:%S UTC+8")
        return f"{cn}"
    except Exception:
        return created_at


def choose_video_url(media_obj: dict) -> str:
    info = media_obj.get("video_info") or {}
    variants = info.get("variants") or []
    candidates = []
    for v in variants:
        if not isinstance(v, dict):
            continue
        u = v.get("url")
        if not u:
            continue
        ct = (v.get("content_type") or "").lower()
        if "video/mp4" not in ct:
            continue
        bitrate = v.get("bitrate") or 0
        candidates.append((bitrate, u))
    if not candidates:
        return ""
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def snowflake_to_epoch(tid: str) -> int:
    try:
        if not str(tid).isdigit():
            return 0
        ts_ms = (int(tid) >> 22) + 1288834974657
        return int(ts_ms / 1000)
    except Exception:
        return 0


def created_at_to_epoch(created_at: str, tid: str) -> int:
    try:
        if created_at:
            dt = datetime.strptime(created_at, "%a %b %d %H:%M:%S %z %Y")
            return int(dt.timestamp())
    except Exception:
        pass
    return snowflake_to_epoch(tid)


def parse_syndication(raw_html: str) -> dict:
    m = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', raw_html, re.S)
    if not m:
        return {"ok": False}

    blob = html.unescape(m.group(1))
    try:
        data = json.loads(blob)
    except Exception:
        return {"ok": False}

    page = data.get("props", {}).get("pageProps", {})
    timeline = page.get("timeline", {})
    entries = timeline.get("entries") or []
    latest_id = str(timeline.get("latest_tweet_id") or "").strip()

    def build_item(entry_obj: dict) -> dict:
        tweet = entry_obj.get("content", {}).get("tweet", {})
        source_tweet = tweet.get("retweeted_status") or tweet

        tid = str(source_tweet.get("id_str") or "").strip()
        if not tid:
            eid = str(entry_obj.get("entry_id", ""))
            if eid.startswith("tweet-"):
                tid = eid.split("tweet-", 1)[1]

        if not tid:
            return {}

        permalink = str(source_tweet.get("permalink") or "").strip()
        if permalink.startswith("/"):
            url = f"https://x.com{permalink}"
        elif permalink:
            url = permalink
        else:
            url = f"https://x.com/{account}/status/{tid}"

        text = (source_tweet.get("full_text") or source_tweet.get("text") or "").strip()
        text = re.sub(r"\s+", " ", text)
        text = re.sub(r"https://t\.co/\w+$", "", text).strip()

        user = source_tweet.get("user") or {}
        author = user.get("screen_name") or account

        media_list = []
        media_src = (source_tweet.get("extended_entities") or {}).get("media") or []
        for mobj in media_src:
            if not isinstance(mobj, dict):
                continue
            mtype = str(mobj.get("type") or "").strip().lower()
            image_url = mobj.get("media_url_https") or mobj.get("media_url") or ""
            video_url = choose_video_url(mobj) if mtype in {"video", "animated_gif"} else ""
            alt_text = str(mobj.get("ext_alt_text") or "").strip()
            duration_ms = 0
            if mtype in {"video", "animated_gif"}:
                duration_ms = int(((mobj.get("video_info") or {}).get("duration_millis")) or 0)
            media_list.append(
                {
                    "type": mtype,
                    "image_url": image_url,
                    "video_url": video_url,
                    "thumb_url": image_url,
                    "alt_text": alt_text,
                    "duration_ms": duration_ms,
                }
            )

        entities = source_tweet.get("entities") or {}
        external_urls = []
        for u in entities.get("urls") or []:
            if not isinstance(u, dict):
                continue
            ex = (u.get("expanded_url") or u.get("url") or "").strip()
            if ex:
                external_urls.append(ex)

        def pick_card_text(card_obj: dict, keys):
            bv = (card_obj or {}).get("binding_values") or {}
            for k in keys:
                v = bv.get(k)
                if isinstance(v, dict):
                    s = v.get("string_value")
                    if isinstance(s, str) and s.strip():
                        return s.strip()
            return ""

        card = source_tweet.get("card") or {}
        card_title = pick_card_text(card, ["title"])
        card_desc = pick_card_text(card, ["description", "summary"])
        card_url = pick_card_text(card, ["card_url", "vanity_url"])

        return {
            "id": tid,
            "url": url,
            "text": text,
            "created_at": source_tweet.get("created_at") or "",
            "created_at_fmt": to_local_time(source_tweet.get("created_at") or ""),
            "created_at_ts": created_at_to_epoch(source_tweet.get("created_at") or "", tid),
            "author": author,
            "post_type": "retweet" if tweet.get("retweeted_status") else "post",
            "conversation_id": str(source_tweet.get("conversation_id_str") or tid),
            "reply_count": int(source_tweet.get("reply_count") or 0),
            "retweet_count": int(source_tweet.get("retweet_count") or 0),
            "quote_count": int(source_tweet.get("quote_count") or 0),
            "favorite_count": int(source_tweet.get("favorite_count") or 0),
            "media": media_list,
            "card_title": card_title,
            "card_desc": card_desc,
            "card_url": card_url,
            "external_urls": external_urls,
        }

    items = []
    seen = set()

    # 如果有 latest_tweet_id，优先把它放第一位
    if latest_id:
        key = f"tweet-{latest_id}"
        for e in entries:
            if e.get("entry_id") == key:
                one = build_item(e)
                if one and one["id"] not in seen:
                    items.append(one)
                    seen.add(one["id"])
                break

    for e in entries:
        if not str(e.get("entry_id", "")).startswith("tweet-"):
            continue
        one = build_item(e)
        if not one:
            continue
        if one["id"] in seen:
            continue
        items.append(one)
        seen.add(one["id"])
        if len(items) >= 8:
            break

    if not items:
        return {"ok": False}

    first = items[0]
    return {
        "ok": True,
        "source": "syndication",
        "items": items,
        "id": first.get("id", ""),
        "url": first.get("url", ""),
        "text": first.get("text", ""),
        "created_at": first.get("created_at", ""),
        "created_at_fmt": first.get("created_at_fmt", ""),
        "created_at_ts": int(first.get("created_at_ts") or 0),
        "author": first.get("author", ""),
        "post_type": first.get("post_type", "post"),
        "conversation_id": first.get("conversation_id") or first.get("id", ""),
        "reply_count": int(first.get("reply_count") or 0),
        "retweet_count": int(first.get("retweet_count") or 0),
        "quote_count": int(first.get("quote_count") or 0),
        "favorite_count": int(first.get("favorite_count") or 0),
        "media": first.get("media") or [],
        "card_title": first.get("card_title") or "",
        "card_desc": first.get("card_desc") or "",
        "card_url": first.get("card_url") or "",
        "external_urls": first.get("external_urls") or [],
    }


def parse_jina(raw_text: str) -> dict:
    # jina 返回内容的用户名大小写/别名可能变化，放宽匹配
    pat = re.compile(r"(https://x\.com/([^/\s]+)/status/(\d+))", re.I)
    matches = list(pat.finditer(raw_text))
    if not matches:
        return {"ok": False}

    uniq = {}
    for m in matches:
        sid = m.group(3)
        if sid not in uniq:
            uniq[sid] = m

    # 优先选择和目标账号同名的状态链接，避免误选到转推原作者
    account_l = (account or "").lower()
    same_account = []
    for sid, mm in uniq.items():
        h = (mm.group(2) or "").lower()
        if h == account_l:
            same_account.append((sid, mm))

    pool = same_account if same_account else list(uniq.items())
    latest_sid, latest_m = max(pool, key=lambda x: int(x[0]))

    full_url = latest_m.group(1).replace("http://", "https://")
    author = latest_m.group(2) or account
    idx = latest_m.start()
    lines = raw_text.splitlines()

    line_idx = None
    for i, ln in enumerate(lines):
        if latest_sid in ln and "/status/" in ln:
            line_idx = i
            break
    if line_idx is None:
        line_idx = 0

    def is_meta_line(s: str) -> bool:
        low = s.lower().strip()
        if not low:
            return True
        if low.startswith("title:") or low.startswith("url source:") or low.startswith("published time:"):
            return True
        if low in {"pinned", "markdown content:", account.lower(), f"{account.lower()}’s posts", f"{account.lower()}'s posts"}:
            return True
        if low.startswith("[!") or low.startswith("http") or low.startswith("@"):
            return True
        if "profile picture" in low:
            return True
        if set(low) == {"-"}:
            return True
        return False

    # 优先取“状态链接上一行”作为正文（jina markdown里通常就是这样）
    tweet_text = ""
    j = line_idx - 1
    while j >= 0:
        s = lines[j].strip()
        if not s:
            if tweet_text:
                break
            j -= 1
            continue
        if is_meta_line(s):
            if tweet_text:
                break
            j -= 1
            continue
        tweet_text = s
        break
    tweet_text = re.sub(r"\s+", " ", tweet_text).strip()

    # 尝试提取媒体链接（优先抓与该 status 同行的 media）
    image_urls = []
    scan_start = max(0, line_idx - 4)
    scan_end = min(len(lines), line_idx + 5)
    for ln in lines[scan_start:scan_end]:
        if latest_sid not in ln:
            continue
        for u in re.findall(r"https://pbs\.twimg\.com/media/[^\s\)\]]+", ln):
            u = u.rstrip(".,;:!?")
            if u not in image_urls:
                image_urls.append(u)
            if len(image_urls) >= 4:
                break
        if len(image_urls) >= 4:
            break

    # 兜底：附近窗口中抓取少量 media
    if not image_urls:
        window = raw_text[max(0, idx - 1500): min(len(raw_text), idx + 1500)]
        for u in re.findall(r"https://pbs\.twimg\.com/media/[^\s\)\]]+", window):
            u = u.rstrip(".,;:!?")
            if u not in image_urls:
                image_urls.append(u)
            if len(image_urls) >= 2:
                break

    media = [{"type": "photo", "image_url": u, "video_url": "", "thumb_url": u, "alt_text": "", "duration_ms": 0} for u in image_urls]

    item = {
        "id": latest_sid,
        "url": full_url,
        "text": tweet_text,
        "created_at": "",
        "created_at_fmt": "",
        "created_at_ts": snowflake_to_epoch(latest_sid),
        "author": author,
        "post_type": "post",
        "conversation_id": latest_sid,
        "reply_count": 0,
        "retweet_count": 0,
        "quote_count": 0,
        "favorite_count": 0,
        "media": media,
        "card_title": "",
        "card_desc": "",
        "card_url": "",
        "external_urls": [],
    }

    return {
        "ok": True,
        "source": "jina",
        "items": [item],
        "id": item["id"],
        "url": item["url"],
        "text": item["text"],
        "created_at": "",
        "created_at_fmt": "",
        "created_at_ts": int(item.get("created_at_ts") or 0),
        "author": item["author"],
        "post_type": "post",
        "conversation_id": item.get("conversation_id", item["id"]),
        "reply_count": 0,
        "retweet_count": 0,
        "quote_count": 0,
        "favorite_count": 0,
        "media": item["media"],
        "card_title": "",
        "card_desc": "",
        "card_url": "",
        "external_urls": [],
    }


if mode == "syndication":
    print(json.dumps(parse_syndication(raw), ensure_ascii=False))
else:
    print(json.dumps(parse_jina(raw), ensure_ascii=False))
PY
}

LAST_HTTP_CODE=""
try_fetch() {
  local url="$1"
  local out_file="$2"

  local code
  code="$(curl -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' -L --silent --show-error --max-time "$HTTP_MAX_TIME" --output "$out_file" --write-out '%{http_code}' "$url" || true)"
  LAST_HTTP_CODE="$code"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  return 1
}

RAW_FILE="$(mktemp)"
trap 'rm -f "$RAW_FILE"' EXIT

PARSED_JSON='{}'
NOW_TS="$(date +%s)"
SKIP_SYNDICATION=0
if [[ -f "$COOLDOWN_FILE" ]]; then
  COOL_UNTIL="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
  if [[ "$COOL_UNTIL" =~ ^[0-9]+$ ]] && [[ "$NOW_TS" -lt "$COOL_UNTIL" ]]; then
    if [[ "$ALLOW_JINA_FALLBACK" == "1" ]]; then
      SKIP_SYNDICATION=1
    else
      exit 0
    fi
  fi
fi

if [[ "$SKIP_SYNDICATION" == "0" ]] && try_fetch "https://syndication.twitter.com/srv/timeline-profile/screen-name/${ACCOUNT}" "$RAW_FILE"; then
  PARSED_JSON="$(parse_with_python 'syndication' "$ACCOUNT" "$RAW_FILE")"
  rm -f "$COOLDOWN_FILE" >/dev/null 2>&1 || true
fi

OK="$(printf '%s' "$PARSED_JSON" | jq -r '.ok // false')"
if [[ "$OK" != "true" ]] && [[ "$ALLOW_JINA_FALLBACK" == "1" ]]; then
  if try_fetch "https://r.jina.ai/http://x.com/${ACCOUNT}" "$RAW_FILE"; then
    PARSED_JSON="$(parse_with_python 'jina' "$ACCOUNT" "$RAW_FILE")"
  fi
fi

OK="$(printf '%s' "$PARSED_JSON" | jq -r '.ok // false')"
if [[ "$OK" != "true" ]]; then
  if [[ "$LAST_HTTP_CODE" == "429" ]]; then
    echo "$((NOW_TS + COOLDOWN_SECONDS))" > "$COOLDOWN_FILE"
  fi
  exit 0
fi

ITEMS_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r '(.items // []) | length')"
if [[ "$ITEMS_COUNT" -le 0 ]]; then
  exit 0
fi

LATEST_ID="$(printf '%s' "$PARSED_JSON" | jq -r '.items[0].id // empty')"
LATEST_URL="$(printf '%s' "$PARSED_JSON" | jq -r '.items[0].url // empty')"
if [[ -z "$LATEST_ID" || -z "$LATEST_URL" ]]; then
  exit 0
fi

if [[ "$FORCE_SEND" != "1" ]] && [[ ! -s "$STATE_FILE" ]] && [[ "$BOOTSTRAP_ON_EMPTY_STATE" == "1" ]]; then
  # 首次接入只记录当前最新帖，不推送旧内容
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "$LATEST_ID" > "$STATE_FILE"
  fi
  exit 0
fi

LAST_ID=""
if [[ -f "$STATE_FILE" ]]; then
  LAST_ID="$(cat "$STATE_FILE" 2>/dev/null || true)"
fi

if [[ "$FORCE_SEND" != "1" ]] && [[ -n "$LAST_ID" ]] && [[ "$LAST_ID" == "$LATEST_ID" ]]; then
  exit 0
fi

TO_SEND_INDEXES=()
if [[ "$FORCE_SEND" == "1" ]]; then
  i=0
  while [[ "$i" -lt "$ITEMS_COUNT" ]]; do
    TO_SEND_INDEXES+=("$i")
    if [[ "${#TO_SEND_INDEXES[@]}" -ge "$MAX_POSTS_PER_RUN" ]]; then
      break
    fi
    i="$((i + 1))"
  done
else
  i=0
  while [[ "$i" -lt "$ITEMS_COUNT" ]]; do
    ITEM_ID="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$i].id // empty")"
    if [[ -z "$ITEM_ID" ]]; then
      i="$((i + 1))"
      continue
    fi
    if [[ -n "$LAST_ID" && "$ITEM_ID" == "$LAST_ID" ]]; then
      break
    fi
    if [[ "$LAST_ID" =~ ^[0-9]+$ ]] && [[ "$ITEM_ID" =~ ^[0-9]+$ ]] && [[ "$ITEM_ID" -lt "$LAST_ID" ]]; then
      # 比最后已推送更旧，跳过
      i="$((i + 1))"
      continue
    fi
    TO_SEND_INDEXES+=("$i")
    if [[ "${#TO_SEND_INDEXES[@]}" -ge "$MAX_POSTS_PER_RUN" ]]; then
      break
    fi
    i="$((i + 1))"
  done
fi

if [[ "${#TO_SEND_INDEXES[@]}" -eq 0 ]]; then
  # 没有新帖，更新锚点避免重复扫描
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "$LATEST_ID" > "$STATE_FILE"
  fi
  exit 0
fi

# 二次过滤：最新性 + AI相关性 + 去重
FILTERED_INDEXES=()
FILTERED_CONVS=()
for idx in "${TO_SEND_INDEXES[@]}"; do
  ITEM_ID="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].id // empty")"
  ITEM_URL="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].url // empty")"
  ITEM_TEXT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].text // \"\"")"
  ITEM_TS="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].created_at_ts // 0")"
  ITEM_CARD_TITLE="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].card_title // \"\"")"
  ITEM_CARD_DESC="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].card_desc // \"\"")"
  ITEM_CONV="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].conversation_id // \"\"")"
  if [[ -z "$ITEM_CONV" ]]; then
    ITEM_CONV="$ITEM_ID"
  fi

  if [[ "$ENFORCE_RECENCY" == "1" ]]; then
    if [[ "$(is_recent_post "$ITEM_ID" "$ITEM_TS")" != "1" ]]; then
      continue
    fi
  fi

  if [[ "$ENABLE_AI_RELEVANCE_FILTER" == "1" ]]; then
    if [[ "$(is_ai_relevant "$ACCOUNT" "$ITEM_TEXT" "$ITEM_URL" "$ITEM_CARD_TITLE" "$ITEM_CARD_DESC")" != "1" ]]; then
      continue
    fi
  fi

  if [[ "$(is_sent_recently "$ITEM_ID" "$ITEM_URL" "$ITEM_TEXT")" == "1" ]]; then
    continue
  fi

  FILTERED_INDEXES+=("$idx")
  FILTERED_CONVS+=("$ITEM_CONV")
done

if [[ "${#FILTERED_INDEXES[@]}" -eq 0 ]]; then
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "$LATEST_ID" > "$STATE_FILE"
  fi
  exit 0
fi

if [[ "$ENABLE_THREAD_MERGE" == "1" ]]; then
  MERGED_INDEXES=()
  SEEN_CONVS="|"
  for idx in "${FILTERED_INDEXES[@]}"; do
    ITEM_CONV="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].conversation_id // \"\"")"
    if [[ -z "$ITEM_CONV" ]]; then
      ITEM_CONV="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$idx].id // \"\"")"
    fi
    if [[ "$SEEN_CONVS" == *"|${ITEM_CONV}|"* ]]; then
      continue
    fi
    SEEN_CONVS="${SEEN_CONVS}${ITEM_CONV}|"
    MERGED_INDEXES+=("$idx")
  done
  TO_SEND_INDEXES=("${MERGED_INDEXES[@]}")
else
  TO_SEND_INDEXES=("${FILTERED_INDEXES[@]}")
fi

if [[ "$DRY_RUN" != "1" ]]; then
  echo "$LATEST_ID" > "$STATE_FILE"
fi

build_post_analysis() {
  local text="$1"
  local card_title="$2"
  local card_desc="$3"
  local photo_count="$4"
  local video_count="$5"
  local card_url="$6"
  local external_urls="$7"
  local media_hints="$8"

  python3 - "$text" "$card_title" "$card_desc" "$photo_count" "$video_count" "$card_url" "$external_urls" "$media_hints" <<'PY'
import sys
import re

text, card_title, card_desc, photo_count, video_count, card_url, external_urls, media_hints = sys.argv[1:]

def clean(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "")).strip()

text = clean(text)
card_title = clean(card_title)
card_desc = clean(card_desc)

source = text if text and text != "(已抓到帖子链接，但正文为空)" else clean((card_title + " " + card_desc).strip())
source = re.sub(r"https?://\S+", "", source)
source = re.sub(r"\s+", " ", source).strip()

low = source.lower()

def detect_event_type(s: str) -> str:
    if any(k in s for k in ["statement", "声明", "回应"]):
        return "官方声明更新"
    if any(k in s for k in ["vulnerab", "security", "漏洞", "安全", "修复"]):
        return "安全能力相关进展"
    if any(k in s for k in ["release", "launched", "launch", "shipping", "available", "发布", "上线", "推出"]):
        return "模型或功能发布进展"
    if any(k in s for k in ["research", "paper", "benchmark", "eval", "实验", "研究", "评测"]):
        return "研究或评测结果更新"
    if any(k in s for k in ["api", "sdk", "developer", "dev", "开发者"]):
        return "开发者能力更新"
    if any(k in s for k in ["partner", "partnership", "collaborat", "合作"]):
        return "合作项目进展"
    return "最新动态"

event_type = detect_event_type(low)

actors_raw = re.findall(r"\b[A-Z][A-Za-z0-9_.-]{1,}\b", source)
stop_words = {"I","We","The","A","An","In","On","At","And","Or","To","Of","For","With","From","By","He","She","It","They","This","That"}
actors = []
for a in actors_raw:
    if a in stop_words:
        continue
    if a.lower() in {"http","https","www","com"}:
        continue
    if a not in actors:
        actors.append(a)
    if len(actors) >= 2:
        break

nums = re.findall(r"\b\d+(?:\.\d+)?%?\b", source)

segments = [f"这条帖子在同步{event_type}"]
if actors:
    segments.append(f"涉及主体包括{'、'.join(actors)}")
if "partner" in low or "合作" in low:
    segments.append("内容提到是通过合作推进")
if "vulnerab" in low or "漏洞" in low:
    segments.append("重点是漏洞发现或修复结果")
if "urge developers" in low or "敦促开发人员" in source:
    segments.append("并呼吁开发者加强软件安全防护")
if ("recognized the test" in low and "decrypted answers" in low) or ("识别了测试" in source and "解密了答案" in source):
    segments.append("并披露了评测中模型识别测试并解题的现象")
if nums:
    segments.append(f"披露的关键数据有{'、'.join(nums[:3])}")

summary = "，".join(segments) + "。"
summary = re.sub(r"\s+", " ", summary).strip(" ，。") + "。"
if len(summary) > 120:
    summary = summary[:119].rstrip() + "…"

print(summary)
PY
}

normalize_summary_text() {
  local text="$1"
  python3 - "$text" <<'PY'
import re
import sys

t = (sys.argv[1] or "").replace("\r", " ")
t = re.sub(r"\s+", " ", t).strip()
t = t.replace("这条在说：", "")
t = t.replace("为什么重要：", "")
t = t.replace("你该关注：", "")
t = t.replace("总结：", "")
t = t.replace("建议", "")
t = t.replace("值得关注", "")
t = re.sub(r"\s+", " ", t).strip(" ，。")
if not t:
    t = "这条帖子信息较少，当前只能提取到有限事实。"
if len(t) > 120:
    t = t[:119].rstrip() + "…"
if t and not re.search(r"[。！？!?]$", t):
    t += "。"
print(t)
PY
}

send_one_item() {
  local item_idx="$1"
  local total_items="$2"
  local nth="$3"

  local STATUS_ID STATUS_URL STATUS_TEXT STATUS_SOURCE STATUS_AUTHOR STATUS_POST_TYPE STATUS_TIME STATUS_TS STATUS_CONV
  local REPLY_COUNT RETWEET_COUNT QUOTE_COUNT LIKE_COUNT MEDIA_COUNT PHOTO_COUNT VIDEO_COUNT
  local CARD_TITLE CARD_DESC CARD_URL EXTERNAL_URLS MEDIA_HINTS ANALYSIS_BRIEF MEDIA_JSON_LIMITED DEEP_MEDIA_ANALYSIS
  local HAS_TEXT WORK_TYPE TEXT_BLOCK TRANSLATION_BLOCK TRANSLATION_TEXT EXPLAIN_BLOCK PRIORITY_LABEL THREAD_NOTE THREAD_COUNT_VALUE

  STATUS_ID="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].id // empty")"
  STATUS_URL="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].url // empty")"
  STATUS_TEXT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].text // \"\"")"
  STATUS_SOURCE="$(printf '%s' "$PARSED_JSON" | jq -r '.source // ""')"
  STATUS_AUTHOR="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].author // \"\"")"
  STATUS_POST_TYPE="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].post_type // \"post\"")"
  STATUS_TIME="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].created_at_fmt // \"\"")"
  STATUS_TS="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].created_at_ts // 0")"
  STATUS_CONV="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].conversation_id // \"\"")"
  REPLY_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].reply_count // 0")"
  RETWEET_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].retweet_count // 0")"
  QUOTE_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].quote_count // 0")"
  LIKE_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].favorite_count // 0")"
  MEDIA_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r "(.items[$item_idx].media // []) | length")"
  PHOTO_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r "(.items[$item_idx].media // [] | map(select(.type==\"photo\")) | length)")"
  VIDEO_COUNT="$(printf '%s' "$PARSED_JSON" | jq -r "(.items[$item_idx].media // [] | map(select(.type==\"video\" or .type==\"animated_gif\")) | length)")"
  CARD_TITLE="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].card_title // \"\"")"
  CARD_DESC="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].card_desc // \"\"")"
  CARD_URL="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].card_url // \"\"")"
  EXTERNAL_URLS="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].external_urls // [] | map(select(type==\"string\" and length>0)) | join(\" | \")")"
  MEDIA_HINTS="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].media // [] | map(.alt_text // \"\") | map(select(length>0)) | unique | join(\" | \")")"
  MEDIA_JSON_LIMITED="$(printf '%s' "$PARSED_JSON" | jq -c ".items[$item_idx].media // [] | map({type:(.type // \"\"), alt_text:(.alt_text // \"\"), duration_ms:(.duration_ms // 0), image_url:(.image_url // \"\"), video_url:(.video_url // \"\"), thumb_url:(.thumb_url // \"\")}) | .[:$DEEP_ANALYSIS_MAX_MEDIA_ITEMS]")"

  if [[ -z "$STATUS_ID" || -z "$STATUS_URL" ]]; then
    return 0
  fi

  if [[ -z "$STATUS_CONV" ]]; then
    STATUS_CONV="$STATUS_ID"
  fi
  THREAD_COUNT_VALUE=0
  for c in "${FILTERED_CONVS[@]:-}"; do
    if [[ "$c" == "$STATUS_CONV" ]]; then
      THREAD_COUNT_VALUE=$((THREAD_COUNT_VALUE + 1))
    fi
  done
  if [[ "$THREAD_COUNT_VALUE" -le 0 ]]; then
    THREAD_COUNT_VALUE=1
  fi
  THREAD_NOTE=""
  if [[ "$THREAD_COUNT_VALUE" -gt 1 ]]; then
    THREAD_NOTE="（同主题连发 ${THREAD_COUNT_VALUE} 条，已合并）"
  fi

  if [[ -z "$STATUS_TIME" ]] && [[ "$STATUS_ID" =~ ^[0-9]+$ ]]; then
    STATUS_TIME="$(tweet_id_to_time "$STATUS_ID" 2>/dev/null || true)"
  fi
  if [[ -z "$STATUS_TIME" ]]; then
    STATUS_TIME="未知"
  fi

  if [[ -z "$STATUS_TEXT" ]]; then
    STATUS_TEXT="(已抓到帖子链接，但正文为空)"
  fi

  local TRANSLATION
  TRANSLATION=""
  if [[ "$ENABLE_TRANSLATION" == "1" && -n "$STATUS_TEXT" && "$STATUS_TEXT" != "(已抓到帖子链接，但正文为空)" ]]; then
    TRANSLATION="$(translate_to_zh "$STATUS_TEXT" 2>/dev/null || true)"
  fi

  ANALYSIS_BRIEF=""
  if [[ "$ENABLE_ANALYSIS" == "1" ]]; then
    SUMMARY_INPUT_TEXT="$STATUS_TEXT"
    if [[ -n "$TRANSLATION" && "$TRANSLATION" != "翻译服务暂时不可用，先附原文供你查看。" ]]; then
      SUMMARY_INPUT_TEXT="$TRANSLATION"
    fi
    ANALYSIS_BRIEF="$(build_post_analysis "$SUMMARY_INPUT_TEXT" "$CARD_TITLE" "$CARD_DESC" "$PHOTO_COUNT" "$VIDEO_COUNT" "$CARD_URL" "$EXTERNAL_URLS" "$MEDIA_HINTS" 2>/dev/null || true)"
  fi
  if [[ -z "$ANALYSIS_BRIEF" ]]; then
    ANALYSIS_BRIEF="这条帖子正文较短，当前可提取的信息有限。"
  fi

  DEEP_MEDIA_ANALYSIS=""
  if [[ "$ENABLE_DEEP_MEDIA_ANALYSIS" == "1" ]] && [[ "$DRY_RUN" != "1" ]]; then
    DEEP_PROMPT="$(cat <<EOF
你是“社媒内容总结助手”。请输出一段简体中文总结，只说明这条帖子讲了什么事实内容。
要求：
1) 只输出总结正文，不要标题；
2) 不要出现“为什么重要”“你该关注”“建议”“值得关注”等词；
3) 不要额外解释，不要分点；
4) 控制在120字以内。

帖子文本：
${STATUS_TEXT}

卡片标题：
${CARD_TITLE}

卡片描述：
${CARD_DESC}

外链：
${EXTERNAL_URLS}

帖子链接：
${STATUS_URL}

媒体元数据(JSON)：
${MEDIA_JSON_LIMITED}
EOF
)"
    DEEP_MEDIA_ANALYSIS="$(run_agent_timeout "$DEEP_PROMPT" "$DEEP_ANALYSIS_TIMEOUT" 2>/dev/null || true)"
  fi
  if [[ -z "$DEEP_MEDIA_ANALYSIS" ]]; then
    DEEP_MEDIA_ANALYSIS="$ANALYSIS_BRIEF"
  fi

  HAS_TEXT=1
  if [[ -z "$STATUS_TEXT" || "$STATUS_TEXT" == "(已抓到帖子链接，但正文为空)" ]]; then
    HAS_TEXT=0
  fi

  if [[ "$VIDEO_COUNT" -gt 0 && "$PHOTO_COUNT" -gt 0 && "$HAS_TEXT" -eq 1 ]]; then
    WORK_TYPE="帖子（文本+图片+视频）"
  elif [[ "$VIDEO_COUNT" -gt 0 && "$PHOTO_COUNT" -gt 0 ]]; then
    WORK_TYPE="帖子（图片+视频）"
  elif [[ "$VIDEO_COUNT" -gt 0 && "$HAS_TEXT" -eq 1 ]]; then
    WORK_TYPE="帖子（文本+视频）"
  elif [[ "$PHOTO_COUNT" -gt 0 && "$HAS_TEXT" -eq 1 ]]; then
    WORK_TYPE="帖子（文本+图片）"
  elif [[ "$VIDEO_COUNT" -gt 0 ]]; then
    WORK_TYPE="视频"
  elif [[ "$PHOTO_COUNT" -gt 0 ]]; then
    WORK_TYPE="图片"
  elif [[ "$HAS_TEXT" -eq 1 ]]; then
    WORK_TYPE="文本"
  else
    WORK_TYPE="帖子"
  fi

  if [[ "$HAS_TEXT" -eq 1 ]]; then
    TEXT_BLOCK="$STATUS_TEXT"
  else
    TEXT_BLOCK="(无正文)"
  fi

  TRANSLATION_TEXT="$TRANSLATION"
  if [[ -z "$TRANSLATION_TEXT" ]]; then
    TRANSLATION_TEXT="(翻译暂不可用)"
  fi
  TRANSLATION_BLOCK="$(cat <<EOF
正文翻译：
${TRANSLATION_TEXT}
EOF
)"

  EXPLAIN_BLOCK="$DEEP_MEDIA_ANALYSIS"
  EXPLAIN_BLOCK="$(normalize_summary_text "$EXPLAIN_BLOCK" 2>/dev/null || true)"
  if [[ -z "$EXPLAIN_BLOCK" ]]; then
    EXPLAIN_BLOCK="$ANALYSIS_BRIEF"
  fi
  PRIORITY_LABEL="$(priority_level "$ACCOUNT" "$STATUS_TEXT" 2>/dev/null || echo 中)"

  HEADER_MSG="$(cat <<EOF
[AI圈最新消息] @${ACCOUNT} (${nth}/${total_items})
1、作者：@${STATUS_AUTHOR}
2、发布时间：${STATUS_TIME}
3、作品类型：${WORK_TYPE}
优先级：${PRIORITY_LABEL}${THREAD_NOTE}
4、正文：
${TEXT_BLOCK}
${TRANSLATION_BLOCK}
5、总结：
${EXPLAIN_BLOCK}
EOF
)"
  if ! send_text "$HEADER_MSG"; then
    return 0
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    mark_sent "$STATUS_ID" "$STATUS_URL" "$STATUS_TEXT"
  fi

  if [[ "$MEDIA_COUNT" -le 0 ]]; then
    return 0
  fi

  limit="$MEDIA_COUNT"
  if [[ "$limit" -gt "$MAX_MEDIA" ]]; then
    limit="$MAX_MEDIA"
  fi

  i=0
  while [[ "$i" -lt "$limit" ]]; do
    mtype="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].media[$i].type // \"\"")"
    image_url="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].media[$i].image_url // \"\"")"
    video_url="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].media[$i].video_url // \"\"")"
    thumb_url="$(printf '%s' "$PARSED_JSON" | jq -r ".items[$item_idx].media[$i].thumb_url // \"\"")"
    media_idx="$((i + 1))"

    case "$mtype" in
      photo)
        send_media "$image_url" "📷 图片 ${media_idx}/${limit}" || true
        ;;
      video|animated_gif)
        if ! send_media "$video_url" "🎬 视频 ${media_idx}/${limit}"; then
          send_media "$thumb_url" "🎬 视频预览 ${media_idx}/${limit}（视频发送失败，保留封面）" || true
          send_text "🎬 视频直链（发送失败回退）：${video_url}" || true
        fi
        ;;
      *)
        send_media "$image_url" "📎 附件预览 ${media_idx}/${limit}" || true
        ;;
    esac
    i="$((i + 1))"
  done
}

total="${#TO_SEND_INDEXES[@]}"
rank=1
for ((k=total-1; k>=0; k--)); do
  send_one_item "${TO_SEND_INDEXES[$k]}" "$total" "$rank"
  rank="$((rank + 1))"
done
