# tg — skill reference

**Status: early implementation (v0.01).** This file will grow into the
full command/workflow reference as the skill is implemented (per TGIG-002
through TGIG-005). See `README.md` for the intended install/config/run
shape; ticket-level status lives on the project's Tira board
("D2 TG Skill"), not as markdown files in `tickets/`.

## Implemented so far

- `D2TG::Config` (`lib/D2TG/Config.pm`) — reads `D2TG_TOKEN`/`D2TG_CHAT_ID`
  from the environment; `require_chat_id_or_warn()` is the startup guard
  that refuses to proceed (warning to STDERR) when `D2TG_CHAT_ID` is
  unset or empty.
- `cli/poller` (dispatched as `d2 tg.poller`) — calls the Config guard,
  then runs `D2TG::Poller`'s real long-poll loop against a `D2TG::Store`
  access-control gate until `SIGTERM`/`SIGINT`. See the `D2TG::Poller` and
  `D2TG::Store` entries below for what the loop actually does.
- `D2TG::Telegram` (`lib/D2TG/Telegram.pm`) — minimal Bot API client:
  `get_me`, `get_updates(offset, timeout)` (returns updates + next
  offset), `get_file($file_id)`. Raw HTTP via `HTTP::Tiny`, no SDK.
- `D2TG::Poller` (`lib/D2TG/Poller.pm`) — `run_once($telegram, $offset,
  $store)` does one `get_updates` call and prints one stdout line per
  inbound text message (`NEW TG [chat_id] sender: text`) from an
  allow-listed sender only. `cli/poller` runs this in a real loop
  (SIGTERM/SIGINT for clean shutdown) once the startup guard passes.
- `D2TG::Store` (`lib/D2TG/Store.pm`) — SQLite-backed (`state/store.sqlite`
  under the skill's install root) `allow_list`/`pending` tables.
  `D2TG_CHAT_ID` is auto-seeded as allowed on every start, no secret
  phrase needed. Anyone else's message is silently recorded pending and
  never reaches stdout. `approve($chat_id)` moves a chat id from
  `pending` to `allow_list` (idempotent - returns false, not an error,
  if the id wasn't actually pending).
- `cli/approve` (dispatched as `d2 tg.approve <chat_id>`) — the operator
  entrypoint for `D2TG::Store::approve`. Prints `Approved N` and exits 0
  on success; exits non-zero on failure with a message distinguishing
  "already allowed" (nothing to do) from "never pending" (never messaged
  the bot). **Not yet implemented**: any Telegram-side notification to
  the admin that someone is pending, non-text media — separate tickets
  under TGIG-002.
- `D2TG::Store::get_offset`/`set_offset` — the Telegram update offset is
  now persisted in the same SQLite file (`meta` table). `cli/poller`
  restores it at startup and saves it after every loop iteration, so a
  restart resumes exactly where it left off instead of losing its place.
- Pending-sender notification — `D2TG::Poller::run_once` now prints a
  `NEW TG PENDING [chat_id] awaiting approval` line the first time a
  non-allow-listed sender messages the bot (not on every subsequent
  message from the same still-pending sender), so the admin sees it on
  the same watched stream as everything else.
- Media recognition — a photo/document/voice message from an allow-listed
  sender now prints `NEW TG MEDIA [chat_id] sender: <type>` instead of
  being silently skipped. **Not yet implemented**: downloading the file,
  transcribing voice, or replying to media — separate tickets.
