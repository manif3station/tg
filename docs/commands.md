# tg — command reference

All commands are dispatched via Developer Dashboard as `d2 tg.<name>`
(the `cli/<name>` script in this repo).

## `d2 tg.help`

Prints `SKILLS.md` (the onboarding runbook) in full, then a divider,
then this file (`docs/commands.md`, the full command reference) in
full - so an agent unfamiliar with this skill can self-serve
documentation without needing to know the skill's own install path on
disk (TGT-089, a live user request). Takes no arguments, requires no
environment variables at all - it touches no state, network, or
credentials, only two static files that ship with the skill.

## `d2 tg.poller [--db <alias> | -d <alias>] [--chat_id <id> --bot <token> ...] [--help]`

At startup - before option handling and any poller work, though after
Perl compiles the modules it loads - `STDOUT`/`STDERR` are opened with an explicit
`:encoding(UTF-8)` layer (TGT-117, a live-experienced incident: a real
inbound Cantonese voice-note transcript triggered a repeated "Wide
character in print" warning at `D2TG::Poller.pm` line 83). Never fatal -
the message was still processed and delivered correctly either way -
but this eliminates the noise for every non-Latin-1 message going
forward, on both streams (so `--help`'s own usage text, and every
`POLL ERROR`/`MEDIA DOWNLOAD ERROR` line on stderr, are also covered).

`--help`/`-h` (TGT-107, a live-experienced incident) prints a short
usage summary and exits 0 - checked before anything else, including
before `--db`/`-d` is parsed. Any OTHER unrecognized argument refuses
(STDERR names the specific token, exit 1) before the storage
location/lock are ever touched - previously, an unrecognized flag
(including `--help` itself) was silently accepted and the process fell
through into a real poll loop, which, per this skill's own "last one
wins" lock (TGT-084), could `SIGKILL` a live, legitimate poller by
typo. Every previously-recognized flag below is unchanged.

The `--help` usage text above and this script's own POD `SYNOPSIS` are
two independently hand-maintained copies of the same flag list, with a
test (`t/88-poller-help-pod-parity.t`) now enforcing they name the same
flags (TGT-119, found via a scheduled improvement hunt reviewing
TGT-107) - it caught a real drift immediately (`-h` was missing from
the `SYNOPSIS`), now fixed. The same drift class was found twice more
in other `cli/*.pl` scripts (`reply.pl`, TGT-157; `approve.pl`, TGT-159)
before a systematic sweep (TGT-163) added the identical parity test to
the remaining 9 scripts that had none - `attachment.pl`, `history.pl`,
`retry-download.pl`, `send.pl`, `status.pl`, `text-only-replies.pl`,
`tts.pl`, `unread.pl`, `whoami.pl` - and caught one more real drift in
the process: `history.pl`'s own `SYNOPSIS` never showed its `-d`
shorthand, now added.

Immediately after acquiring its own lock, warns on STDERR if it detects
another live process whose command line looks like a poller instance
(TGT-113, a live-experienced incident: a poller crashed mid-restart and
left an orphaned second instance under a different PID still running,
never having touched this instance's own lock file, silently competing
for the same bot token's `getUpdates` queue - TGT-084's own lock-eviction
only ever sees whichever single PID the lock FILE currently names, not
every process actually polling). This is a report only, never a kill -
see `D2TG::Lock::find_other_pollers` below. Since TGT-141 (an external
review finding live-reproduced by a sibling project and confirmed by
Michael), the flagged process's own bot token is cross-checked against
this instance's: a same-token match keeps the urgent `WARNING` wording,
an unreadable/unknown token gets its own more cautious `WARNING`, and a
confirmed-different token (TGT-250, live Telegram request from Michael,
2026-09-15) prints nothing at all now - previously every poller-shaped
process was warned about identically, which fired routinely and
alarmingly for the single most common, entirely benign case on a host
running several projects from this skill; TGT-141 first split the
confirmed-different case into its own reassuring `NOTE`, and TGT-250
silenced that `NOTE` entirely once it turned out to be noise with no
action ever attached.

`--db <alias>`/`-d <alias>` (TGT-051, or `D2TG_DB=<alias>` as a
fallback) relocates both the SQLite state file and downloaded
attachments under that Developer Dashboard path alias's directory -
specifically under a `.tira/` subdirectory of it (TGT-081, a live user
request): the state file is `.tira/telegram.messages.db` and
attachments live under `.tira/attachments/`. **Mandatory** (TGT-059,
with a TGT-081 fallback): every `d2 tg.*` command refuses to start
(exit 1, clear STDERR message pointing at `d2 paths`) when neither this
flag nor `D2TG_DB` is given at all AND `TIRA_HOME` isn't set either -
when `TIRA_HOME` *is* set, it's resolved the same way an explicit alias
is (TGT-091, a live production incident): looked up against `d2 paths`
first (e.g. `TIRA_HOME=tira-zen` resolves to whatever `tira-zen` names
in `d2 paths`), falling back to using the value directly as a filesystem
path only if it doesn't match any registered alias.
The same refusal happens when an alias *is* given but isn't a known
one - `TIRA_HOME` is never consulted once an alias was given. As of
TGT-090 (a live user request + live reproduction), the resolved base
directory - whether a `--db`/`-d`/`D2TG_DB` alias's real path or a
`TIRA_HOME` fallback - is also refused if it does not already exist on
disk: every `d2 tg.*` command purely *resolves* the value to a location
and uses it, it never creates that location itself. Before this fix, a
bogus or typo'd `TIRA_HOME` (or an alias whose target directory had
never been created) was silently `mkdir -p`'d into existence, including
the state DB and attachment vault beneath it - reproduced live with
`TIRA_HOME=foobar` creating `./foobar/.tira/telegram.messages.db` under
whatever the current working directory happened to be. The `.tira/`
subdirectory *under* an already-real base directory is still created as
normal (that's this skill's own controlled state folder, not the bug).
See the Environment variables section below. `--db`/`-d`'s own
value is validated (TGT-071): a bare trailing `--db`, or one immediately
followed by another flag (e.g. `--db --chat_id`), exits 1 with a clear
`--db/-d requires a value` message instead of silently swallowing that
flag's own name as the alias and later failing with a misleading
`Unknown --db/-d alias '--chat_id'`. This applies to every `d2 tg.*`
command that takes `--db`/`-d` (`poller`, `approve`, `unread`, `history`,
and `reply`'s own separate leading-position extraction).

`--chat_id <id>`/`--bot <token>` (TGT-049, both repeatable) declare one
or more bot/chat groups: each `--chat_id` starts a new group, and every
`--bot` that follows attaches to it - e.g. `--chat_id 1234 --bot t1
--bot t2 --chat_id 4567 --bot t3` polls bots `t1`/`t2` under chat
`1234`'s allow-list and `t3` under `4567`'s, all from one process,
sequentially, round-robin, once per poll cycle (never one process per
bot). `D2TG_CHAT_ID`/`D2TG_TOKEN` are not a separate fallback code
path - they fold into the exact same grouping algorithm as an implicit
trailing pair (see `D2TG::Config::Flags::bot_groups`'s own POD for the full
merge rule), which is what makes the plain env-var-only case (no
`--chat_id`/`--bot` given at all) byte-identical to this skill's
original single-bot behavior, with no migration step for an existing
install. Refuses to start if no group ends up with at least one bot
token, and (TGT-069) if any `--chat_id` has no usable value following it
- a bare trailing `--chat_id` now fails with a clear message instead of
an opaque database error.

Starts the long-poll loop. Refuses to start (warning to STDERR, exit 1)
if `D2TG_CHAT_ID` is not set AND no `--chat_id` was given on the command
line at all (a CLI-declared group supplies its own chat id
independently of the env var). Also refuses (TGT-164, found via a
scheduled bug hunt) if `D2TG_CHAT_ID` is non-empty but malformed - even when
a `--chat_id` group was also given on the command line: before this
fix, that case skipped the canonical-shape check (TGT-155) entirely,
and `D2TG::Config::Flags::bot_groups` still silently folded the malformed
value in as an extra, broken poll group instead of refusing. A merely
*unset* `D2TG_CHAT_ID` alongside CLI-declared groups is unaffected -
nothing is folded in for that case, so there is nothing to validate.
Also acquires an exclusive lock
(`.tira/telegram.pid` under the resolved `--db`/`-d`/`D2TG_DB` storage
location, TGT-062; nested under `.tira/` as of TGT-087, matching
TGT-081's own nesting of the vault's other files - was a flat
`poller.pid` directly under the storage location before that) before
doing anything else. As of TGT-084 (a live user request
and a live production incident), starting a new `d2 tg.poller` no longer
refuses when another instance already holds that lock and is still
alive - it kills that instance (`SIGKILL`) and takes over: "last one
wins." A lock left by an unclean death (e.g. `kill -9`, a crash, or a
takeover this command itself just performed) is reclaimed automatically.
See `docs/POLICIES.md`'s "Only one poller may ever hold the lock, and the
last one to try wins" section for the full incident history and
rationale. On startup, prints `d2tg poller starting
up (token: <first 4>...<last 4>) (chat_id: <chat_id>)` (TGT-045) for the
single-group/single-bot case (the token is masked, the chat_id - not a
secret - is shown in full), or a multi-line group listing otherwise.
Runs until `SIGTERM`/`SIGINT`. Prints one line per event to **stdout**
(`NEW TG ...`), one line per error to **stderr** — no log file. Meant to
run as a Tira monitor-kind job, not under systemd or cron.

After every poll cycle, the attachment vault is pruned to a 100MB cap
(TGT-052) - oldest files deleted first once exceeded.

`D2TG::Poller::run_once`'s fallback media branch (fires for a photo/
document/voice message when no `download_media`/`transcribe_voice`
callback was given) now records the message in the store too, matching
every other successful branch (TGT-120, found via a scheduled
bug-hunt) - previously it printed the `NEW TG MEDIA` line but never
called `record_message`, making that message invisible to `d2
tg.history`/`d2 tg.unread` afterward. Not exercised by this command
itself, which always passes both callbacks unconditionally - the gap
only mattered to a caller that legitimately omits one.

Self-refreshes on a new install (TGT-036): after each poll cycle, it
compares its own on-disk `VERSION` against the one it started with. If
`dashboard skills install tg` has installed a newer version in the
meantime, it prints a notice and re-execs itself in place (same PID) -
no manual restart needed to pick up a new release. The notice now
appends the new version's own first `Changes` bullet line (TGT-112,
user-supplied live-experienced feedback) - e.g. `... restarting... -
cli/poller.pl now refuses on any unrecognized flag` - so an operator
watching the log doesn't have to go look up `Changes` separately to
find out what actually changed. Reads `Changes` at restart time via
`D2TG::Config::changes_summary`; omitted entirely if that version has
no `Changes` entry or the file can't be read. TGT-187 investigated a
live report that this omission happened unexpectedly on a real
installed poller - confirmed live (both in a `developer-dashboard:latest`
container and on this host's own real installed poller) that the
mechanism works correctly via a real `d2 tg.poller` dispatch when
`.env`'s `VERSION` and the `Changes` header are in sync; not
reproducible against the current codebase for the original report's
own specific incident (many versions behind). `changes_summary` used
to silently omit with no diagnostic whenever no entry could be matched
for the requested version (including a wrong version, or a header
whose version matched but whose own shape was malformed) - not
independently confirmed as the original TGT-187 incident's actual
cause, but a real, separate fragility, fixed as **TGT-190**: this
branch now prints a non-fatal STDERR diagnostic naming the requested
version and, if the file has one, a recognizable header found
elsewhere in it - or says explicitly that none was found, if it
doesn't (two Codex QA-stage review rounds: the diagnostic searches
for the first strictly-shaped header anywhere in the file, which can
skip a malformed earlier one - not necessarily "the" file's own
literal top header; and a file with no strictly-shaped header at all
names none, rather than always naming one), before returning `undef`
unchanged (the return value itself is not affected). A genuinely missing/unreadable
`Changes` file still returns `undef` silently, with no diagnostic -
only a readable file with no matching entry is covered.

Events printed:

Every **stdout** event line below (`NEW TG`/`NEW TG VOICE`/`NEW TG
MEDIA`/`NEW TG PENDING`) is prefixed with `[YYYY-MM-DD HH:MM:SS]`
(TGT-061), sourced from Telegram's own `message.date` field rather than
local wall-clock time - so the printed timestamp always reflects when
Telegram itself received the message, even if this poller processed it
a poll cycle or more later. The two **stderr** error lines below
(`TRANSCRIBE ERROR`, `MEDIA DOWNLOAD ERROR`) are NOT timestamped
(TGT-065) - the timestamp is sourced from the inbound message being
reported on, and these lines report a failure to process it, not
content from it.

- `NEW TG [chat_id] sender (msg #N)` — an allowed sender's text
  message. TGT-311 (explicit user-requested architecture change): the
  message's own text is never printed inline here anymore - only the
  announce line, immediately followed by a `FETCH WITH: d2 tg.fetch
  <chat_id> <message_id>` line (see `d2 tg.fetch`, below), which is
  what actually shows the content, and marks it read as a side effect
  of doing so. `(msg #N)` (TGT-040) is always present, so it can also
  be passed to `d2 tg.reply --reply-to-message-id N` for a genuine
  Telegram-native threaded reply. If this message is itself a reply to
  an earlier one, a ` (replying to <sender> [msg #M]: <content>)`
  suffix still appears on this same announce line (unaffected by
  TGT-311 - it names a *different*, already-existing message's own
  context, not this message's own content). TGT-312 (a TGT-311
  regression fix): in the rare/malformed case where Telegram's own
  payload omits `message_id` entirely (real Bot API traffic always
  sets it, but a defensive payload shape can lack it), there is no id
  to build a `FETCH WITH`/store-write around at all - the poller falls
  back to printing the message's own content inline on this announce
  line instead, exactly like every `NEW TG` line did before TGT-311,
  so the content is never silently and permanently lost. This fallback
  is the only case where content still appears inline after TGT-311.
- `NEW TG MEDIA [chat_id] sender: <photo|document> [- caption: <text>]` —
  an allowed sender's photo/document message, downloaded to a local,
  content-addressed path (TGT-051, named by the file's own SHA256 hash)
  under `D2TG::Config::attachments_dir` - identical content downloaded
  any number of times, from any sender, only ever occupies one copy of
  disk space. That real path is never printed (TGT-133, live Telegram
  request) - a `GET ATTACHMENT WITH: d2 tg.attachment <chat_id>
  <message_id>` line follows immediately, naming the command that
  actually fetches the bytes (see `d2 tg.attachment`, below). For a
  photo, the largest available resolution is downloaded. If the sender
  attached a caption to the photo/document (TGT-092, a live production
  incident: a caption was silently dropped before this fix, causing a
  real miscommunication), it's appended as `- caption: <text>`,
  sanitized the same way inbound text is (TGT-039); omitted entirely
  when there is no caption, which is the common case.
- `NEW TG VOICE [chat_id] sender (msg #N)` — an allowed sender's voice
  message, downloaded and transcribed via a local Whisper install (the
  downloaded audio itself is not kept, only its transcript). TGT-311:
  the transcript itself is never printed inline here either anymore -
  only the announce line, immediately followed by its own `FETCH WITH:
  d2 tg.fetch <chat_id> <message_id>` line, unless `message_id` is
  missing entirely, in which case TGT-312's same fallback applies and
  the transcript is printed inline instead. The stored transcript
  (sanitized the same way inbound text is, TGT-039: any newline
  whisper's own multi-segment output may contain becomes a literal
  `\n`) is what `d2 tg.fetch` prints, always as exactly one stdout line
  even for a transcript spanning multiple sentences/segments.
- `TRANSCRIBE ERROR [chat_id] sender: <message>` (stderr) — a voice
  message's download or transcription failed; the poller keeps running.
- `MEDIA DOWNLOAD ERROR [chat_id] sender: <message>` (stderr) — a
  photo/document message's download failed; the poller keeps running.
  If the file's declared size is over Telegram's Bot API `getFile` limit
  (20MB, TGT-037), this is reported specifically — `file too large to
  download (<N>MB, Telegram's Bot API getFile limit is 20MB)` — instead
  of an opaque `HTTP request failed (status 400 Bad Request)`, and the
  download is never attempted at all.
- `NEW TG PENDING [chat_id] awaiting approval` — printed once, the first
  time a non-allow-listed chat id sends anything.
- `FETCH WITH: d2 tg.fetch <chat_id> <message_id>` (TGT-311, explicit
  user-requested architecture change) — printed immediately after a
  text or successfully-transcribed-voice announce line only (never
  after `NEW TG MEDIA`, which already has its own `GET ATTACHMENT
  WITH` line and isn't in this ticket's scope; never after `PENDING` or
  an error line): a ready-to-run command that shows the message's own
  stored content and marks it read as a side effect - see `d2 tg.fetch`,
  below. TGT-312: also never printed when `message_id` is missing from
  the update entirely - there is no id to build the command around, so
  the content-inline fallback (above) applies instead.
- `REPLY WITH: d2 tg.reply <chat_id> "..." [--bot <token>] --reply-to-message-id <id>` —
  printed immediately after every content line above (text/voice-
  transcript/media, never after the pending notification or an error
  line): a ready-to-run reply command template with the chat id and,
  since TGT-040, the message's own `message_id` already filled in, per
  Q-004. This is only ever a template — the poller never sends a reply
  itself. In multi-bot mode (TGT-049, more than one `--chat_id`/`--bot`
  group configured) the template also names which bot received the
  message via `--bot <masked_token>` (TGT-057) - **masked** as of
  TGT-086 (first 4...last 4 characters, the same form
  `D2TG::Config::masked_token` already uses for the poller's own startup
  line, TGT-045): this line reaches the target project's
  `tira.policy.bridge` as a `monitor-output` event on a shared board, and
  the real token is a credential, not something safe to broadcast there.
  The printed `--bot` value in multi-bot mode is therefore **not directly
  runnable as-is** - whoever runs `d2 tg.reply` for that chat must supply
  the real token themselves (their own `D2TG_TOKEN`, or direct knowledge
  of which bot serves which chat), the same requirement single-bot mode
  already has whenever `D2TG_TOKEN` isn't the right bot. Single-bot/env-
  only mode is unchanged - no `--bot` is ever printed there, since
  `D2TG_TOKEN` alone is already unambiguous.

If the sender used Telegram's native reply-to-message feature, every
content line above also carries a `(replying to <sender> [msg #N]:
<snippet-or-kind>)` suffix (TGT-029, message id added TGT-041) naming
what the reply targets — the original sender's username, that message's
own `message_id`, and a description of the original message. A fresh
message (no reply) gets no suffix.

As of TGT-038, that description is looked up first in this skill's own
stored message history (every processed text/voice-transcript/media line
is recorded against its own chat_id+message_id) — so a reply to a
previously downloaded document names its kind/caption (never its real
local path, per TGT-133 - fetch it via `d2 tg.attachment` if needed),
and a reply to a previously transcribed voice note shows its actual
transcript, instead of just the bare word `document`/`voice`. Only when
nothing was ever stored for the replied-to message (it predates this
feature, or its sender was never allow-listed at the time) does the
suffix fall back to Telegram's own payload: a snippet of the original
text (up to 5000 chars, TGT-035 - comfortably exceeds Telegram's own
4096-char message limit, so a quoted message is effectively never
truncated in practice) or its media kind if the original had none.

Requires a local `whisper` install (a multilingual, non `.en` model) for
voice transcription. No extra dependency is needed for photo/document
download - it reuses the same `D2TG::Download` module.

Voice transcription is bounded by a timeout (TGT-031; scaled per-attempt
since TGT-140): for an automatically-selected model, the budget is
`duration * 8` (an external review finding, confirmed live by Michael -
`$TIMEOUT` alone stayed a flat 300s even after model selection became
duration-tiered), floored at `$TIMEOUT` itself and capped at
`max(3600, $TIMEOUT)` (never a hard-coded 300s/3600s pair - a
caller-configured `$TIMEOUT` is always respected as both the minimum and,
if larger than the default, the ceiling too). An explicitly-passed
`model` keeps the flat `$TIMEOUT` default unchanged. If
`whisper` runs longer than its budget, it is killed and a
`TRANSCRIBE ERROR` is reported instead of blocking the poll loop
indefinitely. `SIGTERM`/`SIGINT` also kill any transcription in progress
immediately, so shutdown is prompt even mid-transcription - previously
Ctrl+C could appear completely unresponsive for as long as a slow
`whisper` run took, since a blocking subprocess call defers Perl's
signal handling until it returns.

`whisper`'s own console output (warnings, language-detection lines,
per-segment transcript lines) never reaches the poller's stdout/stderr
(TGT-030) - only the structured `NEW TG VOICE`/`REPLY WITH` lines do,
keeping the watched stream clean.

The Whisper model itself scales with the voice note's length (TGT-100):
a clip up to 5 minutes starts with `medium` (unchanged quality for the
common case), up to 15 minutes starts with `small`, and anything longer
starts with `base`. This is only a starting guess, though - per-host
Whisper throughput varies far more than audio duration alone can
predict (measured on one host: `medium` runs at ~5.6x real time with no
GPU, so even a 102-second clip took 9m31s). If the chosen model still
times out, transcription automatically retries at the next faster tier
(`medium` → `small` → `base`) instead of failing outright - only a
timeout at `base` itself produces a final `TRANSCRIBE ERROR`.

## `d2 tg.approve [--bot <token>] <chat_id> [--db <alias> | -d <alias>]`

Moves `chat_id` from pending into the allow-list. Prints `Approved N`
and exits 0 on success. Exits 1 (message on STDERR) if `chat_id` was
already allowed under the resolved bot, or was never pending under it at
all. `--db`/`-d` (TGT-051) resolves the same way `d2 tg.poller`'s does.

`--bot <token>` (TGT-098) scopes the approval to that bot - the same
leading-position shape as `d2 tg.reply`'s own `--bot` (TGT-057). The
command's own header above previously showed `--bot` in a trailing
position that was never actually accepted (TGT-210, found via a
scheduled bug-hunt) - fixed to match this section's own (already
correct) description. Omitting it approves under the single-bot
sentinel, unchanged from
before this ticket for every existing single-bot install. Only needed
when a Telegram *group* is shared by more than one of this skill's
configured bots - a group's `chat_id` is the same for every bot that's
a member of it (unlike a private chat's, which Telegram allocates
uniquely per bot), so without `--bot` an approval could otherwise leak
from one bot to another.

Its own `approve`/`is_allowed` calls (TGT-195, found via a repo-wide
grep sweep done as part of a Codex QA-stage review on TGT-194) are now
`eval`-wrapped and classified via `D2TG::Poller::Safe::classify_store_error`
- a locked/busy database at either one used to die raw, uncaught,
printing the real Perl/DBI exception (which can embed the real
db_path) to STDERR and exiting non-zero via Perl's own default
die-at-top-level behavior, instead of the same clean, scrubbed refusal
this project's established pattern provides everywhere else.

Argv-shape validation now runs before `--db` storage resolution
(TGT-211, found via a scheduled improvement hunt) - previously it ran
after, so a caller giving both a bad `--db` and a malformed `<chat_id>`
at once got an exit 1/storage-error instead of the exit 2/`Usage:`
every majority sibling command (`d2 tg.whoami`, `d2
tg.text-only-replies`, `d2 tg.unread`, `d2 tg.status`) gives for the
same class of double-invalid-input. Single-invalid-input behavior is
unaffected.

## `d2 tg.reply [--db <alias> | -d <alias>] [--bot <token>] [--voice-only] <chat_id> <text...> [--reply-to-message-id <id>]`

(`--reply-to-message-id`, when given, must be the last two arguments -
see below; `--db`/`-d`, `--bot`, and `--voice-only` are the opposite -
recognized only in the *leading* position, before `chat_id`, for the
same collision-avoidance reason, and in any order relative to each
other)

The poller's own `REPLY WITH` recovery-command template
(`D2TG::Poller::Format::print_reply_template`) prints `--bot` in this same leading position
(TGT-227, found via a scheduled JOB-003 hourly bug hunt - previously it
printed `--bot` AFTER `chat_id`, a position this command never actually
parses; a `--bot` flag there fell into the reply text itself and was
sent to Telegram verbatim, leaking the real token into the message if
an operator substituted it in place per this module's own instructions,
while the real send silently used the wrong bot). Always copy the
printed template's own argument order exactly rather than reconstructing
it by hand. A `--bot` flag immediately followed by another flag (e.g.
`--bot --db somealias ...`) is refused cleanly with a `--bot requires a
value` message and exit 1 (TGT-231, found via a scheduled JOB-003
hourly bug hunt, live-reproduced) - previously this crashed with Perl's
raw, uncaught exit 255, since the underlying validation's own die was
never caught here, unlike `d2 tg.approve`/`d2 tg.retry-download`'s
already-correct handling of the identical case.

`--voice-only` (TGT-109, a live-experienced incident) skips
`send_message` entirely and resends only a synthesized voice note for
`text`, via `D2TG::Reply::resend_voice` - recovers a reply whose text
already delivered successfully but whose voice half then failed to
synthesize/send (possible because of TGT-083's deliberate text-first
ordering) without duplicating the already-sent text, which running the
plain command again would do. Prints `Resent voice-only to <chat_id>` on
success; a failure is still reported through the same
`format_send_error` path as the normal send. Before attempting the
resend, looks up the most recent still-flagged `d2 tg.text-only-replies`
entry for this exact chat AND bot (TGT-105, scoped by `--bot`/`D2TG_TOKEN`
- a Codex review finding, mirroring TGT-098's own multi-bot isolation
lesson, so one bot's recovery can never select and clear a different
bot's own flag for a chat shared across bots) - a successful resend
clears that flag via `D2TG::Store::record_sent_voice`.

`--bot <token>` (TGT-057) sends via that bot token instead of
`D2TG_TOKEN` - required when replying to a message received under
`d2 tg.poller`'s multi-bot mode (TGT-049) by a bot other than the one
`D2TG_TOKEN` happens to name; the poller's own `REPLY WITH` template
already fills this in when it applies. Omitting it is unchanged from
before this ticket - falls back to `D2TG_TOKEN`, exactly as every
single-bot-mode reply always has. A bare trailing `--bot` with no value
following it does not hang (TGT-068, a real live-reproduced infinite
loop before this fix) and dies with a clear `--bot requires a value`
message (TGT-268, found via a scheduled JOB-003 hourly bug hunt -
originally fell through to a generic `Usage` error, since this script
special-cased a short `@ARGV` instead of always calling
`extract_bot_flag_or_die`, which reintroduced one layer up the exact
silent-discard bug TGT-264 already fixed inside `extract_bot_flag`
itself). `--bot` immediately followed by another flag (e.g. `--bot
--db myalias`) is also rejected (TGT-074, same bug class as `--db`'s
own case above): it dies with the same clear `--bot requires a value`
message instead of silently treating that flag's own name as the bot
token.

Sends `text` to `chat_id` as **both** a text message and a gTTS voice
note. As of TGT-083 (a live, explicit user request), the text message is
sent **first**, then the voice note is synthesized (`gtts-cli` then
`ffmpeg`) and sent — the reverse of this command's original order. There
is still no flag or code path that sends text without also attempting
voice, and a synthesis or send-voice failure still makes the whole
command die with a non-zero exit — but because that failure now happens
*after* the text has already gone out, it can no longer prevent a
text-only outcome the way the original order could (Telegram messages
can't be unsent). See `docs/POLICIES.md`'s reply-ordering section and
`.claude/rules/tg-skill-design.md`'s "Reply design lessons" section for
the full incident history and rationale. Text longer than 4000 UTF-16
code units is split across multiple `sendMessage` calls without ever
breaking a single character (a supplementary-plane character, which is a
UTF-16 surrogate pair, is always kept in one chunk).

`chat_id` must be numeric (matching `d2 tg.approve`'s own guard,
TGT-027) — a non-numeric first argument exits 2 with a `Usage` message
on STDERR, before any Telegram call is attempted.

`--reply-to-message-id <id>` (TGT-040) is optional and is recognized
only in the **trailing** position - the last two arguments, matching
exactly how the `REPLY WITH` template always prints it (TGT-042:
recognizing it anywhere would make free reply text ambiguous with the
flag itself, whenever that text is passed as multiple unquoted shell
words containing the literal token `--reply-to-message-id`). When given,
both the voice and text sends carry Telegram's own `reply_to_message_id`,
so the reply threads natively under the original message in Telegram's
UI instead of arriving as a fresh, unthreaded message. The poller's
`REPLY WITH` template already fills this in with the inbound message's
own `message_id` when one is known - copy the template as printed and it
just works. Omitting the flag is unchanged from before TGT-040.

When `--reply-to-message-id` is given, that message is also marked
**read** (TGT-046) once the reply has actually been sent successfully -
never for a reply that failed (a TTS or send failure dies before
anything is marked). A message with no reply against it stays unread.

Requires `gtts-cli` and `ffmpeg` to be installed on the machine running
this command. Every text send is recorded via `D2TG::Store::record_sent_text`
immediately after it succeeds, and the matching voice send once that
also succeeds (TGT-105) - a row still missing its voice half is exactly
what `d2 tg.text-only-replies` reports; see that command's own section
for the full rationale.

Before sending at all, refuses if the exact same `text` was already
sent to this `chat_id` (and bot) within the last 10 seconds (TGT-114,
via `D2TG::Store::is_recent_duplicate_reply`) - an accidentally re-run
`d2 tg.reply` command, or a retry after a confirmed prior success whose
voice half then failed, no longer delivers the same text a second time.
Dies before `send_message` is ever called, so the duplicate never
reaches Telegram at all. Only checked when a store is available
(every real invocation has one); doesn't protect against retrying after
an *ambiguous* `send_message` failure (one whose response never
confirmed success or failure to this process) - only a confirmed prior
success is ever checked against.

`chat_id`/`text`/`--reply-to-message-id` validation now runs **before**
`--db`/`-d` is resolved (TGT-309, found via a scheduled JOB-004
improvement hunt) - a caller supplying both a bad `--db` alias and
malformed positional args gets exit 2 (`Usage:`), never exit 1 from a
storage-resolution error, matching TGT-211's own established ordering
for every sibling `d2 tg.*` command.

## `d2 tg.text-only-replies [--db <alias> | -d <alias>]`

TGT-105 (user-supplied feature-gap analysis): TGT-083 deliberately
reordered `send_reply` to send text first, then synthesize+send voice -
a synthesis or `send_voice` failure after that point can leave a reply
text-only, always reported loudly (non-zero exit) at the moment it
happens. If that loud failure is missed (the agent wasn't watching, the
error scrolled past), there was previously no way to find out later.

Lists every currently-flagged reply across every configured bot - chat
id, the bot key (only shown for a genuinely multi-bot config), the text
message's own id, and when it was sent - or `No text-only replies
found.` when clean. Exits 1 when anything is flagged (0 when clean), so
this is suitable for a periodic scheduled check, not only manual
inspection.

Scoped by `bot_key` the same way `allow_list`/`pending` already are
(TGT-098's own lesson, a Codex review finding for this ticket): a
Telegram group shared by more than one configured bot never lets one
bot's flagged replies get confused with another's sharing the same
`chat_id`.

**Known limitation** (a Codex review finding, accepted rather than
solved): the text send and its store record are two separate,
non-atomic steps against two separate systems (Telegram's API and this
skill's own SQLite database) - a process kill or a database error in
the narrow window between a successful `sendMessage` and the record
actually being written would leave a genuinely-sent text message
invisible to this checker if its voice half then also fails. This
mirrors `d2 tg.retry-download`'s own accepted best-effort tradeoff
(TGT-104) for its queue write - a substantial improvement over no
record at all, not a guarantee.

## `d2 tg.send [--db <alias> | -d <alias>] [--bot <token>] [--caption <text>] [--reply-to-message-id <id>] <chat_id> <file_path>`

TGT-103 (user-supplied feature-gap analysis): pushes a local file to a
chat as a Telegram photo or document - the old `~/skills/tg` blueprint
had two dedicated senders for exactly this; this skill had no outbound-
media primitive at all until this command (inbound media, arriving FROM
the owner, already worked fully via `D2TG::Download`).

Whether the file sends as a photo (renders inline in Telegram's UI) or a
document (downloadable) is decided by its extension - `.jpg`/`.jpeg`/
`.png`/`.gif`/`.webp` (case-insensitive) send as a photo, everything
else as a document. No content sniffing - Telegram accepts any file type
via `sendDocument` regardless of what it actually contains. A `--bot`
flag immediately followed by another flag (e.g. `--bot --caption ...`)
is refused cleanly with a `--bot requires a value` message and exit 1
(TGT-231, found via a scheduled JOB-003 hourly bug hunt, live-
reproduced) - previously this crashed with Perl's raw, uncaught exit
255, the same gap `d2 tg.reply` had.

`--db`/`-d` is recognized anywhere in the argument list (TGT-124, found
via a scheduled improvement-hunt) - it used to be hand-parsed in a loop
that stopped at the first non-flag token, so `d2 tg.send <chat_id>
<file> --db myalias` refused with a bogus Usage error instead of
resolving `--db` from its trailing position; now matches every other
`d2 tg.*` command's own `D2TG::Config::Flags::extract_db_flag` behavior.
`--bot` still matches `d2 tg.reply`'s own leading-position shape and
validation. `--caption <text>` is optional free text attached to the
sent photo/document. `--reply-to-message-id <id>` (numeric) threads the
send under an existing Telegram message, same as `d2 tg.reply`'s own
flag - but recognized in leading position here (unlike `d2 tg.reply`'s
trailing-only convention), since `file_path` is a single unambiguous
argument, not free-form text that could contain the literal flag token.

Any argument left over after `chat_id`/`file_path` refuses with `Usage`
(exit 2) instead of being silently dropped - a Codex review finding:
`--caption`/`--reply-to-message-id` given *after* `chat_id file_path`
used to be accepted syntactically and then silently ignored, sending
the file with neither.

`chat_id` is validated as numeric and `file_path` must exist on disk as
a genuine regular file (`-f`, not merely `-e` - another Codex finding:
`-e` alone also accepts a directory/FIFO/device/socket, none of which is
a valid upload, and a FIFO could block the read indefinitely) before any
network call is attempted - a missing/non-regular file or a bad chat_id
refuses with a clear message rather than an opaque Telegram API error.

`chat_id`/`file_path`/`@extra` validation now runs **before** `--db`/
`-d` is resolved (TGT-309, found via a scheduled JOB-004 improvement
hunt) - a caller supplying both a bad `--db` alias and malformed
positional args gets exit 2 (`Usage:`), never exit 1 from a
storage-resolution error, matching TGT-211's own established ordering
for every sibling `d2 tg.*` command.

The local file's basename is escaped and sanitized before it reaches
the outbound multipart request (TGT-125, found via a scheduled
bug-hunt) - a literal double-quote in it previously corrupted the
`Content-Disposition` header Telegram receives, and a filename
containing a literal CR/LF could have injected an additional header
line into the request. The file still uploads correctly either way;
only the displayed filename is sanitized (control characters removed,
quotes/backslashes escaped).

## `d2 tg.tts [--out <path>] <text...>`

TGT-106 (user-supplied feature-gap analysis): the old `~/skills/tg`
blueprint's text-to-speech step was a small, self-contained piece
callable directly by anything on the project - this skill's
`D2TG::TTS::synthesize` does the same underlying work, but was only
ever reachable from inside `d2 tg.reply`. This command exposes it
directly: text in, an audio file out, **no Telegram interaction at
all** - no `--db`/`-d`/`D2TG_DB` requirement either, since it touches no
storage. Useful for anything that just needs a spoken audio file - e.g.
attaching a voice note to a `tira.question.ask --voice` card question,
this project's own standing rule for every card question.

`--out <path>` writes the synthesized audio there; without it, prints
the path of a temp file instead (still a real, playable file - just not
at a location the caller chose). An existing directory given as `--out`
is refused with a clear error rather than silently placing the file
inside it (a Codex review finding: `File::Copy::move` would otherwise
do exactly that, and the command would then print the directory's own
path rather than the file it actually wrote).

Synthesis failure (`gtts-cli`/`ffmpeg` unavailable, or any other failure
inside `D2TG::TTS::synthesize`, or a failure to write to the requested
`--out` path itself) is reported loudly - non-zero exit, and the
`--out` path stays exactly as it was before the failed attempt: absent
if it didn't already exist, and - a second Codex review round caught a
real bug here - **completely untouched if a different, pre-existing
file already lived there**, since an earlier version's cleanup logic
would have deleted it even though it had nothing to do with the failed
write. This is done via a same-directory staging file plus a single
atomic rename, matching this skill's existing fail-loud TTS convention
(see `docs/POLICIES.md`'s "Outbound TTS failure is fatal" section).
Does not change `D2TG::TTS::synthesize` or `D2TG::Reply`'s own internal
use of it at all - purely a thin wrapper via the new
`D2TG::TTS::synthesize_to_file`.

## `d2 tg.whoami [--db <alias> | -d <alias>]`

`--db`/`-d` uses the same shared `D2TG::Config::Flags::extract_db_flag` every
other `d2 tg.*` command does (TGT-124, found via a scheduled
improvement-hunt fixing a hand-rolled duplicate) - since this command
accepts no other flags, this is a behavior-preserving consistency fix,
not a change in what invocations it accepts.

TGT-115 (user-supplied feature-gap analysis): with several projects on
one host each running their own installed copy of this skill under
different Developer Dashboard path aliases, there was no cheap way to
confirm which project's bot token/chat id/storage location a given
shell's env vars actually resolve to - short of reading
`D2TG_TOKEN`/`D2TG_CHAT_ID`/`D2TG_DB` by hand, or risking a real `d2
tg.poller` startup or `d2 tg.reply` send just to find out.

Prints the installed `VERSION`, the masked token
(`D2TG::Config::masked_token` - never the raw token), the configured
`chat_id` (or `(not set)`), and the resolved storage/attachments
location (`D2TG::Config::state_db_path`/`attachments_dir`) - the same
resolution every other `d2 tg.*` command uses. Makes **no HTTP request
at all** (never loads `D2TG::Telegram`) - safe to run at any time,
including with a completely unconfigured or misconfigured token, as the
first sanity check before trusting anything else this skill reports.
`chat_id` and the resolved paths are printed in full (only the token is
masked) - deliberate: printing an unmasked `chat_id` matches
`cli/poller.pl`'s own existing startup-line precedent (TGT-045), while
the resolved storage/attachments paths are additional operational
information this command adds beyond what that precedent covers, not
something already exposed elsewhere. The same care about where command
output ends up (shell scrollback, captured logs) applies as with any
other `d2 tg.*` command. `masked_token`'s own short-token behavior
(TGT-138: a token of length <= 8 is shown as the fixed placeholder
`(short token, not shown)`, never as-is) is described accurately in
this command's own POD as of TGT-201 (found via a scheduled JOB-003
hourly bug hunt) - the POD previously still described the pre-TGT-138
shown-as-is behavior, a documentation-accuracy defect only, since
`masked_token`'s own real behavior was already correct.

## `d2 tg.status [--db <alias> | -d <alias>]`

`--db`/`-d` uses the same shared `D2TG::Config::Flags::extract_db_flag` every
other `d2 tg.*` command does (TGT-124, found via a scheduled
improvement-hunt fixing a hand-rolled duplicate) - since this command
accepts no other flags, this is a behavior-preserving consistency fix,
not a change in what invocations it accepts.

TGT-111 (user-supplied feature-gap analysis): reports the installed
version and whether the poller is currently alive, without reaching into
Tira job metadata (`pid`/`last_output_at`) from outside this skill.
Prints `d2tg version: <version>` and either `poller: running (pid <pid>)`
or `poller: not running`.

Read-only - touches no state, sends no network request, and deliberately
never calls `D2TG::Lock::acquire` to answer the question: doing so could
evict a genuinely live poller under this skill's own "last one wins"
lock policy (TGT-084), which is exactly the kind of side effect a status
check must never risk. `D2TG::Lock::is_held` instead sends only a
harmless `kill(0, $pid)` liveness probe (no real signal delivered) and
never touches the lock file itself. `--db`/`-d` resolves the same
storage location the poller itself would use, so this reports on the
right instance.

Also prints `heartbeat: never` (no pair has ever completed a poll cycle
at this storage location), `heartbeat: <N>s ago (ok)`, or `heartbeat:
<N>s ago (STALE)` past a threshold (TGT-116, a live-experienced
incident: a poller stayed alive and held its lock for 80+ minutes while
doing nothing at all, silently losing a message - "alive" and "still
genuinely cycling" are different questions) now derived (TGT-147, not a
re-typed literal, since a scheduled bug hunt caught the original fixed
1200s going stale the moment TGT-140 shipped its own duration-scaled
transcription timeout in this same session) from `D2TG::Transcribe`'s
own `$TIMEOUT_CEILING`/`@MODEL_TIERS` constants - currently 14400s
(4h), `$TIMEOUT_CEILING * scalar(@MODEL_TIERS) * 4/3`. The heartbeat is
written by `cli/poller.pl` after each bot/chat pair's own poll cycle
(not once per full multi-pair cycle - a Codex review caught that the
latter could falsely flag a healthy poller as stale during a single
slow voice transcription's full retry ladder, now up to that same
worst-case bound), atomically (temp file + `rename`) via
`D2TG::Config::write_heartbeat`. Automatic restart-on-stale is
intentionally not built - a genuinely stuck poller cannot restart
itself, so that needs either a second always-running watchdog process or
a Tira-scheduled job to do the restarting, an operational decision
flagged as a follow-up rather than built unilaterally.

## `d2 tg.unread [--bot <token>] [--db <alias> | -d <alias>]`

Lists every stored message (TGT-038) not yet marked read (TGT-046),
oldest first: chat id, message id, sender, timestamp, and the stored
summary. Prints `No unread messages.` and exits 0 when there are none,
rather than a blank/confusing output. `--db`/`-d` (TGT-051) resolves
the same way `d2 tg.poller`'s does. The summary text for a downloaded
photo/document never contains its real local filesystem path (TGT-133)
- fetch the actual bytes via `d2 tg.attachment`, below. Refuses with a
`Usage:` message and exit code 2 on any unrecognized flag or leftover
positional argument (TGT-149, found via a scheduled bug-hunt) - the
one sibling command in this family missing that check until now.
After the unread message list (or in its place, if there are none),
also lists any currently-queued failed media downloads (TGT-204, a
real live-reported incident - a queued failed download is not an
unread message, since it was never recorded into message history at
all, but is exactly the kind of "needs your attention" state this
command exists to surface), naming the exact recovery command
(`d2 tg.retry-download --all`). This listing is unscoped across every
configured bot; the printed `RETRY WITH` hint is now correctly scoped
per bot too (TGT-229, found via a scheduled JOB-003 hourly bug hunt -
previously one bot-agnostic literal that could never actually retry a
non-default-bot row) - each row shows its own bot (masked) when more
than one bot's queue is present, and one `RETRY WITH: d2
tg.retry-download --all [--bot <masked-token>]` line is printed per
distinct bot found; single-bot installs see the exact same output as
before. `--bot <token>` (TGT-233, fast-follow from TGT-232's own scope
decision) now scopes the unread listing itself to that bot's own
messages, using the same leading-position, eval-wrapped
`extract_bot_flag` convention as `cli/retry-download.pl`; omitting it
preserves today's exact default-bot behavior unchanged. TGT-232 made
`D2TG::Store`'s `messages` table `bot_key`-aware, but until now this
command had no `--bot` flag at all, so it could never actually exercise
that scoping. After the failed-downloads section (or in its place, if
there are none), also lists any currently-queued failed voice
transcriptions (TGT-239, found via a scheduled JOB-003 hourly bug hunt
- TGT-237 built the `failed_transcriptions` retry queue but never
wired it into this command's own visibility, so a queued failed
transcription was invisible here and could silently expire via
TGT-238's own 30-day eviction with zero visibility), naming the exact
recovery command (`d2 tg.retry-transcription --all`) - structured
identically to the failed-downloads section above it, including the
same per-bot `RETRY WITH` scoping (TGT-229's own convention, reused
rather than reinvented); single-bot installs see byte-identical output
when nothing is queued.

## `d2 tg.attachment [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]`

TGT-133 (live Telegram request): writes a previously-downloaded
attachment's raw bytes to stdout - the real on-disk path is never
printed anywhere by this skill, matching this project's own Tira board
convention (`tira.attachment.get` writes raw content to stdout, never a
path). `D2TG::Poller`'s `NEW TG MEDIA` line, and the summary text
`d2 tg.history`/`d2 tg.unread` display for that message, both advise
this exact command (`GET ATTACHMENT WITH: d2 tg.attachment <chat_id>
<message_id>`) instead of ever showing the path. Refuses (exit 1,
clear STDERR message) if no attachment is recorded for that
`(chat_id, message_id)` pair, if the stored file can no longer be
opened, or if the recorded path is no longer a regular file; refuses
(exit 2, Usage) if `chat_id`/`message_id` are missing or not numeric -
checked before `--db` storage resolution (TGT-211, found via a
scheduled improvement hunt, reordered from checking storage first),
matching the majority sibling family so a caller with both a bad `--db`
and malformed positional args gets a consistent exit 2/Usage rather
than an exit 1/storage-error. `--db`/`-d` (TGT-051) resolves the same
way `d2 tg.poller`'s does. `--bot <token>` (TGT-233, fast-follow from
TGT-232) scopes the attachment lookup to that bot's own recorded
`(chat_id, message_id)` row, matching `cli/retry-download.pl`'s own
established leading-position, eval-wrapped `extract_bot_flag`
convention; omitting it preserves today's exact default-bot lookup
unchanged.

Marks the message read (TGT-311, explicit user-requested architecture
change) as a side effect of a successful fetch - only once the bytes
have actually been streamed, never on a refusal. Fetching and marking
read are one action, not two.

**Fetching is not permanently guaranteed** (TGT-134): a stored
`local_path` never expires from the database, but the file itself can
be evicted at any later time by `D2TG::Download::prune_vault`'s own
byte-cap eviction (run after every poll cycle) if this attachment is
old and was never re-fetched (a dedup hit refreshes its mtime, TGT-054,
protecting anything actually re-used). A missing file's refusal names
pruning as the likely cause specifically, rather than a generic
"cannot open" message. Redirect stdout to save the file:
`d2 tg.attachment 398296603 130 > photo.jpg`.

**Worked example** (TGT-136): a poll cycle reporting one photo message
prints something like this on stdout -

```
[2026-09-09 07:44:47] NEW TG MEDIA [398296603] Michael: photo (msg #130)
GET ATTACHMENT WITH: d2 tg.attachment 398296603 130
REPLY WITH: d2 tg.reply 398296603 "..." --reply-to-message-id 130
```

- The `NEW TG MEDIA` line announces the message - chat id, sender, kind,
  and message id - but never the file's real path.
- The `GET ATTACHMENT WITH` line names the exact `chat_id`/`message_id`
  to use - run it with a redirect appended (never bare, which dumps raw
  bytes to the terminal): `d2 tg.attachment 398296603 130 > photo.jpg`.
- The `REPLY WITH` line (unrelated to the attachment) is the usual
  reply-command template, printed after every content line as always.

A poll cycle reporting several media messages at once prints this same
three-line block once per message, each with its own `message_id` - a
photo and a document arriving together produce two independent
`GET ATTACHMENT WITH` lines, never one combined or ambiguous one.

## `d2 tg.fetch [--bot <token>] <chat_id> <message_id> [--db <alias> | -d <alias>]`

TGT-311 (explicit user-requested architecture change to the core
message-intake flow): `d2 tg.poller` no longer prints a new text or
successfully-transcribed-voice message's own content inline - it
prints only chat_id/message_id/sender and a `FETCH WITH: d2 tg.fetch
<chat_id> <message_id>` command. This command is the deliberate,
explicit step that actually reveals the content: looks up the stored
`summary` for the given `(chat_id, message_id)` pair via
`D2TG::Store::get_message` and prints it to stdout, then marks that
message read via `D2TG::Store::mark_read` - in that order, so a
message is only ever marked read once its content has actually been
successfully shown, matching `send_reply`'s own TGT-046 "only after
success" precedent. Fetching and marking read are deliberately one
action, not two - there is no separate command to mark a message read.

Refuses (exit 1, clear STDERR message) if no message is recorded for
that `(chat_id, message_id)` pair - nothing is ever marked read in
that case, since there was nothing to show; refuses (exit 2, Usage) if
`chat_id`/`message_id` are missing or not numeric - checked before
`--db` storage resolution, matching every sibling command. `--db`/`-d`
(or `D2TG_DB`) resolves the same way `d2 tg.poller`'s does. `--bot
<token>` scopes the lookup to that bot's own recorded row, matching
`d2 tg.attachment`'s established convention; omitting it acts on the
single-bot sentinel.

This command intentionally does not handle photos/documents - those
already have their own fetch step, `d2 tg.attachment` (above), which
gained this same mark-read-on-success behavior in the same ticket.

**Worked example**: a poll cycle reporting one text message prints
something like this on stdout -

```
[2026-09-18 14:00:00] NEW TG [398296603] Michael (msg #131)
FETCH WITH: d2 tg.fetch 398296603 131
REPLY WITH: d2 tg.reply 398296603 "..." --reply-to-message-id 131
```

- The `NEW TG` line announces the message - chat id, sender, and
  message id - but never the text itself.
- The `FETCH WITH` line names the exact `chat_id`/`message_id` to use:
  `d2 tg.fetch 398296603 131` prints the message's own text and marks
  it read.
- The `REPLY WITH` line (unrelated to fetching) is the usual
  reply-command template, printed after every content line as always.

## `d2 tg.retry-download [--bot <token>] [--db <alias> | -d <alias>] [<id> | --all]`

TGT-104 (user-supplied feature-gap analysis): `d2 tg.poller` now
attempts to persist each failed inbound photo/document download
(chat_id, message_id, file_id, sender, media kind, caption, the
original error) to `D2TG::Store`'s `failed_downloads` queue instead of
only printing a `MEDIA DOWNLOAD ERROR` line and forgetting it - useful
because a transient failure (a network hiccup mid-transfer, a momentary
server error) is genuinely recoverable on retry. A queue-write failure
itself is non-fatal, matching the download failure it's recording (a
Codex review finding), and simply leaves that one download unqueued.
The queue is keyed uniquely by `(chat_id, bot_key, message_id)` (TGT-219,
found via a scheduled improvement hunt - `bot_key` added; previously
just `(chat_id, message_id)`, which silently collapsed the same
message_id failing under two different bots in a multi-bot config into
one row, even though Telegram's own `file_id` values are bot-token-
scoped and a retry under the wrong bot could never succeed), so
Telegram's own at-least-once delivery redelivering the same failed
update under the SAME bot still refreshes the existing row rather than
duplicating it (another Codex finding). `--bot <token>` (TGT-219) scopes
both listing and retrying to that bot, using the same leading-position
shape `cli/reply.pl`/`cli/approve.pl`'s own `--bot` use; omitting it
acts on the single-bot sentinel, matching every existing single-bot
install's behavior exactly. The `RETRY WITH` line the poller itself
prints when queuing a failure now names the exact `--bot` flag to add
for a multi-bot failure (TGT-220), so this command's own multi-bot
usage is discoverable from the poller's own stdout, not just this doc.

Argv-shape validation (a leftover argument, or a value that's neither
numeric nor `--all`) now runs before `--db` storage resolution
(TGT-211, found via a scheduled improvement hunt) - matching the
majority sibling family, so a caller with both a bad `--db` and a
malformed positional argument gets a consistent exit 2/Usage rather
than an exit 1/storage-error.

With no positional argument, lists every currently-queued entry - id,
chat_id, message_id, file_id, the original error, when it was queued -
or `No failed downloads queued.` when empty. With a numeric `id`,
retries exactly that entry via `D2TG::Download::retry_failed_download`,
which requests a fresh download using the saved `file_id` (a Codex
review, backed by a web search of Telegram's own Bot API docs, corrected
an earlier draft's assumption that `file_id`s expire on a short fixed
clock - it's the one-hour-valid `file_path` a `getFile` call resolves a
`file_id` to that's short-lived, and every retry already calls `getFile`
fresh); with `--all`, retries every currently-queued entry in turn (one
failure doesn't stop the rest). A successful retry prints `RETRY OK`
naming the `d2 tg.attachment` fetch command (TGT-146 - never the real
local filesystem path itself, matching TGT-133's own never-expose-the-
real-path convention; an earlier version of this line leaked the raw
path to stdout, which reaches the target project's `tira.policy.bridge`
as monitor-output), restores the message into `D2TG::Store`'s own
history via `record_message` (so `d2 tg.history`/`d2 tg.unread` show it -
a Codex review caught an earlier draft only deleted the queue row and
left nothing to show), and removes the queue entry; a failed retry is
reported on STDERR and the entry stays queued untouched. If Telegram's
own response to the retry looks like its shape for a permanently-gone
`file_id` (`D2TG::Config::is_expired_file_error` - "file is no longer
available"/"wrong file_id"), the line says `RETRY EXPIRED` - a
classification of that response text, not proof a time-based expiry
occurred - deliberately NOT for "file is temporarily unavailable" (a
Codex review caught an earlier draft treating that transient-sounding
wording as permanent too).

TGT-247 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced):
`RETRY OK` is only printed once the retry is genuinely fully complete -
the downloaded file AND the `messages` history row it depends on both
exist. `D2TG::Download::retry_failed_download` can succeed at the
download but still fail the follow-up `record_message` write (a
transient locked/busy database); it reports this via its own 3rd return
value, `$still_queued` (TGT-244) - the row stays queued in
`failed_downloads` (never removed) and `d2 tg.attachment` has nothing to
serve yet, since no `messages` row was ever written. This command now
prints `RETRY PARTIAL` instead of `RETRY OK` for that case, naming the
row as still queued (it is retried automatically, or manually via
`d2 tg.retry-download <id>` again) rather than pointing at a
`d2 tg.attachment` command that is guaranteed to fail. Before this fix,
`$still_queued` was silently discarded and every download success - full
or partial - printed the same `RETRY OK`/`GET ATTACHMENT WITH` line.

TGT-249 (found via a scheduled JOB-003 hourly bug hunt): `$still_queued`
itself used to be wrong in one further edge case - `retry_failed_download`
hardcoded it to `0` once `record_message` succeeded, without checking
whether the follow-up `remove_failed_download` write (which actually
clears the row) succeeded too. If that removal write hit its own
transient failure, the row stayed genuinely queued in `failed_downloads`
but this command still printed `RETRY OK`. Fixed by deriving
`$still_queued` from that removal write's own success/failure instead of
assuming it.

## `d2 tg.retry-transcription [--bot <token>] [--db <alias> | -d <alias>] [<id> | --all]`

TGT-237 (found via a scheduled JOB-003 hourly bug hunt): `d2 tg.poller`
now persists each failed voice transcription (chat_id, message_id, the
Telegram `file_id`, sender, the original error) to `D2TG::Store`'s
`failed_transcriptions` queue instead of only printing a
`TRANSCRIBE ERROR` line and losing the voice note forever - mirrors
`d2 tg.retry-download`'s own established `failed_downloads` pattern
(TGT-104) exactly, including the eval-wrapped non-fatal queue write and
`--bot <token>` scoping (Telegram's own `file_id` values are
bot-token-scoped, so a queued failure recorded under a non-default bot
must be retried as that same bot).

With no positional argument, lists every currently-queued failed
transcription - id, chat_id, message_id, file_id, the original error,
when it was queued - or `No failed transcriptions queued.` when empty.
Argv-shape validation runs before `--db` storage resolution, matching
`d2 tg.retry-download`'s own established ordering.

With a numeric `id`, retries exactly that entry via
`D2TG::Download::retry_failed_transcription` - re-downloads the voice
file transiently (never landing in the shared attachments vault,
matching `d2 tg.poller`'s own `$transcribe_voice` coderef, and always
unlinked afterward regardless of outcome) and re-attempts
transcription. A successful retry restores the message into
`D2TG::Store`'s own history via `record_message` before removing the
queue entry, and prints `RETRY OK` naming the recovered transcript
text directly (unlike `d2 tg.retry-download`'s own `RETRY OK`, which
deliberately never prints a real local filesystem path - a transcript
is text, not a path, so no equivalent leak risk exists here). With
`--all`, retries every currently-queued entry in turn - one failure
doesn't stop the rest. A failed retry is reported on STDERR (`RETRY
FAILED`, or `RETRY EXPIRED` for Telegram's own permanently-gone-`file_id`
shape via `D2TG::Config::is_expired_file_error`, matching `d2
tg.retry-download`'s own distinction) and the entry stays queued
untouched.

The poller's own `NEW TG VOICE FAILED [chat_id] sender: transcription
failed - queued for retry, RETRY WITH: d2 tg.retry-transcription --all
[--bot <masked-token>]` stdout line (TGT-204's own visibility
precedent for downloads, now also applied to transcription) names this
exact recovery command - previously a transcription failure was only
ever visible via `TRANSCRIBE ERROR` on STDERR, which never reaches the
monitor job's own stdout-fed `tira.policy.bridge` notification stream.

TGT-248 (found via a scheduled JOB-003 hourly bug hunt): `RETRY OK` is
only printed once the retry is genuinely fully complete - the exact same
fix TGT-247 already made for `d2 tg.retry-download`.
`D2TG::Download::retry_failed_transcription` can genuinely recover the
transcript but still fail the follow-up `record_message` write (a
transient locked/busy database); it reports this via its own 3rd return
value, `$still_queued` - the row stays queued in `failed_transcriptions`
(never removed) and no `messages` row was ever written, so nothing
exists yet for `d2 tg.history`/`d2 tg.unread` to show. This command now
prints `RETRY PARTIAL` instead of `RETRY OK` for that case, naming the
row as still queued (retried automatically, or manually via
`d2 tg.retry-transcription <id>` again) and sets a non-zero exit code,
rather than falsely claiming full success. Before this fix,
`$still_queued` was silently discarded and every transcription success -
full or partial - printed the same `RETRY OK: <transcript>` line.

TGT-249 (found via a scheduled JOB-003 hourly bug hunt): mirrors the
`retry_failed_download` fix above exactly - `retry_failed_transcription`
derived `$still_queued` only from whether `record_message` succeeded,
never checking whether the follow-up `remove_failed_transcription` write
that actually clears the row also succeeded. A transient failure in that
removal write left the row genuinely queued while this command still
printed `RETRY OK`. Fixed the same way: `$still_queued` now also
reflects the removal write's own outcome.

## `d2 tg.history [--bot <token>] [--since <iso8601>] [--until <iso8601>] [--db <alias> | -d <alias>]`

Lists stored messages (TGT-038) oldest first: chat id, message id,
sender, timestamp, and the stored summary. Without `--since`/`--until`
(TGT-048), shows the 10 most recent messages. With either or both given
(ISO 8601 timestamps), shows every message in that range instead - an
open-ended range on whichever side is omitted. The comparison is done
via SQLite's own `datetime()` function (TGT-214, found via a scheduled
bug hunt, live-verified) rather than a raw string comparison against
`created_at`'s own stored (space-separated) format - a `--since`/
`--until` value with a `T`-separated time component previously sorted
after every same-day row and silently excluded it, regardless of the
message's actual time; `datetime()` normalizes both sides before
comparing, so results reflect true chronological order. A date-only
`--until` still normalizes to midnight of that date (not the end of the
day) - unchanged by this fix, a separate question from the separator
mismatch it addresses. Prints `No messages found.` and exits 0 when
nothing matches. `--db`/`-d` (TGT-051) resolves the same way `d2 tg.poller`'s
does. `--bot <token>` (TGT-233, fast-follow from TGT-232's own scope
decision) scopes both the default recent-10 listing and the
`--since`/`--until` range listing to that bot's own messages, matching
`cli/retry-download.pl`'s own established leading-position,
eval-wrapped `extract_bot_flag` convention; omitting it preserves
today's exact default-bot behavior unchanged. TGT-232 made
`D2TG::Store`'s `messages` table `bot_key`-aware, but until now this
command had no `--bot` flag at all, so it could never actually exercise
that scoping. `--since`/`--until` with no value following it (or immediately
followed by the other flag) exits 2 with a clear message instead of
silently running unscoped or matching nothing (TGT-070). `--since`/
`--until` also validate the *shape* of their value (TGT-209, found via a
scheduled bug-hunt): a value that doesn't match `YYYY-MM-DD` or
`YYYY-MM-DDTHH:MM:SS` exits 2 naming the malformed value and the
expected format, instead of reaching `D2TG::Store::messages_in_range`'s
own SQL comparison, where a value like `not-a-date` sorts
lexicographically after every real timestamp and silently excludes
every message. Any other unrecognized flag or leftover positional
argument also exits 2 with a
`Usage:` message (TGT-122, found via a scheduled bug-hunt) - previously
silently ignored, exiting 0 as if the (mistyped) invocation had
succeeded - reproduced as `No messages found.` when nothing happened
to match, but a query that happened to match real history would print
it, unrelated to the actual (bad) invocation.

All of this argv validation now runs **before** `--db`/`-d` is resolved
(TGT-309, found via a scheduled JOB-004 improvement hunt) - a caller
supplying both a bad `--db` alias and malformed args gets exit 2
(`Usage:` or one of the date-validation messages above, also exit 2),
never exit 1 from a storage-resolution error, matching TGT-211's own
established ordering for every sibling `d2 tg.*` command.

## Registering as a Tira monitor job

Once installed on a project's board, run the poller as a Tira monitor
job rather than under systemd or cron (Q-003):

```
d2 tira.policy.add --rule monitor-output --action bridge-reminder   # once per board
d2 tira.job.add --schedule monitor --command "d2 tg.poller"
d2 tira.job.start --id JOB-NNN
```

Its stdout/stderr then reaches that project's `tira.policy.bridge` as a
`monitor-output` event - verified end to end in TGT-015 inside a
`developer-dashboard:latest` container.

## Environment variables

- `D2TG_TOKEN` — the Telegram bot token.
- `D2TG_CHAT_ID` — the admin/owner's chat id. Required for `tg.poller`
  to start.
- `DEVELOPER_DASHBOARD_SKILL_ROOT` — overrides where `state/store.sqlite`
  is resolved from; normally set by Developer Dashboard itself.
- `D2TG_DB` (TGT-051) — a Developer Dashboard path alias (see `d2 paths`)
  whose directory relocates both the SQLite state file (as
  `.tira/telegram.messages.db`) and downloaded attachments (as
  `.tira/attachments/` - TGT-081); fallback for every `d2 tg.*`
  command's `--db`/`-d` flag when the flag isn't given. **Required**
  (TGT-059) — every `d2 tg.*` command refuses to start if neither this
  nor `--db`/`-d` is given at all AND `TIRA_HOME` isn't set either (see
  below), the same as an unknown alias already refused.
- `TIRA_HOME` (TGT-081, a live user request) — when none of `--db`/`-d`/
  `D2TG_DB` is given at all, this is used as the base directory instead
  of refusing to start. Only consulted when no alias was given at all;
  an explicit `--db`/`-d`/`D2TG_DB` always takes priority, and an
  unknown alias still refuses rather than falling through to this.
  **Resolved as a `d2 paths` alias first** (TGT-091, a live production
  incident: `TIRA_HOME=tira-zen` was being treated as a literal
  filesystem path and refused, even though `tira-zen` is a real,
  registered alias) — only falls back to using the value directly as a
  literal filesystem path if it doesn't match any registered alias.
  Whichever way it resolves, that final value is used purely as a
  lookup, never a creation target (TGT-090) - if it names a directory
  that doesn't already exist, every `d2 tg.*` command refuses to start
  rather than creating it.
- `D2TG_OWNER` (TGT-079, a live user request) — optional. When set, the
  poller's printed sender name (the main content line and any
  `(replying to ...)` suffix) shows this value instead of the raw
  Telegram username, but only for messages from the `D2TG_CHAT_ID`
  chat - every other sender's username is shown unchanged. Purely a
  display preference; has no effect on access control, which still
  keys entirely on the numeric chat id.

## Module reference

Full behavior/signature detail lives in each module's own POD
(`perldoc lib/D2TG/<Name>.pm`); this is a one-line-each map of what's
implemented and where:

| Module | What it does |
| --- | --- |
| `D2TG::Config` | Reads `D2TG_TOKEN`/`D2TG_CHAT_ID`; startup guard; resolves `state/store.sqlite`'s path (or, for a resolved `--db`/`-d`/`D2TG_DB`/`TIRA_HOME` base_dir, `.tira/telegram.messages.db` and `.tira/attachments/` - TGT-081); `skill_version` reads `.env`'s installed VERSION (TGT-036); `masked_token` masks a token to its first/last 4 chars for safe display (TGT-045); `owner_name` reads `D2TG_OWNER` (TGT-079); `resolve_alias_dir`/`attachments_dir` resolve an optional `--db`/`-d`/`D2TG_DB` Developer Dashboard path alias (or a `TIRA_HOME` fallback, TGT-081) for both storage and attachments (TGT-051); `shift_flag_value`/`extract_db_flag`/`extract_db_flag_or_die`/`bot_groups` (TGT-267, found via TGT-266's own qa gate finding) moved out of this module entirely into `D2TG::Config::Flags` - CLI flag-parsing is a distinct concern from this module's own env-reading/version/error-classification concerns; see the `D2TG::Config::Flags` row below. `lock_path` resolves `cli/poller.pl`'s single-instance lock file path, mirroring `state_db_path`/`attachments_dir`'s own base_dir/`.tira/` resolution exactly (`.tira/telegram.pid` for a resolved base_dir, TGT-087); `resolve_alias_dir_or_die` (TGT-172, found via a scheduled improvement hunt) wraps `resolve_alias_dir` in the eval/print-STDERR/exit(1) pattern that 11 of the 13 `cli/*.pl` scripts had each duplicated identically - a pure extraction, no behavior change; `_with_hard_timeout` (TGT-173, found via a scheduled improvement hunt) is a shared SIGALRM-based hard-timeout wrapper extracted after `D2TG::Telegram` (TGT-044) and `D2TG::Download` (TGT-126) each independently implemented the identical control flow - each call site passes its own exact pre-extraction die-message prefix, so behavior is unchanged; `require_existing_base_dir` (TGT-090) dies if the resolved base_dir doesn't already exist on disk - called by every `cli/*` script right after `resolve_alias_dir`/`resolve_alias_dir_or_die`, so a bogus `TIRA_HOME`/alias target is refused instead of silently `mkdir -p`'d into existence; `require_existing_base_dir_or_die` (TGT-230, found via a scheduled JOB-004 improvement hunt) wraps it in the identical eval/print-STDERR/exit(1) pattern `resolve_alias_dir_or_die`/`D2TG::Config::Flags::extract_db_flag_or_die` already established for their own wrapped calls - all 11 `cli/*.pl` scripts that call `require_existing_base_dir` had each duplicated the wrapper identically; a pure extraction, no behavior change; `resolve_self_exec_path` (TGT-094) checks whether a given basename (`poller.pl`) exists in a given bin directory, returning that fresh path if so and a supplied fallback otherwise - `cli/poller.pl`'s version-change restart uses this instead of blindly `exec()`ing the literal `$0` path captured at launch, so a running poller survives an install that renames its own entrypoint file out from under it; `is_transient_error` (TGT-097, widened by TGT-160) classifies an error message as transient (matches `/timed out/i`, `/status 5\d\d/`, or `/status 429\b/`) or not - a shared predicate now used by both `D2TG::Reply::format_send_error` (TGT-096) and `D2TG::Poller::Safe::run_once_safe` (TGT-097), avoiding duplicated regex. The `429` ("Too Many Requests") case (TGT-160, found via a scheduled hourly bug hunt) treats Telegram's own designed, expected, retryable rate-limit condition (a response body containing `parameters.retry_after`) the same as a 5xx/timeout - silently retried rather than logged as a `POLL ERROR` - without reading/honoring `parameters.retry_after` itself, which would require parsing the response body and is out of scope for this narrow classification fix. `heartbeat_path`/`write_heartbeat`/`heartbeat_age` (TGT-116) mirror `lock_path`'s own `.tira/` resolution exactly (`.tira/telegram.heartbeat` for a resolved base_dir) - the poller writes a heartbeat after each bot/chat pair's own poll cycle, unconditionally, atomically (temp file + `rename`, so a concurrent reader or a crash mid-write never observes a partial file), so `d2 tg.status` can distinguish "still genuinely cycling" from "alive but silently wedged". `is_expired_file_error` (TGT-104) classifies an error as Telegram's own shape for a permanently-gone `file_id` (`/file is no longer available/i` or `/wrong file_id/i`) - deliberately NOT "file is temporarily unavailable" (a Codex review caught an earlier draft treating that transient-sounding wording as permanent, when it can still succeed on a later retry); backs `cli/retry-download.pl`'s `RETRY EXPIRED` vs `RETRY FAILED` distinction. `state_db_path`/`attachments_dir`/`lock_path`/`heartbeat_path`/`write_heartbeat`/`heartbeat_age`/`resolve_alias_dir`/`resolve_alias_dir_or_die`/`require_existing_base_dir`/`require_existing_base_dir_or_die`/`resolve_self_exec_path` (TGT-260, found via TGT-258's own module-decomposition survey) are now thin forwarders onto `D2TG::Config::Paths` - no behavior/signature change for any caller. `_developer_dashboard_paths` moved with them and got no forwarder (private, only ever called from within the same extracted cluster). `resolve_and_require_base_dir_or_die` (TGT-287, found via a scheduled JOB-003/004 sweep) composes `resolve_alias_dir_or_die` immediately followed by `require_existing_base_dir_or_die` on its result - that exact adjacent pairing was hand-copied across 12 `cli/*.pl` scripts; all 12 now call this one function instead. |
| `D2TG::Config::Flags` | `shift_flag_value($args_arrayref, $flag_label)` (TGT-072) shifts the next value off `$args_arrayref` and dies `"$flag_label requires a value"` unless it's defined, non-empty, and doesn't itself look like a flag - backs `extract_db_flag`, `bot_groups`'s `--chat_id`/`--bot` handling, `cli/reply.pl`'s own `--db` extraction, `cli/history.pl`'s `--since`/`--until`, and `D2TG::Reply::Args::extract_bot_flag`'s `--bot` validation - one implementation instead of many independent hand-rolled copies. Since TGT-332 it delegates its own undef/empty guard to `shift_flag_value_free_text` below, adding only the flag-shape check on top (a pure internal refactor, no caller-visible change). `shift_flag_value_free_text($args_arrayref, $flag_label)` (TGT-332, found via a live JOB-003 hourly bug hunt; Q-020 answered by Michael) is a sibling for flags whose value is genuinely free text - currently only `cli/send.pl`'s `--caption` - keeping the undef/empty guard but dropping the flag-shape check entirely, so a caption that legitimately starts with `--` is never misread as a missing flag value. `extract_db_flag(@ARGV)` (TGT-051) parses `--db <alias>`/`-d <alias>` anywhere in a raw argument list, dying `--db/-d requires a value` (TGT-071) on a missing/empty/flag-like value. `extract_db_flag_or_die` (TGT-177) wraps it in a one-line forwarder onto the shared `D2TG::OrDie::or_die` helper (TGT-269) - the same eval/print-STDERR/exit(1) idiom 10 `cli/*.pl` scripts had each independently duplicated around this function before TGT-177's own extraction. `bot_groups(argv => \@argv, env_chat_id => $id, env_token => $token)` (TGT-049) parses repeatable `--chat_id <id>`/`--bot <token>` pairs into an ordered list of groups, folding in `D2TG_CHAT_ID`/`D2TG_TOKEN` as an implicit trailing pair through the same grouping algorithm; refuses (dies) an exact duplicate `(chat_id, bot token)` pair (TGT-202), the same bot token configured under two different `chat_id` groups (TGT-213, since `D2TG::Store`'s offset row keys purely on the token), and a `--chat_id` value that doesn't match Telegram's own canonical chat-id shape (TGT-218). All four (TGT-267, found via TGT-266's own qa gate finding) moved here from `D2TG::Config` - CLI flag-parsing is a distinct concern from that module's own env-reading/version/error-classification concerns; no forwarder kept, every real caller (~31 files) updated to the new fully-qualified name directly. Die message text is unchanged (still prefixed `D2TG::Config::bot_groups:`, not renamed to this module), preserving byte-for-byte behavior for any caller/test matching on it. |
| `D2TG::Config::Paths` | The path/alias-resolution cluster extracted out of `D2TG::Config` (TGT-260, ~350 lines/12 subs, the single largest cohesive concern found in a 1131-line module). Resolves where every piece of this skill's state (message store, attachments, lock file, heartbeat) or a caller-supplied Developer Dashboard alias/`TIRA_HOME` lives on disk. `D2TG::Config` is the only caller in practice, via its own forwarders (11 of the 12 - `_developer_dashboard_paths` stays purely internal to this module). |
| `D2TG::Store` (continued) | `messages` table (TGT-232, found via a scheduled JOB-004 improvement hunt) now carries a `bot_key` column, migrated in place from any pre-existing table (preserving `read_at`/`local_path` data) - the sole remaining per-chat table never given the `bot_key` scoping `allow_list`/`pending`/`failed_downloads` already have, despite Telegram's own `message_id` being a per-bot counter (TGT-063) that can legitimately collide across two bots sharing a `chat_id`. `record_message`, `get_message`, `get_attachment_path`, `mark_read`, `is_read`, `unread_messages`, `recent_messages`, and `messages_in_range` all accept an optional `bot_key` (defaulting to the single-bot sentinel, matching `pending_chat_ids`/`failed_downloads`'s own established pattern); `D2TG::Poller::run_once`'s 5 `record_message` sites and 2 `get_message` sites, and `D2TG::Reply::send_reply`/`resend_voice`'s `mark_read` sites, all thread their own already-in-scope bot token through. `cli/history.pl`/`cli/unread.pl`/`cli/attachment.pl` do not yet accept a `--bot` flag to make use of this scoping - deferred to TGT-233, since none of them have any bot_key awareness in their own argv parsing today. |
| `D2TG::Telegram` | Raw HTTP Bot API client (`LWP::UserAgent`, no SDK, explicit 50s timeout - TGT-035/TGT-066, backed by a real SIGALRM-based hard timeout since a stuck TCP connect() was found to bypass it in production - TGT-044): `get_me`, `get_updates`, `get_file`, `file_download_url`, `send_message` (auto-split, optional `reply_to_message_id` - TGT-040), `send_voice` (multipart, optional `reply_to_message_id` - TGT-040), `send_photo`/`send_document` (TGT-103, multipart via a shared `_send_file` helper, optional `caption`/`reply_to_message_id`) - the outbound counterpart to `D2TG::Download`'s inbound media handling. `_send_file` escapes and sanitizes the local file's basename before inserting it into the multipart `Content-Disposition` header (TGT-125, found via a scheduled bug-hunt) - a literal double-quote previously corrupted the header, and a literal CR/LF could have injected an additional header line into the request; C0 control characters and DEL are stripped, then backslashes and quotes are escaped. `get_updates` now requests `allowed_updates` explicitly, defaulting to `[message, edited_message, message_reaction]` (`message_reaction` - TGT-143; `edited_message` - TGT-169, both live Telegram questions). `message_reaction` is genuinely opt-in - excluded from Telegram's own baseline default set even on a bot's first-ever call omitting `allowed_updates`; `edited_message` is not - that same baseline already includes it, and it only stopped reaching this project the moment `allowed_updates` was first narrowed to a fixed list at all (TGT-143). That baseline is a historical fact, not a live fallback: `getUpdates` retains whichever `allowed_updates` a bot last set rather than reverting to the baseline default if a later call omits the parameter, so omitting it now would not restore `edited_message` - it must be listed explicitly, as this default now does. Telegram's own docs warn that specifying `allowed_updates` at all restricts delivery to only the listed types, so every type this project already relies on is preserved alongside each newly-added one. `_send_file`'s `caption` field (TGT-162, found via a scheduled bug-hunt) now also conservatively strips the literal per-call multipart boundary string from itself before insertion - the same trust boundary (a user-supplied `cli/send.pl` argument) as `filename` above, but a narrower risk: caption sits in body content rather than a quoted header attribute, so it needs none of `filename`'s quote/backslash escaping or control-character stripping (CR/LF there is legitimate caption text, not a header-injection vector) - the one real risk was a caption embedding the boundary value in real delimiter syntax (`\r\n--$boundary`, not the bare value alone) prematurely terminating the multipart body. `reply_to_message_id`'s numeric validation (originally added by TGT-040/TGT-055) is shared across `send_message`/`send_voice`/`_send_file` via a private `_validate_reply_to_message_id($method, $reply_to_message_id)` helper (TGT-171, found via a scheduled improvement hunt - all 3 call sites had triplicated the same validation logic, only the method name in the die message differed, a pure extraction with no behavior change). `send_voice` and `_send_file` additionally shared the identical "validate, then if defined append a multipart form-data fragment to the body" 5-line block - extracted into `_append_reply_to_message_id_field($body_ref, $boundary, $method, $reply_to_message_id)` (TGT-182, found via a scheduled improvement hunt), taking the body by scalar ref since the caller's own `$body` must keep accumulating fragments after the call returns (the same by-reference approach `D2TG::Poller::Safe::record_message_and_track_offset` already established for TGT-181). Pure extraction, no behavior change. TGT-280 (own follow-up filed by TGT-279's survey): this module's own embedded POD (210 lines, never previously in a separate file) - the real driver of its 547-line overage, not the code itself (338 lines at the time) - was extracted to `Telegram.pod`, closing this module's own decomposition without any function-level split. The module is now 354 lines (TGT-325, found via a scheduled JOB-005 doc-accuracy hunt: later tickets, e.g. TGT-143/TGT-169's `allowed_updates` work and TGT-162's caption-boundary stripping, grew the code further without this figure being updated in the same commit - corrected against a fresh `wc -l`). TGT-328 (found via a live JOB-005 doc-accuracy hunt): `Telegram.pod`'s `send_photo`/`send_document` had two `=head2` headings in a row with no body text between them, leaving `send_photo`'s own section structurally empty (a real `podchecker` warning) - merged into one combined heading covering both signatures, matching how the shared paragraph below it already documents them together. |
| `D2TG::Poller` | `run_once` — one poll cycle: fetches updates via `$telegram->get_updates`, then for each update dispatches to one of `D2TG::Poller::Dispatch`'s 3 handler functions (`handle_message_reaction`, `handle_edited_message`, `handle_plain_update`, in that priority order) and moves to the next update - TGT-276 (filed via TGT-275's own REQ-029 audit) relocated run_once's own ~520-line branch bodies (plus their extensive historical comments) into that new module, since splitting them into same-file functions would not have reduced this module's own line count at all. The one piece of behavior that stays here, because it spans the whole batch rather than any single update (TGT-178, Michael's own architectural ruling): a handler's own non-fatal store-write failure is tracked by `update_id`, and the returned offset is capped at the first such failure instead of the batch's own full next offset - Telegram never redelivers an update once the offset has moved past it, so returning the full offset regardless would let a genuine store-write failure permanently and silently lose that message's local history. This module is now 74 lines (TGT-273 moved its own POD to `Poller.pod`; TGT-275 relocated 8 non-`run_once` helper functions to `D2TG::Poller::Safe`; TGT-276 relocated the 3 branch handlers to `D2TG::Poller::Dispatch`) - comfortably under the board's 500-line-per-module cap. See `D2TG::Poller::Safe`'s and `D2TG::Poller::Dispatch`'s own rows below for the functions that used to be documented here. |
| `D2TG::Poller::Safe` | TGT-275 (found via TGT-273's own REQ-029 audit): the 8 non-`run_once` eval-wrapped, non-fatal-degradation helper functions relocated out of `D2TG::Poller` to bring that module under the board's 500-line-per-module cap - `classify_store_error` (TGT-167, classifies a raw DBI/SQLite exception into a short fixed reason rather than ever echoing it, since it can embed the database file's own real path), `open_store_or_die` (TGT-186, shared by 8 `cli/*.pl` scripts), `run_once_safe` (TGT-028, wraps `D2TG::Poller::run_once` so a transient failure never kills the caller's loop), `record_message_safe`/`record_message_and_track_offset` (TGT-132/181, `run_once`'s own store-write-and-offset-tracking helpers), `store_write_safe` (TGT-198, the shared `is_allowed`/`add_pending`/retry-queue write wrapper also used by `D2TG::Download` and `D2TG::Transcribe::Retry`), `persist_offset_safe` (TGT-166/191, `cli/poller.pl`'s main-loop offset persistence), and `skill_version_check_safe` (TGT-175, the main-loop version-change check). TGT-314 (found via a scheduled JOB-004 improvement hunt): added a 9th helper, `die_store_error($err, $op_label)` - classifies `$err` via `classify_store_error`, prints `STORE ERROR: $op_label failed - $reason`, and exits 1 in one call, collapsing 13 near-identical inline occurrences of this exact shape (12 direct call sites across 7 `cli/*.pl` scripts, plus one inside `D2TG::RetryCli`) into a single definition. No forwarder was left in `D2TG::Poller` for any of the 8 - matching this project's zero-forwarder precedent for a small caller count; every prior caller (8 `cli/*.pl` scripts, `D2TG::Download`, `D2TG::Transcribe::Retry`, `D2TG::Reply`, and several structural-regression `t/` files) was updated to the new fully-qualified names. Full documentation lives in `D2TG/Poller/Safe.pod`. |
| `D2TG::Poller::Dispatch` | TGT-276 (filed via TGT-275's own REQ-029 audit): the 3 per-update-type branch handlers relocated out of `D2TG::Poller::run_once` - `handle_message_reaction` (TGT-143/151/154, detection/printing only, diffs Telegram's full current/previous reaction sets by type+id key), `handle_edited_message` (TGT-169/273, announces and records a text edit via `record_message`, guarded by a stored-summary comparison against a Telegram redelivery of the same edit - `get_message` presence alone doesn't work here since `record_message` already upserts a row for the ORIGINAL pre-edit send), and `handle_plain_update` (the fallback for a plain text/voice/photo/document/video message - access control via `add_pending`, the TGT-178/TGT-270 redelivery-dedup checks, voice transcription and photo/document download with their own TGT-104/TGT-204/TGT-237 failure-queuing and retry-command announcements). Every guard clause that used to be an inline `next` inside `run_once`'s own loop became a `return` inside these functions instead - `next` outside of a loop is a fatal runtime error, and a handler function has no loop of its own; `run_once`'s own dispatch loop calls `next` unconditionally right after each handler returns, since none of the 3 branches ever falls through into another. TGT-313 (found via a JOB-004 improvement hunt): `handle_plain_update`'s text and voice-success branches used to duplicate an identical-shaped `defined($message_id)`-branching announce/record block - the same duplication shape that let TGT-311's own regression (TGT-312) happen - now consolidated into one shared private helper, `_announce_and_record`, called from both branches; pure refactor, no observable stdout/store behavior change. TGT-327 (found via a live JOB-004 improvement hunt): the voice-transcription-failure and photo/document-download-failure branches shared the same duplication shape (eval-wrap a `record_failed_X` call, report queued-or-failed) - consolidated into a second shared private helper, `_queue_failed_and_report`. Full documentation lives in `D2TG/Poller/Dispatch.pod`. |
| `D2TG::Poller::Format` | The 13-sub stdout-line formatting/presentation cluster extracted out of `D2TG::Poller` (TGT-259, ~244 lines, no poll-loop state - pure functions of their inputs). Implements `display_name`, `reply_context_suffix`, `stored_summary`, `timestamp_prefix`, `sanitize_for_stdout`, `bot_flag`, `print_reply_template`, `print_attachment_template`, `reaction_key`, `reaction_label`, `forward_origin_name`, `format_forwarded_sender`, `media_kind` - unchanged in behavior from their pre-extraction selves. `print_reply_template` (TGT-322, found via a live JOB-003 hourly bug hunt) now prints `--reply-to-message-id` BEFORE `chat_id` too, matching its own existing `--bot`-before-`chat_id` convention (TGT-227) - `D2TG::Reply::Args::parse_cli_args` only recognizes the flag in that leading position now, so the printed template must match it. `D2TG::Poller::Dispatch` is now the only real caller (TGT-276 moved run_once's own branch bodies there, calling Format's bare functions directly) - `D2TG::Poller` itself keeps only one forwarder, `_bot_flag`, for its sole remaining external caller (`t/226-bot-flag-helper-extracted.t`); the other 10 forwarders TGT-259 originally kept were removed as permanently-uncallable dead code once TGT-276 moved their only caller elsewhere. `sanitize_for_stdout` (TGT-326, found via a live JOB-003 hourly bug hunt) now also strips the C1 control range (`\x7F-\x9F`, extending the prior `\x00-\x08\x0B-\x1F\x7F` strip) - `\x9B`, the 8-bit form of CSI (Control Sequence Introducer), triggers the same terminal-escape-sequence class as ESC (`\x1B`) + `[` in 7-bit form, and was reachable via arbitrary Telegram message text before this fix. |
| `D2TG::Store` | SQLite-backed allow-list/pending/offset/message-history persistence; the constructor's `DBI->connect` sets `PrintError => 0` alongside `RaiseError => 1` (TGT-316, found via a scheduled JOB-003 hourly bug hunt, reproduced live) - `RaiseError`/`PrintError` are independent DBI attributes, and DBI's own documented default for `PrintError` is `1` (true), so without this a DBI error not already inside one of `D2TG::Store::Schema`'s own local `PrintError = 0` blocks leaked a raw, unclassified exception line to STDERR before whatever classified refusal the calling code went on to print - exactly the raw-exception-leak class TGT-133/183/186/195/293/311 all exist to prevent. The constructor also sets `PRAGMA busy_timeout = 5000` and `PRAGMA journal_mode = WAL` on every connection (TGT-129, found via an ad-hoc bug-hunt) - without these, a concurrent writer (the long-running poller vs. an independently-invoked `d2 tg.*` command against the same `db_path`) got an immediate "database is locked" error instead of a brief, usually-successful wait, closing a concurrency robustness gap flagged in this project's own research notes on the original Python blueprint; `is_allowed`/`add_pending`/`approve`/the constructor's `admin_chat_id` seeding all accept an optional `bot_key` (default `DEFAULT_BOT_KEY`, a named constant currently `''`, the single-bot sentinel - TGT-101) - `allow_list`/`pending` carry a composite `(chat_id, bot_key)` PRIMARY KEY (TGT-098), migrated in place from any pre-existing single-column-PK database so a Telegram group shared by more than one configured bot can no longer have an approval leak from one bot to another; `approve` is atomic and rolls back cleanly on any failure; `record_message`/`get_message` store a short summary of each processed message keyed by chat_id+message_id (TGT-038); `record_message` also accepts an optional `local_path` (TGT-133), stored in a separate column never included in `summary` - `get_attachment_path($chat_id, $message_id)` is the only accessor that ever returns it, backing `cli/attachment.pl`; re-recording a message without a `local_path` preserves whichever one (if any) was already stored, rather than wiping it; `mark_read`/`is_read` track read/unread status, set only after a reply actually succeeds (TGT-046); `unread_messages` lists every not-yet-read message, oldest first (TGT-047; ties on the same-second `created_at` broken by `message_id` ascending, TGT-075); `recent_messages`/`messages_in_range` back `d2 tg.history`'s default-last-10 and date-range views (TGT-048; `messages_in_range` shares the same same-second `message_id` tiebreaker, TGT-075); `admin_chat_id` (constructor) also accepts an arrayref to seed multiple chat ids allowed - an arrayref element may also be a hashref `{ chat_id => ..., bot_key => ... }` to seed a specific `bot_key` per chat_id (TGT-234, found via a scheduled JOB-003 hourly bug hunt) rather than only the default sentinel, which is what `cli/poller.pl`'s real multi-bot startup now builds for every real `(chat_id, bot token)` pair it is about to poll - previously every declared admin chat_id was seeded only under the single-bot sentinel, which never matched `is_allowed`'s real per-bot check in multi-bot mode and silently locked the admin out under every non-default bot; plain scalars still seed under the sentinel exactly as before; `get_offset`/`set_offset` accept an optional per-bot key (SHA256-hashed before storage, never plaintext) for independent multi-bot offsets (TGT-049); `disconnect` closes the DB handle cleanly (used before the poller re-execs itself, TGT-036). `record_failed_download`/`failed_downloads`/`remove_failed_download` (TGT-104) persist/list/clear the retry queue for a failed inbound media download; `failed_downloads` is keyed uniquely by `(chat_id, bot_key, message_id)` (`bot_key` added by TGT-219, found via a scheduled improvement hunt - previously just `(chat_id, message_id)`, a Codex review finding that Telegram's at-least-once delivery could otherwise insert a duplicate row on redelivery, but which also silently collapsed the same message_id failing under two different bots in a multi-bot config into one row, even though Telegram's own `file_id` values are bot-token-scoped and a retry under the wrong bot could never succeed - migrated in place from any pre-existing table lacking `bot_key`, matching `allow_list`/`pending`'s own TGT-098 migration pattern), so `record_failed_download` is an upsert (`INSERT ... ON CONFLICT DO UPDATE`), refreshing an existing row's `file_id`/error/timestamp rather than duplicating it when the SAME bot redelivers; both `record_failed_download` and `failed_downloads` take an optional `bot_key` (defaulting to the single-bot sentinel; `failed_downloads` omitting it lists every bot's own entries, each row naming its own `bot_key`, matching `pending_chat_ids`' own TGT-215 pattern); ordered by `id` (not `created_at`, whose second precision isn't a reliable tiebreaker - another Codex finding). `failed_downloads` also carries a `local_path` column (TGT-196, Michael's own design choice, Q-013) via a duplicate-tolerant `ALTER TABLE` migration, and a new `mark_failed_download_downloaded($id, $local_path)` method sets it - `D2TG::Download::retry_failed_download` uses this to persist an already-successful download when only the `record_message` bookkeeping write keeps failing, so a future retry can skip re-downloading entirely. `failed_downloads_due_for_retry(bot_key => $b)`/`mark_failed_download_retried($id)` (TGT-221, Q-015 answered by Michael: retry every 60s for up to 5 minutes total) back the poller's own automatic background retry - the former selects queued rows still within a 5-minute window of their own `created_at` that haven't been attempted (via the latter, which stamps `last_retry_at`) in the last 60s; a row past the window is left queued/visible for manual `d2 tg.retry-download` recovery, not deleted - automatic retry simply stops attempting it. `failed_transcriptions_due_for_retry(bot_key => $b)`/`mark_failed_transcription_retried($id)` (TGT-246, found via a scheduled JOB-003 hourly bug hunt) mirror this same pair exactly, applied to `failed_transcriptions` instead - closing a real gap where that structurally identical queue (TGT-237, built as `failed_downloads`' own explicit sibling) never got the same automatic recovery TGT-221 gave downloads, leaving a transient transcription failure queued forever until a manual `d2 tg.retry-transcription`. `failed_transcriptions` also gained a `last_retry_at` column via the same duplicate-tolerant `ALTER TABLE` pattern. `record_failed_download`'s own id-lookup `SELECT` (TGT-225, found via a scheduled JOB-003 hourly bug hunt) now also scopes by `bot_key`, matching the `INSERT...ON CONFLICT` clause a few lines above it - previously it filtered only by `(chat_id, message_id)`, so two rows sharing that pair under different `bot_key`s could make it return the wrong row's own id (latent in production since `D2TG::Poller::run_once` discards the return value, but broke the documented public contract `t/83`/`t/196` already assert on directly in single-bot scenarios). `prune_history(retention_days => $days = 90)` (TGT-235, found via a scheduled JOB-004 improvement hunt) deletes rows older than the retention window from `messages` and `sent_replies` - neither table had any retention/eviction policy before this, unlike `D2TG::Download::prune_vault` which already caps the attachments vault's own disk usage by byte count; mirrors `prune_vault`'s own pattern (a sane hardcoded default, an optional override argument, silent no-op when nothing is past the window) and is called from `cli/poller.pl`'s per-cycle loop right after the existing `prune_vault` call, eval-wrapped so a locked/busy database can't turn this housekeeping into a poll-cycle failure. `prune_history` (TGT-238, found via a scheduled JOB-004 improvement hunt) also now sweeps `failed_downloads` and `failed_transcriptions` - neither table had any eviction path besides a successful retry, so a permanently-unretryable row (an expired Telegram `file_id`, say) would otherwise sit in the queue forever - using a separate, shorter `failed_queue_retention_days` argument (default 30 days, independent of the message-history `retention_days` above) since a stale retry-queue row is a different concern from message-history retention; no `cli/poller.pl` change was needed, since it already calls `prune_history` unconditionally. `record_sent_text`/`record_sent_voice`/`text_only_replies` (TGT-105) back the text-only-reply audit trail via a `sent_replies` table keyed by `(chat_id, bot_key, text_message_id)` - a row whose `voice_message_id` is still `NULL` IS the text-only flag; `bot_key` scoping (a Codex review finding, the same TGT-098 lesson) keeps one bot's flags from colliding with another's for a chat shared across bots; `record_sent_voice` warns on STDERR (non-fatal) rather than silently no-op'ing when no matching row exists (another Codex finding). `is_recent_duplicate_reply` (TGT-114) checks whether the exact same text was already sent to a chat/bot within a short window (default 10s, via a `text` column added to `sent_replies`) - backs `send_reply`'s own duplicate-send refusal; `window_seconds` is validated non-negative-numeric (a Codex finding); the `text` column is added via an `ALTER TABLE`-with-duplicate-tolerance migration (a Codex finding - the bare `CREATE TABLE IF NOT EXISTS` above is a no-op against a database that already has `sent_replies` from an earlier TGT-105-only install). `record_failed_download`/`failed_downloads`/`failed_downloads_due_for_retry`/`mark_failed_download_retried`/`remove_failed_download`/`mark_failed_download_downloaded`/`record_failed_transcription`/`failed_transcriptions`/`remove_failed_transcription`/`failed_transcriptions_due_for_retry`/`mark_failed_transcription_retried` (TGT-257, found via a scheduled JOB-004 improvement hunt) are now thin forwarders onto a `D2TG::Store::RetryQueue` instance built once in the constructor (same `$dbh`) - no behavior/signature change for any caller, just a smaller Store.pm. `has_failed_download`/`has_failed_transcription` (TGT-270, a live report from Michael via the budget project) are new thin forwarders backing `D2TG::Poller::run_once`'s own redelivery-dedup guard - a boolean-ish check for whether a given `(chat_id, message_id, bot_key)` already has a queued row, so a Telegram redelivery of an already-failed-and-queued update can be recognized and skipped instead of re-processed as brand new. TGT-278 (found via a wc -l sweep): the message-history methods named above (`record_message`/`get_message`/`get_attachment_path`/`mark_read`/`is_read`/`unread_messages`/`recent_messages`/`messages_in_range`) moved into a new `D2TG::Store::History` module (see its own row below), mirroring `D2TG::Store::RetryQueue`'s own precedent - unchanged in behavior, `D2TG::Store` keeps a thin forwarder for each. This module's own embedded POD also moved to `Store.pod` (never previously in a separate file). Still 720 lines after that extraction. TGT-279 (own follow-up) then extracted the access-control cluster (`is_allowed`/`add_pending`/`approve`/`pending_chat_ids`/`seed_admin`) into `D2TG::Store::AccessControl` and the sent-reply audit-trail cluster (`record_sent_text`/`record_sent_voice`/`text_only_replies`/`is_recent_duplicate_reply`) into `D2TG::Store::SentReplyAudit` (see their own rows below) - `D2TG::Store.pm` is now 248 lines (TGT-280 then extracted `_ensure_schema` itself - see `D2TG::Store::Schema`'s own row below) - comfortably under the 500-line-per-module cap, closing out this module's own decomposition chain. TGT-325 (found via a scheduled JOB-005 doc-accuracy hunt): this figure had drifted stale (documented as 232 lines) after later tickets (e.g. TGT-316's `PrintError` fix, TGT-234's `admin_chat_id` seeding) grew the module without the doc being updated in the same commit - corrected against a fresh `wc -l`. | |
| `D2TG::Store::History` | Message-history storage extracted out of `D2TG::Store` (TGT-278, found via a wc -l sweep - the largest cohesive cluster in a 1378-line module, needing only the shared `$dbh`). Wraps an already-connected DBI handle (`new(dbh => $dbh)`) and implements `record_message`/`get_message`/`get_attachment_path`/`mark_read`/`is_read`/`unread_messages`/`recent_messages`/`messages_in_range` - unchanged in behavior from their pre-extraction selves; see `D2TG::Store`'s own row above for what each does. `D2TG::Store` is the only caller in practice, via its own forwarders. `unread_messages`/`recent_messages`/`messages_in_range` (TGT-324, found via a JOB-004 improvement hunt) now share a private `_select_all_rows($self, $sql, @bind)` helper for the identical `selectall_arrayref`-then-return-list shape all three previously duplicated inline - pure extraction, no behavior change. Full documentation lives in `D2TG/Store/History.pod`. |
| `D2TG::Store::AccessControl` | Allow-list/pending-approval storage extracted out of `D2TG::Store` (TGT-279, own follow-up filed by TGT-278's survey). Wraps an already-connected DBI handle (`new(dbh => $dbh)`) and implements `is_allowed`/`add_pending`/`approve`/`pending_chat_ids`/`seed_admin` - unchanged in behavior from their pre-extraction selves; see `D2TG::Store`'s own row above for what each does (`seed_admin` is the renamed, now-public former `_seed_admin`, called by `D2TG::Store::new` for each `admin_chat_id` given to it). `D2TG::Store` is the only caller in practice, via its own forwarders. Full documentation lives in `D2TG/Store/AccessControl.pod`. |
| `D2TG::Store::Schema` | SQLite schema/migration DDL extracted out of `D2TG::Store`'s own `_ensure_schema` (TGT-280, own follow-up filed by TGT-279's survey) - a single `ensure_schema($dbh)` function rather than an object, since it has no state of its own to keep between calls, unlike the DBI-handle-wrapper clusters (RetryQueue/History/AccessControl/SentReplyAudit). Called once, synchronously, from `D2TG::Store::new` before any other storage object is built. Its own migrations are strictly order-dependent (e.g. the TGT-232 `bot_key` migration copies columns added by earlier `ALTER TABLE` calls) and must always run in the exact order they appear in the file. TGT-317 (found via a scheduled JOB-004 improvement hunt): the 6 duplicate-column-tolerant `ALTER TABLE` calls no longer each locally set `PrintError => 0` around themselves - `D2TG::Store::new`'s own connection-level default (TGT-316) already covers it, so the per-call overrides were dead weight and were removed. TGT-318 (found via a scheduled JOB-004 improvement hunt, reviewing this module after TGT-317's own cleanup of it): those same 6 call sites also duplicated the identical `eval { $dbh->do($sql) }; die $@ if $@ && $@ !~ /duplicate column name/;` shape - collapsed into a new shared `_add_column_if_missing($dbh, $sql)` helper. Full documentation lives in `D2TG/Store/Schema.pod`. |
| `D2TG::Store::SentReplyAudit` | Sent-reply audit-trail storage extracted out of `D2TG::Store` (TGT-279, own follow-up filed by TGT-278's survey). Wraps an already-connected DBI handle (`new(dbh => $dbh)`) and implements `record_sent_text`/`record_sent_voice`/`text_only_replies`/`is_recent_duplicate_reply` - unchanged in behavior from their pre-extraction selves; see `D2TG::Store`'s own row above for what each does. `D2TG::Store` is the only caller in practice, via its own forwarders. Full documentation lives in `D2TG/Store/SentReplyAudit.pod`. |
| `D2TG::Store::RetryQueue` | The `failed_downloads`/`failed_transcriptions` retry-queue storage extracted out of `D2TG::Store` (TGT-257, ~200 lines/10 subs, the largest cleanly-separable concern found in a 1528-line module). Wraps an already-connected DBI handle (`new(dbh => $dbh)`) and implements the same 10 methods listed just above, unchanged in behavior - `D2TG::Store` is the only caller in practice, via its own forwarders. `has_failed_download($chat_id, $message_id, bot_key => $b)`/`has_failed_transcription($chat_id, $message_id, bot_key => $b)` (TGT-270) run a cheap `SELECT 1 ... LIMIT 1` existence check scoped by `(chat_id, bot_key, message_id)`, defaulting `bot_key` to the single-bot sentinel like every other method here. TGT-330 (found via a live JOB-004 improvement hunt): both now forward to a shared private `_has_failed($table, $chat_id, $message_id, %args)` helper, matching this module's own established `$table`-parameterized private-helper pattern (`_due_for_retry`/`_mark_retried`/`_remove_failed`) - pure extraction, no behavior change. TGT-333 (found via a live JOB-004 improvement hunt): `failed_transcriptions` gained a `transcript` column (a duplicate-tolerant `ALTER TABLE`, mirroring `failed_downloads`' own `local_path`) and a new `mark_failed_transcription_transcribed($id, $transcript)` method - the same TGT-196 escape hatch `local_path`/`mark_failed_download_downloaded` already gave downloads, closing the one asymmetry left between the two otherwise fully-mirrored queues: `D2TG::Transcribe::Retry::retry_failed_transcription` now skips re-downloading/re-transcribing entirely once a transcript is already persisted, retrying only the still-failing `record_message` write. |
| `D2TG::TTS` | `synthesize` — text → gTTS → ffmpeg → Ogg/Opus, fatal on failure; `_run`'s subprocess output is suppressed, never leaks onto the caller's stdout/stderr (TGT-033). `synthesize_to_file` (TGT-106) wraps `synthesize` unchanged with "write to a given path, or return a sensible default" plumbing — `cli/tts.pl`'s own backing function. `_run` (TGT-127, same failure class as TGT-035/044/126) forks and execs gtts-cli/ffmpeg itself via `D2TG::Subprocess::fork_in_own_process_group` (TGT-144), under a SIGALRM hard timeout (`$D2TG::TTS::HARD_TIMEOUT`, default 60s) - a hung external command dies with a clear timeout message and has its whole process group killed, rather than blocking every outbound voice reply forever the way a bare `system()` call could. |
| `D2TG::OrDie` | `or_die($coderef, @args)` (TGT-269, found via a scheduled JOB-004 improvement hunt) — the `eval { inner_call(...) }; if ($@) { print STDERR $@; exit 1; }` idiom that `extract_bot_flag_or_die` (`D2TG::Reply::Args`), `extract_db_flag_or_die` (`D2TG::Config::Flags`), and `resolve_alias_dir_or_die`/`require_existing_base_dir_or_die` (`D2TG::Config::Paths`) each independently hand-rolled — the same duplication class TGT-172/230/236 already extracted per-caller, just never noticed at the wrapper-generator level itself. Calls `$coderef->(@args)` in `eval`; on failure prints `$@` to `STDERR` and `exit(1)`s; on success returns `wantarray`-aware (the full result list in list context, just the first value in scalar context), so both list-returning wrappers (e.g. `extract_bot_flag_or_die`) and scalar-returning ones (e.g. `resolve_alias_dir_or_die`) convert to a one-line forwarder with no caller-visible difference. Deliberately a leaf module with zero `use` dependencies on `D2TG::Config`/`D2TG::Config::Paths`/`D2TG::Reply` — `D2TG::Config` already `use`s `D2TG::Config::Paths`, so a shared helper needed by both of those plus `D2TG::Reply::Args` must live outside that whole family to avoid a circular `use`. |
| `D2TG::Subprocess` | `fork_in_own_process_group` (TGT-144, found via a scheduled improvement hunt) — the fork+setpgrp-race-closing+devnull-redirect+exec preamble D2TG::TTS::_run and D2TG::Transcribe::_run had each independently accumulated across separate Codex review rounds (TGT-127/TGT-128), extracted into one shared, tested implementation. Forks (an optional `forker` coderef for test injection, matching Transcribe's own pre-existing `$FORKER` pattern), puts the child in its own process group (both parent and child call `setpgrp`, redundantly, closing the same race both sibling modules' own reviews had already caught independently), redirects the child's STDOUT/STDERR to devnull, execs — never via a shell. `POSIX::_exit(126)` if the devnull redirect itself fails, `POSIX::_exit(127)` if exec fails - two distinguishable codes, matching TTS's own pre-extraction convention (a Codex review finding: collapsing both to one code would have been an unpromised behavior change for a ticket that guarantees a pure refactor). Each caller's own distinct wait/timeout/kill-escalation logic stays in its own module, unchanged - a deliberate design difference (TTS: `alarm`+`SIGALRM`; Transcribe: a `waitpid` poll loop, chosen so a pending signal in the caller gets a chance to run promptly), not duplication to remove. Since TGT-179, an optional `stdout => $path` param redirects the child's STDOUT to a real file instead of devnull - opt-in, every existing caller that omits it keeps the original devnull-only behavior unchanged; `D2TG::Transcribe::_probe_duration` is the one caller that needs the child's own output captured rather than discarded. |
| `D2TG::Reply` | `send_reply` — text sent first, then the voice note is synthesized and sent (TGT-083; reversed from the original voice-first order). No flag or code path skips voice, and a synthesis/`send_voice` failure still fails the whole reply loudly, but it can no longer prevent the text half from having already reached the user. Threads an optional `reply_to_message_id` through both sends for a native Telegram reply (TGT-040); given a `store` too, marks that message read only after both sends succeed (TGT-046). `format_send_error` (TGT-096) appends an explicit "try again" instruction to a `send_reply` failure's error text when it looks transient (a network timeout or a `5\d\d` status, matching `D2TG::Telegram`'s own die message shapes) - a permanent failure (bad token, invalid chat_id) is returned unchanged, with no misleading retry suggestion; `cli/reply.pl` now wraps `send_reply` in `eval` and routes any failure through this before printing to STDERR. `resend_voice` (TGT-109) - synthesizes and sends only the voice half, never calling `send_message` - recovers a reply whose text already delivered but whose voice failed, without duplicating the text; exposed as `cli/reply.pl --voice-only`. Both `send_reply` and `resend_voice` (TGT-105) also record the text-only-reply audit trail when `store` is given - `send_reply` records the text send immediately after it succeeds (before synthesis/`send_voice` can fail) and the voice send once that also succeeds; `resend_voice` clears the flag left by an earlier failed attempt on a successful recovery, given `text_message_id`/`bot_key`. The `message_id` extraction from `send_message`'s return is `eval`-guarded and skipped entirely if it fails, so a caller's `telegram` double returning any other shape (existing tests that never opt into this feature) is never broken by it - a self-caught bug during this ticket's own full-suite run. `send_reply` (TGT-114) also refuses to send at all - dies before `send_message` is ever called - when `D2TG::Store::is_recent_duplicate_reply` finds the exact same text already sent to this chat/bot within the last few seconds; only checked when `store` is given. `record_sent_text`/`record_sent_voice`/`mark_read` (TGT-192, found via a scheduled JOB-003 hourly bug hunt, the same class of issue TGT-191 just fixed) were the one `D2TG::Store` write call shape in this codebase never wrapped in `eval` - a locked/busy database at `record_sent_text` used to die raw AFTER `send_message` had already succeeded, aborting the rest of `send_reply` (skipping voice synthesis entirely) and reporting a hard failure that could suggest retrying, risking a duplicate text delivery. All 5 call sites (across `send_reply`/`resend_voice`) now go through a shared `_store_write_safe` helper - `eval`-wrapped, classified via `D2TG::Poller::Safe::classify_store_error`, logged non-fatally to STDERR as `STORE ERROR [chat_id]: ... failed - REASON` - so voice synthesis/send still runs afterward and a store-write failure specifically can no longer turn an otherwise-successful `send_reply` call into a reported hard failure (synthesis/`send_voice` themselves still fail loudly exactly as before, TGT-083's own tradeoff unchanged). A second, QA-stage Codex finding on this same fix: `$voice_result->{message_id}` must be extracted outside `_store_write_safe`'s own `eval`, not inside its closure, or a malformed (non-hashref) `$voice_result` risks being misclassified as a non-fatal `record_sent_voice failed` `STORE ERROR`. A third round on the same finding: merely `eval`-guarding that extraction is not enough either, since dereferencing a hash key off `undef` in Perl's rvalue context never actually raises an exception (`eval { undef->{key} }` leaves `$@` empty) - that `eval` could never tell a malformed (non-hashref) result apart from a well-formed hashref simply missing the key, and the malformed case was silently reported as success instead. Fixed by checking `ref($voice_result) eq 'HASH'` explicitly in both `send_reply` and `resend_voice`: a non-hashref result now dies for real - but only when a `store` was actually given (a caller that never passes `store` is unaffected either way) - matching TGT-083's "voice failures are loud, never silent" tradeoff, while a present-but-incomplete hashref (e.g. `Fake::ReplyTelegram`'s own `shapeless` option) still quietly skips just the store write with no error. A fourth round qualified the docs (the die is gated on store, not unconditional) and added `resend_voice` coverage for both shapes. A fifth round found `resend_voice`'s `mark_read` originally ran BEFORE this check, so a malformed result died only after the message was already marked read - fixed by reordering. A sixth round found the check itself was gated on `store && text_message_id` while `mark_read` is gated on the broader `store && reply_to_message_id` - a caller omitting `text_message_id` could still slip a malformed result past the check and have it marked read; fixed by checking whenever `store` is given at all, independent of `text_message_id`, in both functions. `extract_bot_flag`/`extract_bot_flag_or_die`/`parse_cli_args` (TGT-265, found via TGT-264's own qa gate finding) moved out of this module entirely - CLI argv-parsing is a distinct concern from this module's send/voice/store-write concern; see the `D2TG::Reply::Args` row below. |
| `D2TG::Reply::Args` | `extract_bot_flag(@args)` (TGT-057) parses a leading `--bot <token>` pair off the front of `@args`, returning `($bot_token, @remaining_args)`; validated via `D2TG::Config::Flags::shift_flag_value` (TGT-074): dies `--bot requires a value` if the value is missing, empty, or itself flag-like, instead of silently swallowing another flag's own name as the token - including a sole bare `--bot` with no other argument at all (TGT-264, found via a scheduled JOB-003 hourly bug hunt: the guard previously required at least 2 args before even checking, so `extract_bot_flag('--bot')` silently fell through to returning `(undef, '--bot')` instead of dying like every other malformed shape). `extract_bot_flag_or_die` (TGT-236) centralizes the eval-wrap-print-STDERR-exit-1 idiom that 9 `cli/*.pl` scripts (`history`, `attachment`, `unread`, `retry-download`, `retry-transcription`, `approve`, `send`, `reply`, `fetch` - TGT-311 added the 9th) each duplicated around `extract_bot_flag` - the exact duplication class that already caused TGT-068/074/231; `extract_bot_flag` itself is unchanged, the new helper returns whatever it returns (the bot token may be `undef`), leaving each caller's own downstream default/positional handling untouched. `parse_cli_args(@ARGV)` (TGT-042, revised by TGT-322) parses `cli/reply.pl`'s argv into `($chat_id, $text, $reply_to_message_id)`; decodes every argument as UTF-8 first (TGT-073), fixing a real bug where non-ASCII reply text (accents, CJK, emoji) arrived on Telegram as mojibake since `@ARGV`'s raw bytes were never decoded before reaching `encode_json`. `--reply-to-message-id` (TGT-322, found via a live JOB-003 hourly bug hunt) is now recognized only in the LEADING position - immediately before `chat_id` - not trailing as originally shipped by TGT-042: a reply message legitimately ending with the literal words `--reply-to-message-id <word>` used to be silently corrupted, since trailing-only recognition still scanned the very end of the free-text region. Raised as a question (Q-019) rather than reversed unilaterally, since TGT-042's trailing-only choice was itself deliberate - Michael's answer moved it to leading-only, matching `extract_bot_flag`'s own TGT-227 precedent (a leading flag never scans into free text at all, so it can never collide with it). A new shared `_extract_leading_flag_value($args, $flag)` helper (found duplicated in the same TGT-322 diff, per this project's own "found it twice, extract it" convention) now backs both `extract_bot_flag` and `parse_cli_args`'s own leading-flag recognition. A bare `--reply-to-message-id` with no value, or immediately followed by another flag, now dies `--reply-to-message-id requires a value` (matching `--bot`/`--db`'s own convention) instead of silently falling through to ordinary text. All three original functions (TGT-265, found via TGT-264's own qa gate finding) moved here from `D2TG::Reply` - CLI argv-parsing is a distinct concern from `D2TG::Reply`'s own send/voice/store-write concern, and `extract_bot_flag_or_die` was already called by 9 `cli/*.pl` scripts beyond `reply.pl`, so it wasn't really reply-specific logic either; no forwarder kept, every real caller updated to the new fully-qualified name directly. |
| `D2TG::RetryCli` | `run(%args)` (TGT-310, found via a scheduled JOB-004 improvement hunt) — the shared list/dispatch/retry/report skeleton behind both `cli/retry-download.pl` and `cli/retry-transcription.pl`, extracted after a diff of the two scripts showed 296 of ~480 total lines identical: same `--db`/`--bot`-independent argv-shape validation, same store-lookup-with-classify helper (`_list_or_die`), same `--all`/single-id dispatch, same `RETRY EXPIRED`/`RETRY FAILED`/`RETRY PARTIAL` reporting shape (TGT-247/248) - the exact duplication class `D2TG::Store::RetryQueue`'s own shared helpers already fixed at the lib layer (TGT-295), just never applied to the CLI layer above it. Parameterized by `label` (`'download'`/`'transcription'`, for every user-facing message), `list`/`retry` coderefs, a lazily-invoked `telegram_builder` coderef (called at most once, only once there's something to retry - neither pre-extraction script ever constructed `D2TG::Telegram` for a pure-listing invocation, since `D2TG::Telegram->new` dies without a token, and a caller with no token configured must still be able to list the queue), and `format_success` (the `RETRY OK` line's own trailing text, including its own separator - the two callers differ even there: `cli/retry-download.pl` uses `" - GET ATTACHMENT WITH: ..."`, TGT-146's never-leak-the-real-path convention, while `cli/retry-transcription.pl` uses `": <transcript>"` with no dash, since a transcript is text, not a path). A pure extraction - each caller's own flag-parsing preamble, `Usage:` text, and POD stay in its own script; zero behavior change, every pre-existing test for both scripts stays green unmodified. Full documentation lives in `D2TG/RetryCli.pod`. |
| `D2TG::Download` | `download_file` — any Telegram `file_id` → local file. Given a `dir` (TGT-051), the file is content-addressed by its own SHA256 hash and deduplicated; without one, an OS-temp-dir file as before. A dedup hit refreshes the existing file's modification time to now (TGT-054), so a repeatedly re-sent file counts as recently used. `prune_vault` keeps a directory at or under a byte cap (100MB default), deleting oldest-modified files first (TGT-052). `retry_failed_download` (TGT-104) retries one `D2TG::Store::failed_downloads` row - on success, restores the message into the store's own history via `record_message` before removing the queue row (a Codex review caught an earlier design only did the latter, leaving nothing for `d2 tg.history`/`d2 tg.unread` to show), passing the newly-downloaded path via `record_message`'s `local_path` argument rather than folding it into the summary text (TGT-133); on failure, returns the error and leaves the row untouched. Backs `cli/retry-download.pl`. The HTTP GET itself is now protected the same way `D2TG::Telegram`'s own Bot API calls are (TGT-126, same failure class as TGT-044): `LWP::UserAgent` gets an explicit timeout, and the request is wrapped in `D2TG::Config`'s shared `_with_hard_timeout` SIGALRM guard (TGT-173, found via a scheduled improvement hunt - both this and `D2TG::Telegram`'s own call site had each independently implemented the identical wrapper, extracted into one shared implementation with no behavior change), so a connection stuck in `connect()` dies with a clear timeout message instead of hanging the poll cycle indefinitely. `retry_failed_download`'s own `record_message`/`remove_failed_download` calls (TGT-194, found via a scheduled JOB-003 hourly bug hunt, reproduced live in a `developer-dashboard:latest` container) were the one unwrapped `D2TG::Store` write pair in this module - a locked/busy database at either one used to die raw, breaking the function's own `(1, $local_path)`/`(0, $error)` return contract even though the download itself genuinely succeeded, and crashing `cli/retry-download.pl`'s own batch loop mid-run since it has no `eval` around this call either. Both calls now `eval`-wrapped and classified via `D2TG::Poller::Safe::classify_store_error`, matching the established pattern; the reported `(1, $local_path)` success is unaffected by a bookkeeping-write failure. A Codex documentation-stage review finding: `remove_failed_download` is now deliberately only attempted when `record_message` either succeeded or wasn't needed (no `media_kind`) - removing the queue row unconditionally would leave a message with neither a queue row nor a history record on a `record_message` failure, a genuine data-retention regression worse than the pre-fix crash (which at least left the row queued, since the raw die happened before reaching `remove_failed_download`). A repo-wide sweep for this bug class done as part of that same review found one more remaining unwrapped call pair - `cli/approve.pl`'s own `approve`/`is_allowed` calls - filed separately as TGT-195 and since fixed the same way. A follow-on Codex finding on TGT-194's own fix, answered by Michael as TGT-196 (Q-013, Option A): a persistently-failing `record_message` used to make `retry_failed_download` re-download the same already-fetched file on every retry pass, forever. `retry_failed_download` now checks `$row->{local_path}` first - if already set (persisted via `D2TG::Store::mark_failed_download_downloaded` by a prior retry that downloaded successfully but then failed on `record_message`), `download_file` is skipped entirely and the persisted path is reused, retrying only the still-failing `record_message` write. `retry_failed_download`'s `record_message`/`remove_failed_download`/`mark_failed_download_downloaded` calls (TGT-198, found via a scheduled JOB-004 improvement hunt) now go through `D2TG::Poller::Safe::store_write_safe` instead of each hand-writing its own `eval`/classify/print block - a pure refactor, no behavior change, printed text unchanged. `auto_retry_failed_downloads($telegram, $store, $dir, bot_key => $b)` (TGT-221, a live budget-project incident via JOB-008 feature-request-triage, Q-015 answered by Michael: retry every 60s for up to 5 minutes total, independent of poll cadence) closes the gap TGT-204 deliberately left open - a queued failed download previously sat until a human/agent ran `d2 tg.retry-download` by hand. Selects rows via `D2TG::Store::failed_downloads_due_for_retry` and reuses `retry_failed_download` itself for the actual retry attempt (a failed attempt calls `mark_failed_download_retried` to stamp `last_retry_at`); called once per `(chat_id group, bot)` pair per poll cycle from `cli/poller.pl`'s main loop, never dies - a locked/busy database or a retry failure can't turn this into a poll-cycle failure, matching `prune_vault`/`prune_history`'s own established non-fatal call-site pattern. A row past the 5-minute window is silently skipped, not deleted - it stays fully visible/retryable via `d2 tg.unread`/`d2 tg.retry-download` exactly as before; this is additive automatic recovery, not a replacement for the manual escape hatch. `auto_retry_failed_transcriptions($telegram, $store, bot_key => $b)` (TGT-246, found via a scheduled JOB-003 hourly bug hunt) is the same closure applied to `failed_transcriptions` - `retry_failed_transcription` (TGT-237) existed but was never called automatically, only via the manual `d2 tg.retry-transcription`. Unlike its download sibling, this does not trust `retry_failed_transcription`'s own `($ok, $result)` return to decide whether to throttle - that function always returns `(1, $transcript)` once download+transcription succeed, even when the following `record_message` write then fails and the row is left queued, which would silently reintroduce TGT-244's own throttle-bypass bug; instead it checks `D2TG::Store::failed_transcriptions` directly after the attempt for whether the row still exists. Wired into `cli/poller.pl`'s main loop next to `auto_retry_failed_downloads`. `retry_failed_transcription`/`auto_retry_failed_transcriptions` (TGT-261, found via TGT-258's own module-decomposition survey) moved out of this module entirely - transcription retry is `D2TG::Transcribe`'s own domain, not the file-download module's. No forwarder kept (unlike `D2TG::Store`'s own precedent): every real caller (`cli/poller.pl`, `cli/retry-transcription.pl`, 5 test files) was updated to the new fully-qualified name directly. |
| `D2TG::Transcribe` | `transcribe` — local `whisper` CLI, refuses `*.en` models; `_run` is timeout-bounded and killable (`kill_current`, TGT-031). `select_model($duration_seconds)` (TGT-100) tiers the model by audio length as a starting-point guess - a genuinely short, parsed duration in `(0, 60]` gets `base` (TGT-251, live Telegram request from Michael - `medium` measured at ~5.6x real time made even a 30-second clip take ~168s of wall time); `<=300s` otherwise gets `medium`, `<=900s` 'small', longer 'base'; an unparsed/failed duration (undef, non-numeric, or a failed probe) is never swept into the new short-clip tier just because it coerces to 0 - it still falls back to `medium` exactly as before; `transcribe()` probes duration via `_probe_duration` (an `ffprobe` call, no shell) unless an explicit `model` argument is given. Since TGT-179 (a live hang reproduced via a stalled FIFO, found by a scheduled hourly bug hunt), `_probe_duration` no longer uses a plain blocking pipe-open with no timeout at all - it runs `ffprobe` via `D2TG::Subprocess::fork_in_own_process_group` (its new `stdout` capture support) and waits under a `waitpid(WNOHANG)` poll loop bounded by `$PROBE_TIMEOUT` (10s default), killing the process group and the direct pid on a timeout - the same pattern `_run` below already uses for whisper, chosen over a plain `alarm()`-around-a-blocking-readline because that does NOT reliably interrupt a buffered pipe read (PerlIO retries on `EINTR` without giving Perl a chance to run a deferred `SIGALRM` handler mid-read). A timed-out, missing, or corrupt-output probe all fall back to 0 duration identically (`select_model`'s 'medium' tier), exactly as a probe failure already did before this fix - a hang just no longer blocks the entire single-threaded poller indefinitely to get there. Per-host Whisper throughput varies too much for the duration guess alone to guarantee correctness (measured: `medium` at ~5.6x real time on one host, no GPU) - so `transcribe()` also automatically retries at the next faster tier (`medium` → `small` → `base`, via `_next_tier`) whenever an automatically-selected model times out, dying with `TRANSCRIBE ERROR` only if even `base` times out. An explicitly-passed `model` is never automatically retried. The per-attempt timeout itself is also duration-scaled for an automatically-selected model (TGT-140, an external review finding confirmed live by Michael - the flat 300s timeout stayed independent of `select_model`'s own duration tiering even after TGT-100 shipped): `duration * 8`, floored at `$TIMEOUT` itself (never a hard-coded constant, so a caller-configured `$TIMEOUT` is always respected as the minimum - a Codex QA-stage review finding) and capped at `max(3600, $TIMEOUT)` (so the cap can never undercut a `$TIMEOUT` configured above the default ceiling either); an explicitly-passed `model` keeps the flat `$TIMEOUT` default unchanged. `_run` (TGT-128, same failure class as TGT-035/044/126/127) puts the whisper subprocess in its own process group via `D2TG::Subprocess::fork_in_own_process_group` (TGT-144 - shared with `D2TG::TTS::_run`, which had accumulated the identical preamble independently) and signals the whole process group - plus the direct pid as a fallback - on both the `TERM` and `KILL` timeout steps, so a child process whisper itself spawns (e.g. for audio decoding) is terminated too, not left orphaned. `kill_current` (TGT-131, a consistency follow-up found via an ad-hoc bug-hunt) now signals that same process group too, not just the tracked direct pid - `cli/poller.pl`'s own SIGTERM/SIGINT shutdown handlers call `kill_current` directly, so a clean poller shutdown mid-transcription now reaches a whisper-spawned child exactly like a timeout-triggered kill already did. `retry_failed_transcription`/`auto_retry_failed_transcriptions` (TGT-261, found via TGT-258's own module-decomposition survey) moved here from `D2TG::Download`, then (TGT-263, found via TGT-261's own qa gate line-count check) moved on again into `D2TG::Transcribe::Retry` - a distinct concern from this module's core probe/transcribe/timeout logic, since both functions talk to `D2TG::Poller`/`D2TG::Download` rather than `whisper` itself. This module is now 311 lines (POD moved to `Transcribe.pod`, TGT-263's own new convention; TGT-320 added a shared `_looks_like_duration` duration-validation helper), well under the board's 500-line-per-module cap. |
| `D2TG::Transcribe::Retry` | `retry_failed_transcription($telegram, $store, $row, ua => $optional_client)` / `auto_retry_failed_transcriptions($telegram, $store, bot_key => $b, ua => $optional_client)` (TGT-263) — extracted out of `D2TG::Transcribe` (which had owned them since TGT-261) into their own module, mirroring `D2TG::Store::RetryQueue`'s own precedent (TGT-257). Behavior is unchanged from TGT-261/237/245/246/248/249: re-downloads a queued voice file transiently, re-transcribes, restores the message into store history via `record_message`, then removes the queue row - both store writes go through `D2TG::Poller::Safe::store_write_safe`; a `record_message` failure leaves the row queued rather than losing the transcript. TGT-333 (found via a live JOB-004 improvement hunt): `retry_failed_transcription` now checks `$row->{transcript}` first and skips `download_file`/`transcribe` entirely when already present (mirroring `D2TG::Download::retry_failed_download`'s own `local_path` check, TGT-196) - only the still-failing `record_message` write is retried; a `record_message` failure now also persists the transcript via `D2TG::Store::RetryQueue::mark_failed_transcription_transcribed` before leaving the row queued. `auto_retry_failed_transcriptions` is called once per `(chat_id group, bot)` pair per poll cycle from `cli/poller.pl`'s main loop. Full documentation lives in `D2TG/Transcribe/Retry.pod`. |
| `D2TG::Lock` | `acquire`/`release` — single-instance PID-file lock for `cli/poller.pl`, so a stopped/suspended or otherwise still-live previous instance never silently competes for the same bot's `getUpdates` slot (TGT-062). `acquire` re-acquiring the caller's own already-held lock (exactly what `cli/poller.pl`'s version-triggered self-restart produces every time, since `exec()` preserves the PID) returns success immediately without ever touching the lock file (TGT-102 - previously fell through into the fallback reclaim path and unlinked+recreated the file even though it wasn't stale, opening a narrow race window where an independently-started second poller could SIGKILL the legitimately self-restarting one). A lock held by a genuinely different, still-live PID is taken over "last one wins" - `SIGKILL`, then a short bounded wait for death (TGT-084). A lock naming a dead PID is reclaimed via an atomic unlink+`O_CREAT|O_EXCL` retry, never a non-atomic in-place overwrite. `release` only removes the file if it still names the caller's own PID. `is_held` (TGT-111) is a pure, read-only liveness probe for `d2 tg.status` - returns the PID of a live process matching the lock, `undef` otherwise, via a harmless `kill(0, $pid)` check (treating `EPERM` as "alive, different user" per a Codex review finding, not "dead") that never touches the lock file and never calls `acquire` (which could evict a live poller just to answer a status question). Like `acquire`'s own liveness check, this can't distinguish the original poller from an unrelated process that happens to reuse the same PID after the original died - inherent to a bare-PID lock file, not something this ticket introduces or fixes. `find_other_pollers` (TGT-113) scans `/proc/<pid>/cmdline` for other live processes whose argv matches a poller-shaped pattern, independent of the lock file entirely - a Codex review caught the first draft's unanchored substring match (joined-with-spaces cmdline) false-positiving on names like `not-a-poller.pl`/`poller.pl.bak`/`--note=poller.pl`, fixed by matching each NUL-split argv element individually against an anchored `(?:^|/)poller\.pl$` pattern; a caller-supplied `pattern`/`proc_dir` override both work for testing or a differently-named entrypoint. Report-only by design - never kills or refuses, since a cmdline match alone isn't strong enough evidence for an unprompted kill. `classify_other_poller_token` (TGT-141, an external review finding live-reproduced by a sibling project and confirmed by Michael) reads a flagged PID's own `D2TG_TOKEN` from `/proc/<pid>/environ` and compares it against the running instance's own - returns `same` (a real `getUpdates` collision, worth investigating), `different` (almost certainly a sibling project's own poller sharing this skill on the same host, not a real conflict), or `unknown` (unreadable environ, no `D2TG_TOKEN` in it, or the caller's own token itself unknown - never guessed either way). `cli/poller.pl` uses this to split its own warning: a same-token match still gets the urgent `WARNING` framing; an `unknown` classification gets its own more cautious `WARNING` (the token comparison itself couldn't be made, so it can't be ruled out); a `different` classification (TGT-250, live Telegram request from Michael, 2026-09-15 - "that is noise and confusion to the agent") prints nothing at all now, since it was confirmed benign with no action ever attached - the never-kill, report-only design itself is unchanged, only whether the confirmed-benign case reports anything. |

`cli/poller.pl`, `cli/approve.pl`, `cli/attachment.pl`, `cli/reply.pl`, `cli/send.pl`, `cli/status.pl`, `cli/unread.pl`, `cli/history.pl`, `cli/help.pl`
are the thin `d2 tg.*` entrypoints described above; each just wires the
relevant modules together.

## Troubleshooting

### `HTTP request failed (status 401 Unauthorized)`

This means **Telegram itself rejected the token** - `D2TG_TOKEN` is
wrong, was regenerated, or was revoked. It is not a code bug: confirmed
(TGT-026) by running a direct `curl
https://api.telegram.org/bot<token>/getMe` alongside `cli/poller.pl` in a
fresh `developer-dashboard:latest` container with the same token - both
fail with the identical 401, proving the code correctly surfaces
Telegram's own rejection rather than misbehaving locally.

Fix: open `@BotFather` on Telegram, `/mybots` → the bot → **API Token**
→ **Revoke current token** to get a fresh one, then update
`D2TG_TOKEN` and retry. Quick standalone check before retrying anything
else: `curl https://api.telegram.org/bot<token>/getMe` - if that alone
returns 401, the token is the problem, not this skill.

### `HTTP request failed (status 409 Conflict)`

This means **Telegram briefly saw more than one `getUpdates` consumer**
for the same bot token - not a code bug, and already handled gracefully
(logged as `POLL ERROR`, retried by `run_once_safe`, TGT-028). The
likely cause (TGT-031/TGT-032): the poller was previously stopped by
force (e.g. `kill -9`, or a terminal closed) rather than a clean
`Ctrl+C`/`SIGTERM` shutdown, leaving Telegram's long-poll connection
open a little longer on the old side while a new instance started -
briefly overlapping. Since TGT-031, `Ctrl+C`/`SIGTERM` kill any
in-flight work (including a transcription) immediately, so a clean
shutdown should no longer leave this window open. Fix/avoidance: let
the poller shut down via `Ctrl+C`/`SIGTERM` rather than force-killing
it. If 409s continue after a clean shutdown, that would point at a
second `d2 tg.poller` genuinely running somewhere else with the same
token - check for that first.

### `POLL ERROR: ...` lines on stderr, and the poller keeps running

Expected and correct (TGT-028): a transient failure inside one poll
cycle (network blip, a temporary Telegram-side error, etc.) is caught by
`run_once_safe`, logged as `POLL ERROR: <message>`, and retried after a
short backoff - the poller does not stop. If these repeat continuously
with the same message, treat it like any other error line (e.g. a
repeating "401 Unauthorized" `POLL ERROR` means the token problem above,
not a new bug).

### `cpan-audit` reports HTTP::Tiny CVEs

Expected (TGT-222, found via a vulnerability-scan gate): `cpan-audit
deps .` flags 2 CVEs against `HTTP::Tiny` (CRLF injection,
cross-origin credential forwarding on redirect). This project's own
HTTP transport is exclusively `LWP::UserAgent` (`D2TG::Telegram`,
`D2TG::Download`) - `HTTP::Tiny` is a core Perl module the audit tool
sees installed on the system, never a dependency this project declares
or calls, so neither CVE's vulnerable code path is reachable through
this codebase. Documented as an accepted, non-applicable finding in
`docs/POLICIES.md`'s own TGT-222 section; `t/222-no-http-tiny-usage.t`
guards against a future change accidentally introducing a direct
`HTTP::Tiny` call.

### A shipped ticket's fix write-up is missing from README.md

Should not happen (TGT-228, found via a scheduled JOB-005 doc-accuracy
hunt): `README.md`'s own top-of-file rolling changelog convention
(each shipped ticket adds its own paragraph, newest bolded as
`**Status:**`, older ones retained below) was silently broken for 5
consecutive commits when each one's documentation-column edit REPLACED
the prior ticket's paragraph instead of prepending above it - always
edit `README.md` by prepending a NEW paragraph above the current
`**Status:**` line and demoting the old `**Status:**` paragraph to a
plain paragraph, never by replacing the existing top paragraph's own
text. `t/228-readme-ticket-history-not-lost.t` now catches a future
recurrence of this specific mistake mechanically.
