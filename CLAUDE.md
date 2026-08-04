# CLAUDE.md

Follow [AGENTS.md](AGENTS.md), especially its irreversible-send safety contract.

## Build

```bash
swift build
swift test
```

The package requires Homebrew SQLCipher and uses Swift Argument Parser.

## Safe sender architecture

- `SafeSendClient` owns idempotency, the in-process lock, the cross-process
  `flock`, fresh database identity resolution, database-wide UI-label
  uniqueness, the per-chat high-water mark, unique confirmed-log ownership,
  and exact post-send confirmation.
- `KakaoClient` is the public actor wrapper for reads and sends.
- `KakaoAutomator.submit` is the only send automation entry point. It operates
  on an already-rendered UI and must remain free of application activation,
  window raising, pointer movement, and global input.
- `BackgroundSendSelector` contains pure fail-closed selection rules and is
  covered by unit tests. The send path accepts only the structurally verified,
  selected Chats tab and never reuses an already-open room.
- `DatabaseReader.confirmedOutgoing` scopes confirmation to the intended
  `chat_id`, current user, log ID above the snapshot, and exact message bytes.

An automation error after the submit action becomes an `unknown` receipt.
Replaying the exact request ID may reconcile it from the database but must
never repeat UI work. Never add automatic retries for that result. Live tests
must target self-chat only.
