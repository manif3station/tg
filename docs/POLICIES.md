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

## A reply-to-message carries its own context on the way in

When a sender replies to a specific earlier Telegram message (TGT-029,
live usability report), the poller's `NEW TG`/`NEW TG VOICE`/`NEW TG
MEDIA` line names what that reply targets - the original sender and a
snippet of the original text (or its media kind) - so the monitoring
agent never has to cross-reference an earlier line to know which
message in the conversation a reply responds to.

## CLI commands validate chat_id locally before any network call

Both `d2 tg.approve` and `d2 tg.reply` reject a non-numeric `chat_id`
argument immediately (exit 2, `Usage` message on STDERR) rather than
letting it reach the Telegram API and fail there (TGT-027) - a mistyped
or missing chat id should read as a clear local usage error, not an
opaque remote failure.

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

## Outbound TTS failure is fatal; inbound transcription failure is not

`d2 tg.reply`'s synthesis/send failure is deliberately fatal (see above)
- a reply the operator can't verify happened should not silently
partially happen. Inbound voice transcription is the opposite: a single
voice note that fails to download or transcribe must not take down the
whole poller loop, since a live bridge processing many messages should
keep serving the rest of them. `cli/poller` reports such a failure on
stderr (`TRANSCRIBE ERROR [chat_id] sender: <message>`) and continues.

## A single transcription can never block shutdown, or run unbounded

Voice transcription shells out to `whisper`, which can be slow (TGT-031,
a real production incident: it was found genuinely blocking the whole
poll loop, and `cli/poller` was unresponsive to Ctrl+C for as long as
it ran). `D2TG::Transcribe::_run` is bounded by `$TIMEOUT` (default
300s) - a run that exceeds it is killed and reported as a normal
`TRANSCRIBE ERROR`, never blocks forever. `cli/poller`'s `SIGTERM`/
`SIGINT` handlers also call `D2TG::Transcribe::kill_current` so an
in-flight transcription is killed immediately at shutdown time rather
than waited out.

## A transcription's own console output never reaches the watched stream

`whisper` prints its own chatter (warnings, language-detection lines,
per-segment transcript output) to its own stdout/stderr by default.
Confirmed live (TGT-030, Michael sent a voice message): this was
inherited straight onto the poller's real stdout, polluting the exact
stream a Tira monitor job's feeder reads. `D2TG::Transcribe::_run`'s
forked child now reopens its own stdout/stderr onto `/dev/null` before
exec, so only this project's own structured lines (`NEW TG VOICE`,
`TRANSCRIBE ERROR`, etc.) ever reach the real stream.

## The poll loop itself survives transient failures

Beyond individual voice/media failures (above), the poll cycle itself
(`get_updates`) can fail transiently - a network blip, a momentary
Telegram-side error. `run_once_safe` (TGT-028, a real production
incident: an uncaught transient failure once silently killed the whole
poller) catches this, logs `POLL ERROR: <message>` to stderr, waits a
short backoff, and retries - the poller process itself must never die
from a failure that will very likely resolve on its own.

## No systemd, no cron

The poller is meant to be registered as a Tira monitor-kind job on the
project it serves, not started by systemd or cron. This keeps the
poller's lifecycle visible on the same board that tracks everything else
about the project, instead of in an OS-level service list nobody is
watching (Q-003).
