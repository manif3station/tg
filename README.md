# tg

**Status: early implementation (v0.97).** `d2 tg.send`'s outbound photo/
document uploads now escape and sanitize the local filename before
inserting it into the multipart request Telegram receives (TGT-125,
found via a scheduled bug-hunt) - a literal double-quote previously
corrupted the request, and a filename containing a literal CR/LF could
have injected an extra header line into it. `d2 tg.status`, `d2
tg.whoami`, and `d2 tg.send` now recognize `--db`/`-d` anywhere in
their arguments (TGT-124, found via a scheduled improvement hunt),
matching every other `d2 tg.*` command - `d2 tg.send <chat_id> <file>
--db myalias` previously refused with a bogus Usage error because
`--db` had to come before `chat_id`/`file_path`. New `d2 tg.tts [--out <path>]
<text...>` command (TGT-106, user-supplied feature-gap analysis)
synthesizes text to a local audio file with no Telegram interaction at
all - the underlying `D2TG::TTS::synthesize` was previously only
reachable from inside `d2 tg.reply`. Useful for anything needing a
spoken audio file on its own, e.g. attaching a voice note to a
`tira.question.ask` card question. SKILLS.md's `cli/*.pl` file
list is now current (TGT-123, found via a scheduled doc-accuracy hunt) -
5 entrypoints added by later tickets (`send.pl`, `status.pl`,
`retry-download.pl`, `text-only-replies.pl`, `whoami.pl`) were missing
from it. `d2 tg.poller`'s version-bump
restart notice now names what actually changed, not just the version
numbers (TGT-112, user-supplied live-experienced feedback) - it appends
the new version's own first `Changes` bullet line, read from the
installed `Changes` file at restart time. Test-only refactor (TGT-121,
found via a scheduled improvement hunt): a shared
`t/lib/Fake/ReplyTelegram.pm` test double now replaces 6
independently-reinvented copies of the same outbound test fake across 5
test files - no user-facing behavior change. `d2 tg.history` now refuses
with a Usage message and exit 2 if any unrecognized flag or leftover
positional argument remains after `--since`/`--until` parsing (TGT-122,
found via a scheduled bug-hunt) - previously silently ignored, exiting
0 as if the invocation had succeeded (with output ranging from "No
messages found." to actually matching, unrelated history).
`cli/poller.pl`'s `--help`
usage text and its own POD SYNOPSIS - two independently hand-maintained
copies of the same flag list - now have a test enforcing they stay
consistent (TGT-119, found via a scheduled improvement hunt); it caught
a real drift immediately (`-h` was missing from the SYNOPSIS), now
fixed. `D2TG::Poller::run_once`'s
fallback media branch (a photo/document/voice message whose applicable
callback - `download_media` for photo/document, `transcribe_voice` for
voice - was not given) now records the message in the store too,
matching every other successful branch (TGT-120, found via a scheduled
bug-hunt) - not exercised by `cli/poller.pl`, which always supplies
both callbacks, but a genuine gap closed in `run_once`'s own
general-purpose contract.
`d2 tg.poller` now opens its
`STDOUT`/`STDERR` with an explicit UTF-8 encoding layer (TGT-117, a
live-experienced incident: a real inbound Cantonese voice-note
transcript triggered a repeated "Wide character in print" warning) -
never a functional failure (the message still printed and was still
processed correctly), just log noise on every non-Latin-1 message,
eliminated now for every print/warn path in the poller. New `d2 tg.whoami` (TGT-115,
user-supplied feature-gap analysis) reports which token/chat/storage a
given shell's env vars actually resolve to - the masked token, the
configured chat_id, and the resolved storage/attachments location - no
HTTP request at all, safe to run at any time including with a
completely unconfigured token. Useful when several projects on one host
each run their own installed copy of this skill and it's not obvious
which one a given terminal is actually pointed at. `d2 tg.reply` now refuses to
send the exact same text to the same chat (and bot) twice within a
short window (TGT-114, default 10s) - an accidentally re-run reply
command, or a retry after a confirmed prior success whose voice half
then failed, no longer delivers the message a second time. Only applies
when a store is given (unchanged behavior otherwise); doesn't protect
against retrying after an ambiguous send failure (one where Telegram's
own response never confirmed success or failure) - only a confirmed
prior success is ever checked against. A Codex review caught that the
underlying schema change needed the same upgrade-safe migration pattern
this project already uses elsewhere (a bare `CREATE TABLE IF NOT
EXISTS` is a no-op against a database that already has the table from
an earlier install), now fixed. A reply that went out
text-only (TGT-083's own send-text-then-voice ordering means a late
voice failure can leave one behind, always reported loudly at the time
but easy to miss if that failure scrolled past) is now flagged for
after-the-fact discovery too (TGT-105, user-supplied feature-gap
analysis) - `d2 tg.text-only-replies` lists any reply still missing its
voice half, exit 1 if anything's flagged. Scoped per configured bot the
same way access control already is (a Codex review finding, mirroring
TGT-098's own lesson): `d2 tg.reply --voice-only`'s recovery lookup
can't select and clear a different bot's own flag for a chat shared
across bots. A failed inbound photo/
document download is now queued for retry instead of just printed and
forgotten (TGT-104, user-supplied feature-gap analysis) - `d2
tg.retry-download` lists it and retries by id or `--all` using the
saved Telegram `file_id` to request a fresh download; a successful
retry restores the message into `d2 tg.history`/`d2 tg.unread` the same
way a first-time success does, not just deleting the queue row. A
retry Telegram itself reports as permanently gone - "file is no longer
available"/"wrong file_id", not merely a transient hiccup - gets a
distinguishable `RETRY EXPIRED` message; a Codex review caught an
earlier draft also treating "file is temporarily unavailable" as
permanent, when that wording describes a real transient condition that
can still succeed later, and (per a web search of Telegram's own Bot
API docs during that review) that a `file_id` itself doesn't expire on
a short fixed clock the way an earlier draft of this project's own docs
claimed - it's the one-hour-valid `file_path` a `getFile` call resolves
it to that's short-lived, and a fresh `getFile` call (which every retry
already makes) gets a fresh one. The same review caught the queue
itself needed a `(chat_id, message_id)` uniqueness constraint, since
Telegram's at-least-once delivery could otherwise insert a duplicate row
for the same failed media on redelivery, and that queuing a failure is
only ever attempted (a database-write failure there is itself
non-fatal, matching the download failure it's recording), not
guaranteed.
`d2 tg.poller` now warns on
stderr if it detects another live process whose command line looks like
a poller instance, right after acquiring its own lock (TGT-113, a
live-experienced incident: a poller crashed mid-restart and left an
orphaned second instance under a different PID still running,
undetected, competing for the same bot token's `getUpdates` queue -
TGT-084's own "last one wins" lock-eviction never sees this shape, since
it only ever looks at whichever single PID the lock FILE currently
names). This is a report, not a kill - a `/proc` cmdline pattern match
alone isn't strong enough evidence to justify an unprompted kill, so
`D2TG::Lock::find_other_pollers` only ever warns; a Codex review caught
that its first draft matched an unanchored substring against a
NUL-joined cmdline (false-positiving on names like `not-a-poller.pl`),
fixed by matching each argv element individually against an anchored
pattern. `d2 tg.poller` also writes a
heartbeat after each bot/chat pair's own poll cycle, atomically (temp
file + rename), and `d2 tg.status` reports its age, flagging it stale
past 20 minutes (TGT-116, a live-experienced incident: a poller stayed
alive and held its lock for 80+ minutes while doing nothing at all,
silently losing a message - "alive" and "still genuinely cycling" turned
out to be different questions). The 20-minute threshold and per-pair
write both came from a Codex review catching that a once-per-full-cycle
heartbeat against a tighter threshold could falsely flag a healthy,
actively-transcribing poller as stale. Automatic restart-on-stale is
intentionally not built yet - that needs an external actor, an
operational decision flagged as a follow-up. `d2 tg.status` also reports the
installed version and whether the poller is currently alive (TGT-111,
user-supplied feature-gap analysis), without reaching into Tira job
metadata from outside - read-only, never calls the lock's own `acquire`
(which could evict a live poller just to answer a status question).
`d2 tg.send <chat_id>
<file_path>` pushes a local file to a chat as a Telegram photo or
document (TGT-103, user-supplied feature-gap analysis) - the outbound
counterpart to inbound media, which already worked fully. `d2 tg.reply --voice-only
<chat_id> <text...>` resends just the voice half of a reply whose text
already went out but whose voice synthesis/send then failed (TGT-109, a
live-experienced incident) - never calling `send_message`, so it can't
duplicate the already-delivered text. `d2 tg.poller` now validates
its own arguments fully before ever touching its lock file - `--help`/
`-h` prints usage and exits, and any other unrecognized flag refuses
with a clear error naming it (TGT-107, a live-experienced incident: a
`--help` typo used to be silently accepted and start a real second
poller, which this skill's own "last one wins" lock (TGT-084) then let
`SIGKILL` the legitimate one already running). The multi-bot allow-list is
now scoped per bot (`chat_id`, `bot_key`) rather than by `chat_id`
alone - a Telegram group shared by more than one of this skill's
configured bots no longer leaks an approval from one bot to another
(TGT-098, found via a scheduled bug-hunt investigating multi-bot
interactions). `cli/approve` gains an optional `--bot <token>` flag,
matching `cli/reply`'s own; omitting it behaves exactly as before for
every single-bot install. Inbound voice-note
transcription now automatically retries at a faster Whisper model when
the current one times out (`medium` → `small` → `base`), instead of
failing outright - per-host Whisper throughput varies too much for a
duration-based guess alone to guarantee correctness (a 102-second clip
measured at 9m31s on one host, ~5.6x real time with no GPU), so
retry-on-timeout is what actually keeps transcription from being lost;
duration-based tiering (TGT-100) still picks a sensible starting model.
A voice note also gets an immediate "transcribing..." notice on stdout
before the blocking transcription starts, so a multi-minute wait isn't
silent. `d2 tg.poller` no longer
prints a `POLL ERROR` line for a known-transient failure (a network
timeout or a 5xx status) - it keeps retrying silently, since these are
routine and self-heal on their own; a genuinely unexpected failure is
still reported (TGT-097, live user request). `d2 tg.reply`'s error output
now tells the calling agent to retry when a send fails with a
transient-shaped error (a network timeout or a 5xx status) - a
permanent failure (bad token, invalid chat_id) is reported as before,
with no misleading retry suggestion (TGT-096, live user request). The
poller's own version-change
self-restart no longer briefly drops and recreates its own lock file
either (TGT-102, found via a scheduled bug-hunt): re-acquiring a lock
already held by its own PID - exactly what that self-restart produces,
since `exec()` keeps the same PID - now succeeds immediately instead of
falling through into the fallback reclaim path, closing a narrow
window where a second poller could otherwise `SIGKILL` the legitimately
restarting one. Also (TGT-036) no longer trusts a stale `$0` - live production
incident, TGT-094: a running poller mid-restart during TGT-093's own
install died because `$0` pointed at the just-renamed-away `cli/poller`
path. It now re-checks its own bin directory for the current
`poller.pl` at restart time, falling back to `$0` only if that lookup
fails - so a poller survives an install that renames its own entrypoint
out from under it. Every `cli/*` entrypoint now
carries a `.pl` extension (`cli/poller.pl`, `cli/reply.pl`, etc. — TGT-093);
`d2 tg.<command>` dispatch is unaffected, since Developer Dashboard's
`SkillDispatcher` already tries a `.pl` fallback for an extensionless
command name. `d2 tg.poller` runs for real —
it long-polls Telegram, gates inbound senders against an allow-list (only
`D2TG_CHAT_ID` is allowed by default; anyone else is silently recorded
pending — and prints a one-time notification when they do), and prints
allowed text messages (and now recognizes photo/document/voice by name)
to stdout. `d2 tg.approve <chat_id>` moves a pending sender into the
allow-list. The poll offset persists across restarts. Only one `d2
tg.poller` process may hold the lock for a given storage location at a
time; starting a new one takes over from ("kills") a still-live previous
instance rather than refusing (TGT-084 - "last one wins"). `d2 tg.reply
<chat_id> <text>` sends a reply as BOTH a text message and a gTTS voice
note — text is sent first, then the voice note is synthesized and sent
(TGT-083); a synthesis or send failure after that point is still
reported loudly but can no longer un-send the text. An allow-listed
sender's voice message is downloaded and transcribed via a local
Whisper install, printed to stdout as its text; a photo/document message
is downloaded to a local file and its path printed, along with any
caption the sender attached (TGT-092). Either kind of
download/transcription failure is reported on stderr without stopping
the poller. Every content line also carries a ready-to-run `REPLY WITH:
d2 tg.reply <chat_id> "..."` template (per Q-004) — the poller never
sends a reply itself, this just makes composing one fast. Run `d2
tg.help` (TGT-089) any time for both of these in one place - it prints
`SKILLS.md` then `docs/commands.md`, no config required. See `SKILLS.md`
for what's implemented so far, `docs/commands.md` for the command
reference, and this project's Tira board ("D2 TG Skill") for
ticket-level status.

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
- `D2TG_DB` — a Developer Dashboard path alias (run `d2 paths` to see the
  choices) naming where the skill's SQLite state and downloaded
  attachments live. **Required** (TGT-059) — every `d2 tg.*` command
  refuses to start and prints a warning if neither this nor `--db
  <alias>`/`-d <alias>` is given. Its resolved directory (or a
  `TIRA_HOME` fallback) must already exist — it's looked up, never
  created (TGT-090).

## Running

```
d2 tg.poller
```

The poller is meant to be registered as a Tira monitor-kind job on the
project it serves, not run under systemd or cron — new messages then
reach that project's `tira.policy.bridge` as monitor-output events. On
the project's board:

```
d2 tira.policy.add --rule monitor-output --action bridge-reminder   # once, if not already declared
d2 tira.job.add --schedule monitor --command "d2 tg.poller"
d2 tira.job.start --id JOB-NNN   # the id tira.job.add just printed
```

Verified (TGT-015) in a `developer-dashboard:latest` container: with the
`tg` skill installed and a scratch Tira project, this registers and
starts `d2 tg.poller` as a monitor job, and its own output — including
the real startup-guard warning when `D2TG_CHAT_ID` is unset — reaches
that project's `tira.policy.bridge` as a `monitor-output` event, with no
systemd or cron involved.

To reply to a chat (text + voice note together, always):

```
d2 tg.reply <chat_id> <text...>
```

The text message is sent first, then the voice note is synthesized and
sent (TGT-083) — so if voice synthesis or sending fails, the failure is
still reported loudly (non-zero exit), but the text half has already
reached the chat; Telegram messages can't be unsent. This shells out to
`gtts-cli` and `ffmpeg` to synthesize the voice note — both must be
installed on the machine running this. Voice-note transcription
similarly requires a local `whisper` install with a multilingual (non
`.en`) model. See `docs/commands.md` for the full command reference and
`docs/POLICIES.md` for the operational rules (access control, the
always-voice-with-text rule, etc.) this skill follows.
