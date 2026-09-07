# tg — operational policies

These are the behavioral rules this skill's code enforces, distinct from
the Tira board's own SDLC/delivery policies (see this project's board,
"D2 TG Skill", for those). They come from the owner's original design
brief for this skill.

## Access control: not everyone can talk to the bot

`D2TG_CHAT_ID` is auto-seeded as allowed on every start. Any other chat
id that messages the bot is silently recorded as **pending** — nothing
it sends reaches stdout — until an operator runs `d2 tg.approve
<chat_id>`. The first time a given pending chat id messages the bot, one
`NEW TG PENDING [chat_id] awaiting approval` line is printed so the
operator notices; repeat messages from the same still-pending sender do
not repeat the notification.

## A reply is always text + voice, never text-only

`d2 tg.reply` (via `D2TG::Reply::send_reply`) synthesizes the voice note
first, then sends the voice note, and only sends the text message once
the voice note has actually been delivered. If synthesis fails
(`gtts-cli` or `ffmpeg` unavailable or erroring) or the voice-note send
itself fails, the whole reply fails and the text message is never sent —
there is deliberately no fallback that degrades to a text-only reply. A
caller that wants to know a reply failed needs to see the failure, not a
silently incomplete answer on the other end.

## No log file — stdout/stderr only

`d2 tg.poller` writes its event stream to **stdout** and errors to
**stderr**; there is no `bot.log` or similar file. The intended
consumer is a Tira monitor-kind job, whose `tira.policy.bridge` output
already captures both streams — a separate log file would be a second,
divergent copy of the same information.

## No systemd, no cron

The poller is meant to be registered as a Tira monitor-kind job on the
project it serves, not started by systemd or cron. This keeps the
poller's lifecycle visible on the same board that tracks everything else
about the project, instead of in an OS-level service list nobody is
watching (Q-003).
