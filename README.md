# kakaocli

**CLI tool for KakaoTalk on macOS — read chats, search messages, send texts, and integrate with AI agents.**

**macOS용 카카오톡 CLI 도구 — 채팅 읽기, 메시지 검색, 텍스트 전송, AI 에이전트 연동.**

<p align="center">
  <img src="assets/demo.svg" alt="kakaocli demo" width="820">
</p>

> [!NOTE]
> This tool reads KakaoTalk's local database and automates the UI via macOS Accessibility APIs. It does not reverse-engineer the KakaoTalk protocol or call any Kakao APIs. See [Disclaimer](#disclaimer) for details.

---

**[English](#overview)** | **[한국어](#개요)**

---

## Overview

kakaocli lets AI agents (Claude Code, Cursor, custom bots) check and send your KakaoTalk messages — something Kakao's official APIs simply can't do.

- **AI Agent Integration** — JSON output for every command, MCP skill definition, webhook delivery, auto-login
- **Read** — list chats, view messages, full-text search, raw SQL queries
- **Send** — send messages to any chat via UI automation
- **Sync** — real-time NDJSON message stream with webhook support
- **Harvest** — bulk-capture chat names and load older message history

### Why?

Kakao's official APIs cannot read chat history, export conversations, or send free-form messages. If you want an AI agent to check your messages, summarize conversations, or reply on your behalf — there's no official way to do it. kakaocli fills that gap by reading the local database and automating the native macOS client.

## 개요

kakaocli는 AI 에이전트(Claude Code, Cursor, 커스텀 봇)가 카카오톡 메시지를 확인하고 보낼 수 있게 해줍니다 — 카카오 공식 API로는 불가능한 기능입니다.

- **AI 에이전트 연동** — 모든 명령의 JSON 출력, MCP 스킬 정의, 웹훅 전달, 자동 로그인
- **읽기** — 채팅 목록, 메시지 조회, 전체 텍스트 검색, SQL 쿼리
- **전송** — UI 자동화를 통한 메시지 전송
- **동기화** — 실시간 NDJSON 메시지 스트림 및 웹훅 지원
- **수집** — 채팅방 이름 일괄 수집 및 이전 메시지 로드

### 왜 필요한가요?

카카오 공식 API로는 채팅 기록을 읽거나, 대화를 내보내거나, 자유로운 메시지를 보낼 수 없습니다. AI 에이전트가 메시지를 확인하거나, 대화를 요약하거나, 대신 답장하게 하고 싶어도 공식적인 방법이 없습니다. kakaocli는 로컬 데이터베이스를 읽고 네이티브 macOS 클라이언트를 자동화하여 이 부분을 해결합니다.

## Getting Started / 시작하기

### 1. Install / 설치

**Option A: Homebrew (recommended)**

```bash
brew install silver-flight-group/tap/kakaocli
```

This installs sqlcipher automatically and builds from source (~20 seconds).

**Option B: Build from source**

```bash
brew install sqlcipher
git clone https://github.com/silver-flight-group/kakaocli.git
cd kakaocli
swift build -c release
# Binary is at .build/release/kakaocli
# Either add to PATH or run directly:
.build/release/kakaocli status
# Or use swift run:
swift run kakaocli status
```

### 2. Grant permissions / 권한 부여

Your terminal app needs two permissions in **System Settings > Privacy & Security**:

터미널 앱에 다음 두 가지 권한이 필요합니다 (**시스템 설정 > 개인정보 보호 및 보안**):

- **Full Disk Access** (전체 디스크 접근) — to read KakaoTalk's encrypted database
- **Accessibility** (접근성) — for UI automation (sending messages, harvest)

> [!NOTE]
> Full Disk Access is required for all commands. Accessibility is only needed for `send`, `harvest`, and `inspect`.

### 3. Verify it works / 동작 확인

```bash
# Check KakaoTalk installation and permissions
kakaocli status

# Verify database decryption
kakaocli auth

# List your most recent chats
kakaocli chats --limit 10
```

If `auth` succeeds, you're all set. All read commands work immediately — no KakaoTalk login or window required.

`auth`가 성공하면 준비 완료입니다. 모든 읽기 명령은 카카오톡 창 없이도 바로 작동합니다.

### 4. Try it out / 사용해보기

```bash
# Search across all your messages
kakaocli search "점심"

# Read recent messages from a chat (substring match on name)
kakaocli messages --chat "지수" --since 7d

# Discover the stable chat ID, then send exact stdin with an idempotency UUID
kakaocli chats --json
printf '%s' '안녕!' | kakaocli send --chat-id 123456 --request-id "$(uuidgen)" --json

# Self-chat is the only safe live-test destination
printf '%s' 'test message' | kakaocli send --self --request-id "$(uuidgen)" --json

# Stream new messages as JSON
kakaocli sync --follow

# Run a custom SQL query against the database
kakaocli query "SELECT COUNT(*) FROM NTChatMessage"
```

> [!TIP]
> Sending accepts only an exact numeric chat ID or `--self`. A result is
> `confirmed` only when the exact outgoing bytes appear under that chat ID in
> the local database. Repeating the exact same request ID only reconciles the
> database and never repeats the UI action. Never retry `unknown` with a new ID.

## Commands

### Read / 읽기

| Command | Description |
|---------|-------------|
| `kakaocli status` | Check KakaoTalk installation and permissions |
| `kakaocli auth` | Verify database decryption |
| `kakaocli chats` | List chats sorted by last activity |
| `kakaocli messages --chat "name"` | Show messages from a chat (substring match) |
| `kakaocli search "keyword"` | Full-text search across all messages |
| `kakaocli schema` | Dump raw database schema |
| `kakaocli query "SQL"` | Run read-only SQL against the decrypted database |

All read commands support `--json` for structured output.

모든 읽기 명령은 `--json` 옵션으로 구조화된 출력을 지원합니다.

### Send / 전송

```bash
printf '%s' 'message' | kakaocli send --chat-id 123456 --request-id UUID
printf '%s' 'message' | kakaocli send --self --request-id UUID
printf '%s' 'message' | kakaocli send --self --request-id UUID --dry-run
```

`send` never launches or activates KakaoTalk, raises a window, moves the cursor,
or posts global input. KakaoTalk must already be running with its main window
rendered. The command resolves the ID through the local database, requires one
database-unique UI identity and one exact row in the structurally verified,
selected Chats tab, rejects every already-open room and all drafts, verifies
selection/focus/window title/composer/control identity immediately before the
action, and uses one exact Send control or a focused-composer Return event
delivered only to KakaoTalk's process. A same-process mutex and cross-process
lock cover the whole resolution, UI, and exact database-confirmation
transaction. Bodies are capped at 64 KiB of UTF-8.

### Sync / 동기화

```bash
kakaocli sync --follow                              # NDJSON stream of new messages
kakaocli sync --follow --interval 1                  # Poll every 1 second
kakaocli sync --follow --webhook http://localhost:8080/kakao  # POST to webhook
```

See [AGENTS.md](AGENTS.md) for AI agent integration instructions.

### Harvest / 수집

```bash
kakaocli harvest                   # Capture display names for all chats
kakaocli harvest --scroll          # Also load older message history
kakaocli harvest --scroll --top 20 # Process top 20 most recent chats
kakaocli harvest --dry-run         # Preview without changes
```

The harvest command iterates through your chat list to:
1. Capture **display names** from the UI (many group chats show `(unknown)` in the database)
2. With `--scroll`: open each chat, scroll to top, click "View Previous Chats" to load older messages
3. Auto-dismiss **Talk Drive Plus paywall** popups
4. Save metadata to `~/.kakaocli/metadata.json`

Chats with unread messages are skipped to avoid marking them as read.

### Login / 로그인

```bash
kakaocli login                                       # Store credentials (interactive)
kakaocli login --email user@example.com --password pw # Non-interactive
kakaocli login --status                               # Check status
kakaocli login --clear                                # Remove credentials
```

The `login` command can manage stored credentials. `send` deliberately does
not enter the app lifecycle path and fails closed when the rendered main window
is unavailable; the user may foreground KakaoTalk manually.

## AI Integration / AI 연동

kakaocli is designed to work with AI coding assistants and agents. Every read
command outputs structured JSON. Sending deliberately does not enter the app
lifecycle path.

### Claude Code

Add kakaocli as a skill in your project's `CLAUDE.md`:

```markdown
## KakaoTalk Integration

Use `kakaocli` to read and send KakaoTalk messages:
- `kakaocli chats --json` — list all chats
- `kakaocli messages --chat "name" --json` — read messages
- `kakaocli search "keyword" --json` — search messages
- `printf message | kakaocli send --chat-id ID --request-id UUID` — send to an exact ID
- `printf message | kakaocli send --self --request-id UUID` — self-chat test
```

Or copy the skill file directly:

```bash
# Copy the skill definition to your project
cp skills/kakaocli/SKILL.md /path/to/your/project/.claude/skills/
```

Claude Code can then read your KakaoTalk messages, search conversations, and send messages on your behalf.

### Cursor / Windsurf / Other AI Editors

Add to your project rules or `.cursorrules`:

```
You have access to kakaocli for KakaoTalk messaging.
Run `kakaocli chats --json` to list chats.
Run `kakaocli messages --chat "name" --since 1d --json` to read messages.
Pipe approved text to `kakaocli send --chat-id ID --request-id UUID`.
Always use `--self` for live tests and never retry an `unknown` result.
Always ask for confirmation before sending messages to other people.
```

### Webhooks & Real-time Agents

For agents that need to react to incoming messages in real-time:

```bash
# Stream new messages as NDJSON (pipe to your agent)
kakaocli sync --follow | your-agent-processor

# Or POST to a webhook endpoint
kakaocli sync --follow --webhook http://localhost:8080/kakao
```

Each new message is delivered as a JSON object:

```json
{"chatId": 123, "logId": 456, "author": "김지수", "message": "안녕!", "sentAt": "2026-02-20T09:15:00Z"}
```

### OpenClaw

A kakaocli [skill definition](skills/kakaocli/SKILL.md) is included for use with [OpenClaw](https://github.com/nichochar/open-claw) or similar skill registries.

See [AGENTS.md](AGENTS.md) for detailed integration instructions including credential setup, lifecycle management, and error handling.

## How It Works / 동작 원리

kakaocli reads KakaoTalk's local SQLCipher-encrypted database in **read-only mode** — it never modifies the database. For sending messages and UI interactions, it uses macOS Accessibility APIs (AXUIElement) to automate the native KakaoTalk client.

kakaocli는 카카오톡의 로컬 SQLCipher 암호화 데이터베이스를 **읽기 전용 모드**로 읽습니다 — 데이터베이스를 절대 수정하지 않습니다. 메시지 전송 및 UI 상호작용에는 macOS 접근성 API(AXUIElement)를 사용하여 네이티브 카카오톡 클라이언트를 자동화합니다.

## Known Limitations / 알려진 제한 사항

> [!WARNING]
> **macOS only.** This tool works exclusively with KakaoTalk for Mac. It does not support Windows, mobile, or web versions.

- **Incomplete message history.** KakaoTalk Mac only syncs messages from the server when you open a chat. If you haven't opened a chat on your Mac in a while (or ever), older messages won't be in the local database. Use `kakaocli harvest --scroll` to trigger loading older history, but this is limited by KakaoTalk's own sync behavior and the Talk Drive Plus paywall.
- **Group chat names may show as `(unknown)`.** The database doesn't always store display names for group chats. Run `kakaocli harvest` to capture names from the UI.
- **Sending requires a rendered KakaoTalk main window.** `send` never launches or activates KakaoTalk and fails closed if the app or main window is unavailable. The user may foreground it manually. Read commands work from the local database; `harvest` still uses its separate foreground UI workflow.
- **One Mac at a time.** KakaoTalk only allows one Mac logged in per account.
- **Media and non-text messages.** Currently only text messages are fully supported. Photos, videos, stickers, and other media types are visible in the database but not rendered.

> [!WARNING]
> **macOS 전용.** 이 도구는 카카오톡 Mac 버전에서만 작동합니다.

- **불완전한 메시지 기록.** 카카오톡 Mac은 채팅을 열어야 서버에서 메시지를 동기화합니다. Mac에서 오래 열지 않은 채팅은 이전 메시지가 로컬 데이터베이스에 없을 수 있습니다. `kakaocli harvest --scroll`로 이전 메시지 로드를 시도할 수 있지만, 카카오톡 자체 동기화 및 톡드라이브 플러스 페이월에 의해 제한됩니다.
- **그룹 채팅 이름이 `(unknown)`으로 표시될 수 있습니다.** `kakaocli harvest`를 실행하여 UI에서 이름을 수집하세요.
- **전송 시 카카오톡 메인 창 필요.** `send`는 카카오톡을 실행하거나 활성화하지 않으며 앱이나 메인 창을 사용할 수 없으면 실패합니다. 사용자가 직접 카카오톡을 전면에 표시할 수 있습니다. `harvest`의 별도 UI 흐름은 계속 포그라운드 권한이 필요합니다.
- **계정당 Mac 1대.** 카카오톡은 계정당 하나의 Mac만 로그인을 허용합니다.
- **미디어 및 비텍스트 메시지.** 현재 텍스트 메시지만 완전히 지원됩니다.

## Disclaimer

> **This project is not affiliated with, endorsed by, or associated with Kakao Corp. in any way.**
>
> "KakaoTalk" and "카카오톡" are trademarks of Kakao Corp. This tool is an independent, unofficial project.
>
> **What this tool does:**
> - Reads the KakaoTalk local database on your own machine (read-only, never modifies it)
> - Automates the native KakaoTalk Mac client via standard macOS Accessibility APIs
>
> **What this tool does NOT do:**
> - Does not reverse-engineer or reimplement the KakaoTalk protocol (LOCO)
> - Does not call any Kakao APIs or servers
> - Does not decompile or modify the KakaoTalk application
> - Does not bypass any authentication or security mechanisms
>
> This tool accesses only your own data stored locally on your own computer. Use responsibly and at your own risk. The authors are not responsible for any consequences of using this software, including but not limited to account restrictions by Kakao.

## 면책 조항

> **이 프로젝트는 카카오와 제휴, 보증, 또는 관련이 없습니다.**
>
> "KakaoTalk" 및 "카카오톡"은 카카오의 상표입니다. 이 도구는 독립적인 비공식 프로젝트입니다.
>
> **이 도구가 하는 것:**
> - 사용자의 컴퓨터에 있는 카카오톡 로컬 데이터베이스를 읽기 전용으로 읽습니다
> - 표준 macOS 접근성 API를 통해 카카오톡 Mac 클라이언트를 자동화합니다
>
> **이 도구가 하지 않는 것:**
> - 카카오톡 프로토콜(LOCO)을 역분석하거나 재구현하지 않습니다
> - 카카오 API나 서버를 호출하지 않습니다
> - 카카오톡 애플리케이션을 디컴파일하거나 수정하지 않습니다
>
> 이 도구는 사용자 본인의 컴퓨터에 저장된 본인의 데이터에만 접근합니다. 책임감 있게 사용하시기 바랍니다. 카카오의 계정 제한 등 이 소프트웨어 사용으로 인한 결과에 대해 저자는 책임지지 않습니다.

## Credits / 크레딧

Developed by **[Brian ByungHyun Shin](https://github.com/brianshin22)** at **[Silver Flight Group](https://github.com/silver-flight-group)**.

Database decryption approach based on research by [blluv](https://gist.github.com/blluv/8418e3ef4f4aa86004657ea524f2de14).

Inspired by [wacli](https://github.com/steipete/wacli) by Peter Steinberger — a similar CLI tool for WhatsApp on Mac.

Built with [Claude Code](https://claude.ai/code).

## License

MIT License. Copyright (c) 2026 Silver Flight Group, LLC. See [LICENSE](LICENSE) for details.

## [Changelog](CHANGELOG.md)
