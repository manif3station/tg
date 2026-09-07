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
- `cli/poller` (dispatched as `d2 tg.poller`) — calls the Config guard and
  refuses to proceed if it fails. The actual Telegram long-poll loop is
  not implemented yet (see TGIG-002); this only proves the guard wiring.
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
  never reaches stdout. **Not yet implemented**: any command/workflow to
  approve a pending sender, non-text media, persisting the poll offset
  across restarts — separate tickets under TGIG-002.
