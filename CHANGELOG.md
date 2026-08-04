# Changelog

### Unreleased
- Replaced name and substring sending with exact `chat_id` or self-chat destinations
- Added caller request IDs, durable idempotent receipts, and whole-transaction process locking
- Added fail-closed UI identity checks and exact per-chat database confirmation
- Removed foreground send mode, application activation, window raising, pointer movement, global input, positional Send-button guessing, and automatic room closing from the send path
- Added explicit `confirmed` and `unknown` outcomes; unknown results are never retried automatically
- Resolve self-chat window identity from the logged-in user's database name while proving the row by its unique self badge
- Reserve request IDs before the irreversible UI action so a process crash cannot become a duplicate retry
- Resolve every first-attempt destination freshly, reject database-wide duplicate UI identities, and require structural proof of the selected Chats tab
- Reject every already-open room and revalidate the selected row, exact window set, composer, focus, body, and Send-control state immediately before action
- Harden state and lock files against symlinks, wrong owners, and non-user permissions; give each confirmed chat/log row one durable request owner
- Reconcile stored `unknown` attempts read-only under the same request ID without repeating UI work
- Limit send bodies to 64 KiB and remove source-database keys from send-process arguments
- Return durable `unknown` for unclassified UI or confirmation failures after
  reservation, and fsync the receipt directory entry before reporting success

### v0.5.0 - Chat Harvest (Phase 4)
- `harvest` command: bulk-capture chat display names and load message history
- Vision framework OCR to locate "View Previous Chats" button
- CGEvent-based clicking for reliable UI interaction
- CGWindow API for paywall popup detection
- Auto-dismiss Talk Drive Plus paywall dialogs
- MetadataStore: persistent chatId → displayName at `~/.kakaocli/metadata.json`
- `query` command: raw read-only SQL queries against the decrypted database

### v0.4.1 - Robust Auto-Login
- Fix credential storage: switch from Security framework to `security` CLI
- Fix state detection: use status bar menu when AX window is not visible
- Fix login transition: non-aggressive polling avoids interfering with login flow

### v0.4.0 - App Lifecycle & Login (Phase 3.5)
- `login` command: store/check/clear credentials (macOS Keychain)
- AppLifecycle: auto-launch KakaoTalk, auto-login via AX automation
- `ensureReady()` called before all send operations

### v0.3.0 - Agent Integration (Phase 3)
- `sync` command with `--follow` for real-time NDJSON message streaming
- Webhook support: `--webhook <url>` POSTs new message batches
- AGENTS.md: AI agent integration instructions

### v0.2.0 - UI Automation (Phase 2)
- Send messages via macOS Accessibility API
- `send` command with chat name matching
- `--me` flag for self-chat (나와의 채팅) via badge detection
- `inspect` command to dump UI element tree

### v0.1.0 - Database Reader (Phase 1)
- SQLCipher database decryption (PBKDF2-SHA256, cipher_default_compatibility=3)
- Auto-detect device UUID, user ID, container path
- `auth`, `chats`, `messages`, `search`, `schema`, `status` commands
- JSON output for all read commands
