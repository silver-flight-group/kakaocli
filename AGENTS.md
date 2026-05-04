# AGENTS.md — KakaoCLI for AI Agents

Instructions for AI agents that want to read and send KakaoTalk messages.

## Prerequisites

- macOS 14+ with KakaoTalk desktop app installed
- `kakaocli` binary built and in PATH (or run via `swift run kakaocli`)
- System Settings > Privacy & Security: **Full Disk Access** + **Accessibility** granted to your terminal
- KakaoTalk credentials stored (see First-Time Setup below)

## Source of Truth

- Treat `~/Repository/kakaocli-upstream` as the source of truth.
- For this machine's OpenClaw runtime, point `~/.openclaw/openclaw.json` at the stable built binary path:
  - `~/Repository/kakaocli-upstream/.build/arm64-apple-macosx/release/kakaocli`
- Source edits do not affect the live OpenClaw runtime until you rebuild with `swift build -c release`.
- After AX/send fixes, prefer this local rollout order:
  1. `swift test -Xcc -I/opt/homebrew/include -Xlinker -L/opt/homebrew/lib`
  2. `swift build -c release -Xcc -I/opt/homebrew/include -Xlinker -L/opt/homebrew/lib`
  3. `./.build/release/kakaocli status`
  4. Restart the gateway in its current mode: use `launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway"` when `~/.openclaw/bin/openclaw-gateway-screen.py status` shows `screenRunning: false`; use `~/.openclaw/bin/openclaw-gateway-screen.py restart` only when screen mode is already active.

## First-Time Setup

Before using kakaocli, store credentials so the tool can auto-login:

```bash
# Store KakaoTalk credentials (saved in macOS Keychain)
kakaocli login --email user@example.com --password yourpassword

# Verify everything is working
kakaocli login --status
# Expected output includes: "Stored credentials: Yes"
```

**Important for AI agents:** The `--password` flag is required in non-interactive contexts (scripts, automation, Claude Code). The interactive `kakaocli login` prompt uses `getpass()` which doesn't work outside a real terminal.

### Credential Storage

- Stored in macOS login Keychain under service `com.kakaocli.credentials`
- Two items: `kakaotalk-email` and `kakaotalk-password`
- Persists across reboots, encrypted by macOS (AES-256-GCM)
- Accessible by any process running as the current macOS user
- Uses `security` CLI tool (not Security.framework) to avoid code-signing ACL issues

To inspect or manage credentials manually:
```bash
# Read stored email
security find-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-email" -w

# Delete stored credentials
security delete-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-email"
security delete-generic-password -s "com.kakaocli.credentials" -a "kakaotalk-password"
```

## Automatic Lifecycle Management

You do **NOT** need to manually launch or log into KakaoTalk. The tool handles it automatically:

| Situation | What happens |
|-----------|-------------|
| App not running | Launches KakaoTalk via `NSWorkspace` |
| Login screen showing | Auto-fills credentials and clicks "Log in" |
| "Keep me logged in" | Checked automatically — future launches skip login |
| Window hidden (menu bar only) | Detects state via status bar menu items |
| Already logged in | Proceeds immediately |

The first auto-login after a fresh install takes 5-10 seconds. With "Keep me logged in" checked, subsequent launches are near-instant.

### App State Detection

```bash
kakaocli login --status
```

| State | Meaning |
|-------|---------|
| `loggedIn` | Ready to use |
| `loginScreen` | Needs login (will auto-login if credentials stored) |
| `notRunning` | KakaoTalk not running (will auto-launch on next command) |
| `launching` | App starting up |
| `unknown` | Transient state during transitions |

### Known AX Quirks

KakaoTalk's macOS Accessibility (AX) hierarchy is non-standard:
- `kAXWindowsAttribute` may return `AXApplication` elements instead of `AXWindow`
- When the window is hidden (app running in menu bar), there are zero real AXWindow elements
- The **status bar menu** is the most reliable state indicator ("Log out" present = logged in)
- After login, the window briefly disappears during the transition — don't poll aggressively
- Inline composers and dedicated chat windows can differ between builds, so keep message-composer detection in shared helpers rather than duplicating it per command

## Quick Start

```bash
# Verify database access
kakaocli auth

# List recent chats
kakaocli chats --json

# Read messages from a specific chat
kakaocli messages --chat "Mom" --since 1h --json

# Send a message (auto-launches and logs in if needed)
kakaocli send "Mom" "I'll be home soon"

# Send to self-chat (for testing — ALWAYS use this for tests)
kakaocli send x --me "Test message"

# Preview leaving a chatroom
kakaocli leave --dry-run "Test Room"

# Watch for new messages (NDJSON stream)
kakaocli sync --follow
```

## Reading Messages

### List Chats
```bash
kakaocli chats --json --limit 20
```
Returns: `[{"id", "type", "display_name", "member_count", "unread_count", "last_message_at"}]`

### Read Messages
```bash
kakaocli messages --chat "Name" --since 1h --json
kakaocli messages --chat-id 12345 --limit 100 --json
```
Returns: `[{"id", "chat_id", "sender_id", "sender", "text", "type", "timestamp", "is_from_me"}]`

### Search
```bash
kakaocli search "keyword" --json
```

## Sending Messages

```bash
kakaocli send "Chat Name" "Message text"
kakaocli send x --me "Self-chat message"    # --me flag for self-chat
kakaocli send "Mom" "Hello" --dry-run       # Preview without sending
```

**Important constraints:**
- KakaoTalk is auto-launched if needed (no need to start it manually)
- UI automation needs Accessibility permission granted to your terminal
- Rate limit: wait at least 2 seconds between sends
- The chat window opens, types, sends, then closes automatically
- The `--me` flag sends to self-chat regardless of the chat name argument (use `_` as placeholder)

## Leaving Chatrooms

```bash
kakaocli leave --dry-run "Chat Name"   # Preview without leaving
kakaocli leave "Chat Name"             # Leave a chatroom via the KakaoTalk menu
```

**Important constraints:**
- This is destructive for that KakaoTalk account; use `--dry-run` before testing.
- UI automation needs Accessibility permission granted to your terminal or runtime binary.
- Do not run actual leave tests against shared rooms unless the user explicitly asks.

## Sync Mode (Real-Time Monitoring)

### NDJSON Stream
```bash
kakaocli sync --follow
```
Outputs one JSON object per line (NDJSON) for each new message:
```json
{"type":"message","log_id":123,"chat_id":456,"chat_name":"Mom","sender_id":789,"sender":"Mom","text":"Are you coming?","message_type":1,"timestamp":"2026-02-20T10:30:00Z","is_from_me":false}
```

### With Webhook
```bash
kakaocli sync --follow --webhook http://localhost:8080/kakao
```
POSTs batches of new messages as JSON arrays to the webhook URL.

### Options
- `--interval <seconds>` — Poll frequency (default: 2s)
- `--since-log-id <id>` — Start from a specific point instead of latest
- `--webhook <url>` — POST new messages to this URL

### One-Shot Status
```bash
kakaocli sync
```
Returns: `{"status":"ready","max_log_id":12345}` — useful for getting the current high-water mark.

## Agent Integration Pattern

Typical agent loop:

```python
import subprocess, json

# 1. Check for new messages
proc = subprocess.run(["kakaocli", "messages", "--since", "5m", "--json"],
                      capture_output=True, text=True)
messages = json.loads(proc.stdout)

# 2. Process and respond
for msg in messages:
    if not msg["is_from_me"] and needs_response(msg):
        subprocess.run(["kakaocli", "send", msg["chat_name"], response_text])
```

Or use sync mode for real-time:

```bash
kakaocli sync --follow | while read -r line; do
  echo "$line" | jq -r '.text' | process_message
done
```

## Harvest (Bulk Chat History)

The `harvest` command automates bulk extraction of chat display names and message history loading.

### Names Only (Fast)
```bash
kakaocli harvest
```
Captures display names for all chats from the UI (many group chats show `(unknown)` in the DB). Saves to `~/.kakaocli/metadata.json`.

### Full History Loading
```bash
kakaocli harvest --scroll --max-clicks 5
```
Opens each chat, scrolls to top, and clicks "View Previous Chats" to load older messages from the server. Automatically handles Talk Drive Plus paywall popups.

### Options
- `--top <N>` — Process only top N most recent chats
- `--scroll` — Enable full scroll + click mode (without this, only captures names)
- `--max-clicks <N>` — Max "View Previous Chats" clicks per chat (default: 10)
- `--scroll-delay <seconds>` — Delay between actions (default: 1.5s)
- `--dry-run` — Preview without making changes

### Output
Returns JSON array with per-chat results:
```json
[{"chatId": 123, "name": "Chat Name", "messagesBefore": 48, "messagesAfter": 148, "newMessages": 100, "skipped": false}]
```

### Notes
- Chats with unread messages are automatically skipped (to avoid marking them as read)
- The Talk Drive Plus paywall blocks loading older messages — the tool detects and dismisses it
- Uses Vision OCR + CGEvent clicks for reliable UI interaction
- Metadata saved to `~/.kakaocli/metadata.json`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Keychain error` | Run `kakaocli login --clear` then re-store credentials |
| `No login window found` | KakaoTalk window may be hidden — run `kakaocli login --status` to check |
| `Login did not succeed` | Verify credentials: `kakaocli login --email ... --password ...` |
| `Chat not found` | Use exact substring match — run `kakaocli chats` to see available names |
| `No open windows` | KakaoTalk may need manual interaction first time — open it once manually |
| Login works but send fails | Window may need time to load — retry after 2-3 seconds |

## Safety Rules

1. **Never send test messages to other people's chats.** Use `--me` flag for testing.
2. **Always use `--dry-run` first** when testing new send or leave logic.
3. **Rate limit sends** — at least 2 seconds between messages.
4. **Respect hours** — avoid sending between 11 PM and 7 AM unless urgent.
5. **Confirm before sending or leaving** — agents should verify message content or room names with the user before acting on other people's chats.
