# OpenClaw X -> Feishu Monitor

一个可复用的“X（Twitter）账号监控并推送到飞书”项目。

文档：
- 中文：`README.md`
- English: `README.en.md`

特性：
- 监听指定 X 账号的新帖子（仅推新，默认不推历史旧帖）
- 双通道推送：
  - 实时推送：有新帖就推
  - 每天早上 8:00 补推：无新帖则不推
- 推送到飞书（通过 `openclaw message send --channel feishu`）
- 自动输出：作者、发布时间、作品类型、正文+翻译、总结
- 发布时间统一为中国时间（`UTC+8`）
- 支持图片/视频媒体推送
- 支持多账号批量轮询

## 1. 前置要求

- macOS / Linux
- 已安装并可执行：`openclaw`、`jq`、`curl`、`python3`
- 已在 OpenClaw 内完成 Feishu channel 配置（能正常 `openclaw message send`）

快速自检：

```bash
openclaw --version
jq --version
python3 --version
```

## 2. 快速开始

```bash
cd openclaw-x-feishu-monitor
cp .env.example .env
```

编辑 `.env`（至少要填 `FEISHU_TARGET`）：

```dotenv
FEISHU_TARGET=ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
STATE_DIR=.state
```

编辑 `accounts.txt`，每行一个账号（不带 `@`）：

```text
OpenAI
AnthropicAI
cursor_ai
openaidevs
sama
```

单账号测试（建议先 dry-run）：

```bash
DRY_RUN=1 ./scripts/run_once.sh OpenAI
```

批量运行：

```bash
./scripts/run_batch.sh
```

## 3. 定时运行（macOS launchd）

安装后会创建 2 个服务：
- `realtime`：实时轮询（默认每 180 秒）
- `daily`：每天 08:00 补推一次（没有新帖就不推）

默认安装：

```bash
./scripts/install_launchd.sh
```

自定义实时间隔和每日时间：

```bash
REALTIME_INTERVAL_SECONDS=180 DAILY_HOUR=8 DAILY_MINUTE=0 ./scripts/install_launchd.sh
```

查看状态：

```bash
launchctl print gui/$UID/com.openclaw.x-feishu.monitor.realtime
launchctl print gui/$UID/com.openclaw.x-feishu.monitor.daily
```

卸载：

```bash
./scripts/uninstall_launchd.sh
```

## 4. 关键配置说明

`.env` 常用项：

- `FEISHU_TARGET`：飞书接收目标（必填，`DRY_RUN=0` 时）
- `STATE_DIR`：状态目录，保存每个账号的 last_status、去重缓存
- `ENFORCE_RECENCY=1`：只推送最近窗口的新帖
- `MAX_POST_AGE_HOURS=24`：最新性窗口（小时）
- `ENABLE_TRANSLATION=1`：正文翻译
- `ENABLE_ANALYSIS=1`：开启第 5 点总结
- `ENABLE_DEEP_MEDIA_ANALYSIS=0`：默认关闭深度总结模型调用（更稳）
- `ALLOW_JINA_FALLBACK=1`：主源失败时允许备用抓取源
- `DAILY_MAX_POST_AGE_HOURS=24`：每日 8:00 补推时仅看最近多少小时

## 5. 推送格式

```text
[AI圈最新消息]
1、作者
2、发布时间（中国时间 UTC+8）
3、作品类型
4、正文 + 正文翻译
5、总结
```

## 6. 上传到 GitHub

```bash
cd /Users/wangxinglin/Desktop/openclaw-x-feishu-monitor
git init
git add .
git commit -m "feat: openclaw x to feishu monitor"
# 替换为你的仓库地址
git remote add origin https://github.com/<yourname>/openclaw-x-feishu-monitor.git
git branch -M main
git push -u origin main
```

注意：
- `.env` 已在 `.gitignore` 中，避免把私钥/ID传上去
- 如果你更新了飞书或 OpenRouter 密钥，只改本地 `.env` 或 OpenClaw 认证即可

## 7. 故障排查

- 无消息：先 `DRY_RUN=1 ./scripts/run_once.sh OpenAI` 看是否能抓到帖子
- 报 401/鉴权错误：检查 OpenClaw 的 Feishu channel 是否可用
- 报 rate_limit / cooldown：等待冷却后自动恢复
- 定时任务无输出：看日志 `logs/realtime.log`、`logs/daily.log`、`logs/realtime.launchd.err.log`、`logs/daily.launchd.err.log`
