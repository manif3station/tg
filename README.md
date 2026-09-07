# tg

**Status: early implementation (v0.01).** `d2 tg.poller` runs for real —
it long-polls Telegram, gates inbound senders against an allow-list (only
`D2TG_CHAT_ID` is allowed by default; anyone else is silently recorded
pending), and prints allowed text messages to stdout. `d2 tg.approve
<chat_id>` moves a pending sender into the allow-list. Still missing: any
Telegram-side notification that someone is pending, media handling,
reply/voice output, and persisting the poll offset across restarts. See
`SKILLS.md` for what's implemented so far and this project's Tira board
("D2 TG Skill") for ticket-level status.

Telegram bridge skill for Developer Dashboard. Lets an admin reach a
project's live agent session over Telegram, and be reached by it — text,
photos, documents, and voice notes in both directions.

## Install

```
dashboard skills install tg
```

## Configuration

Set these environment variables before starting the poller:

- `D2TG_TOKEN` — the Telegram bot token (from @BotFather).
- `D2TG_CHAT_ID` — the admin/owner's Telegram chat id. **Required** — the
  poller refuses to start and prints a warning if this is not set.

## Running

```
d2 tg.poller
```

The poller is meant to be registered as a Tira monitor-kind job on the
project it serves (`tira.job.add --schedule monitor --command "d2
tg.poller"`), not run under systemd or cron — new messages then reach that
project's `tira.policy.bridge` as monitor-output events.
