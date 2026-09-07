# tg — skill reference

**Status: early implementation (v0.01).** This file will grow into the
full command/workflow reference as the skill is implemented (per TGIG-002
through TGIG-005). See `README.md` for the intended install/config/run
shape and `tickets/` for what's actually done vs. planned.

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
  offset), `get_file($file_id)`. Raw HTTP via `HTTP::Tiny`, no SDK. Not
  yet wired into `cli/poller`'s loop — that's the next ticket.
