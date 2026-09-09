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
the `SYNOPSIS`), now fixed.

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
a different or unreadable token gets a reassuring `NOTE` instead, naming
a sibling project's own poller on the same host as the likely
explanation - previously every poller-shaped process was warned about
identically, which fired routinely and alarmingly for the single most
common, entirely benign case on a host running several projects from
this skill.

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
trailing pair (see `D2TG::Config::bot_groups`'s own POD for the full
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
independently of the env var). Also acquires an exclusive lock
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
no `Changes` entry or the file can't be read.

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

- `NEW TG [chat_id] sender: text` — an allowed sender's text message.
  Every content line (this one and the two below) also names the
  message's own `message_id` as `(msg #N)` (TGT-040), so it can be passed
  to `d2 tg.reply --reply-to-message-id N` for a genuine Telegram-native
  threaded reply.
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
- `NEW TG VOICE [chat_id] sender: <transcript>` — an allowed sender's
  voice message, downloaded and transcribed via a local Whisper install
  (the downloaded audio itself is not kept, only its transcript).
  `<transcript>` is sanitized the same way inbound text is (TGT-039): any
  newline whisper's own multi-segment output may contain becomes a
  literal `\n`, so this is always exactly one stdout line even for a
  transcript that spans multiple sentences/segments.
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

## `d2 tg.approve <chat_id> [--db <alias> | -d <alias>] [--bot <token>]`

Moves `chat_id` from pending into the allow-list. Prints `Approved N`
and exits 0 on success. Exits 1 (message on STDERR) if `chat_id` was
already allowed under the resolved bot, or was never pending under it at
all. `--db`/`-d` (TGT-051) resolves the same way `d2 tg.poller`'s does.

`--bot <token>` (TGT-098) scopes the approval to that bot - the same
leading-position shape as `d2 tg.reply`'s own `--bot` (TGT-057).
Omitting it approves under the single-bot sentinel, unchanged from
before this ticket for every existing single-bot install. Only needed
when a Telegram *group* is shared by more than one of this skill's
configured bots - a group's `chat_id` is the same for every bot that's
a member of it (unlike a private chat's, which Telegram allocates
uniquely per bot), so without `--bot` an approval could otherwise leak
from one bot to another.

## `d2 tg.reply [--db <alias> | -d <alias>] [--bot <token>] [--voice-only] <chat_id> <text...> [--reply-to-message-id <id>]`

(`--reply-to-message-id`, when given, must be the last two arguments -
see below; `--db`/`-d`, `--bot`, and `--voice-only` are the opposite -
recognized only in the *leading* position, before `chat_id`, for the
same collision-avoidance reason, and in any order relative to each
other)

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
following it is rejected with the usual `Usage` error instead of
hanging (TGT-068, a real live-reproduced infinite loop before this fix).
`--bot` immediately followed by another flag (e.g. `--bot --db myalias`)
is also rejected (TGT-074, same bug class as `--db`'s own case above):
it dies with a clear `--bot requires a value` message instead of
silently treating that flag's own name as the bot token.

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
via `sendDocument` regardless of what it actually contains.

`--db`/`-d` is recognized anywhere in the argument list (TGT-124, found
via a scheduled improvement-hunt) - it used to be hand-parsed in a loop
that stopped at the first non-flag token, so `d2 tg.send <chat_id>
<file> --db myalias` refused with a bogus Usage error instead of
resolving `--db` from its trailing position; now matches every other
`d2 tg.*` command's own `D2TG::Config::extract_db_flag` behavior.
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

`--db`/`-d` uses the same shared `D2TG::Config::extract_db_flag` every
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
other `d2 tg.*` command.

## `d2 tg.status [--db <alias> | -d <alias>]`

`--db`/`-d` uses the same shared `D2TG::Config::extract_db_flag` every
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
<N>s ago (STALE)` past 1200 seconds (TGT-116, a live-experienced
incident: a poller stayed alive and held its lock for 80+ minutes while
doing nothing at all, silently losing a message - "alive" and "still
genuinely cycling" are different questions). The heartbeat is written by
`cli/poller.pl` after each bot/chat pair's own poll cycle (not once per
full multi-pair cycle - a Codex review caught that the latter, against a
tighter 600s threshold, could falsely flag a healthy poller as stale
during a single slow voice transcription's full retry ladder, up to
~900s), atomically (temp file + `rename`) via
`D2TG::Config::write_heartbeat`. Automatic restart-on-stale is
intentionally not built - a genuinely stuck poller cannot restart
itself, so that needs either a second always-running watchdog process or
a Tira-scheduled job to do the restarting, an operational decision
flagged as a follow-up rather than built unilaterally.

## `d2 tg.unread [--db <alias> | -d <alias>]`

Lists every stored message (TGT-038) not yet marked read (TGT-046),
oldest first: chat id, message id, sender, timestamp, and the stored
summary. Prints `No unread messages.` and exits 0 when there are none,
rather than a blank/confusing output. `--db`/`-d` (TGT-051) resolves
the same way `d2 tg.poller`'s does. The summary text for a downloaded
photo/document never contains its real local filesystem path (TGT-133)
- fetch the actual bytes via `d2 tg.attachment`, below.

## `d2 tg.attachment <chat_id> <message_id> [--db <alias> | -d <alias>]`

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
(exit 2, Usage) if `chat_id`/`message_id` are missing or not numeric.
`--db`/`-d` (TGT-051) resolves the same way `d2 tg.poller`'s does.

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

## `d2 tg.retry-download [--db <alias> | -d <alias>] [<id> | --all]`

TGT-104 (user-supplied feature-gap analysis): `d2 tg.poller` now
attempts to persist each failed inbound photo/document download
(chat_id, message_id, file_id, sender, media kind, caption, the
original error) to `D2TG::Store`'s `failed_downloads` queue instead of
only printing a `MEDIA DOWNLOAD ERROR` line and forgetting it - useful
because a transient failure (a network hiccup mid-transfer, a momentary
server error) is genuinely recoverable on retry. A queue-write failure
itself is non-fatal, matching the download failure it's recording (a
Codex review finding), and simply leaves that one download unqueued.
The queue is keyed uniquely by `(chat_id, message_id)`, so Telegram's
own at-least-once delivery redelivering the same failed update
refreshes the existing row rather than duplicating it (another Codex
finding).

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

## `d2 tg.history [--since <iso8601>] [--until <iso8601>] [--db <alias> | -d <alias>]`

Lists stored messages (TGT-038) oldest first: chat id, message id,
sender, timestamp, and the stored summary. Without `--since`/`--until`
(TGT-048), shows the 10 most recent messages. With either or both given
(ISO 8601 timestamps, matching `created_at`'s own stored format), shows
every message in that range instead - an open-ended range on whichever
side is omitted. Prints `No messages found.` and exits 0 when nothing
matches. `--db`/`-d` (TGT-051) resolves the same way `d2 tg.poller`'s
does. `--since`/`--until` with no value following it (or immediately
followed by the other flag) exits 2 with a clear message instead of
silently running unscoped or matching nothing (TGT-070). Any other
unrecognized flag or leftover positional argument also exits 2 with a
`Usage:` message (TGT-122, found via a scheduled bug-hunt) - previously
silently ignored, exiting 0 as if the (mistyped) invocation had
succeeded - reproduced as `No messages found.` when nothing happened
to match, but a query that happened to match real history would print
it, unrelated to the actual (bad) invocation.

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
| `D2TG::Config` | Reads `D2TG_TOKEN`/`D2TG_CHAT_ID`; startup guard; resolves `state/store.sqlite`'s path (or, for a resolved `--db`/`-d`/`D2TG_DB`/`TIRA_HOME` base_dir, `.tira/telegram.messages.db` and `.tira/attachments/` - TGT-081); `skill_version` reads `.env`'s installed VERSION (TGT-036); `masked_token` masks a token to its first/last 4 chars for safe display (TGT-045); `owner_name` reads `D2TG_OWNER` (TGT-079); `extract_db_flag`/`resolve_alias_dir`/`attachments_dir` resolve an optional `--db`/`-d`/`D2TG_DB` Developer Dashboard path alias (or a `TIRA_HOME` fallback, TGT-081) for both storage and attachments (TGT-051); `bot_groups` parses repeatable `--chat_id`/`--bot` CLI args, folding in `D2TG_CHAT_ID`/`D2TG_TOKEN` as an implicit trailing pair through the same grouping algorithm (TGT-049); `shift_flag_value` (TGT-072) is a shared helper backing `extract_db_flag`'s `--db`/`-d`, `bot_groups`'s `--chat_id` and (TGT-074) `--bot`, `cli/reply.pl`'s own `--db`, `cli/history.pl`'s `--since`/`--until`, and `D2TG::Reply::extract_bot_flag`'s `--bot` validation - one implementation instead of many independent hand-rolled copies; `lock_path` resolves `cli/poller.pl`'s single-instance lock file path, mirroring `state_db_path`/`attachments_dir`'s own base_dir/`.tira/` resolution exactly (`.tira/telegram.pid` for a resolved base_dir, TGT-087); `require_existing_base_dir` (TGT-090) dies if the resolved base_dir doesn't already exist on disk - called by every `cli/*` script right after `resolve_alias_dir`, so a bogus `TIRA_HOME`/alias target is refused instead of silently `mkdir -p`'d into existence; `resolve_self_exec_path` (TGT-094) checks whether a given basename (`poller.pl`) exists in a given bin directory, returning that fresh path if so and a supplied fallback otherwise - `cli/poller.pl`'s version-change restart uses this instead of blindly `exec()`ing the literal `$0` path captured at launch, so a running poller survives an install that renames its own entrypoint file out from under it; `is_transient_error` (TGT-097) classifies an error message as transient (matches `/timed out/i` or `/status 5\d\d/`) or not - a shared predicate now used by both `D2TG::Reply::format_send_error` (TGT-096) and `D2TG::Poller::run_once_safe` (TGT-097), avoiding duplicated regex. `heartbeat_path`/`write_heartbeat`/`heartbeat_age` (TGT-116) mirror `lock_path`'s own `.tira/` resolution exactly (`.tira/telegram.heartbeat` for a resolved base_dir) - the poller writes a heartbeat after each bot/chat pair's own poll cycle, unconditionally, atomically (temp file + `rename`, so a concurrent reader or a crash mid-write never observes a partial file), so `d2 tg.status` can distinguish "still genuinely cycling" from "alive but silently wedged". `is_expired_file_error` (TGT-104) classifies an error as Telegram's own shape for a permanently-gone `file_id` (`/file is no longer available/i` or `/wrong file_id/i`) - deliberately NOT "file is temporarily unavailable" (a Codex review caught an earlier draft treating that transient-sounding wording as permanent, when it can still succeed on a later retry); backs `cli/retry-download.pl`'s `RETRY EXPIRED` vs `RETRY FAILED` distinction. |
| `D2TG::Telegram` | Raw HTTP Bot API client (`LWP::UserAgent`, no SDK, explicit 50s timeout - TGT-035/TGT-066, backed by a real SIGALRM-based hard timeout since a stuck TCP connect() was found to bypass it in production - TGT-044): `get_me`, `get_updates`, `get_file`, `file_download_url`, `send_message` (auto-split, optional `reply_to_message_id` - TGT-040), `send_voice` (multipart, optional `reply_to_message_id` - TGT-040), `send_photo`/`send_document` (TGT-103, multipart via a shared `_send_file` helper, optional `caption`/`reply_to_message_id`) - the outbound counterpart to `D2TG::Download`'s inbound media handling. `_send_file` escapes and sanitizes the local file's basename before inserting it into the multipart `Content-Disposition` header (TGT-125, found via a scheduled bug-hunt) - a literal double-quote previously corrupted the header, and a literal CR/LF could have injected an additional header line into the request; C0 control characters and DEL are stripped, then backslashes and quotes are escaped. |
| `D2TG::Poller` | `run_once` — one poll cycle: access-control gate (its `is_allowed`/`add_pending` calls pass the pair's own `bot_token` through as the store's `bot_key`, TGT-098 - so a multi-bot config's per-bot access scoping is enforced on the inbound side too, not just at `cli/approve`), text/voice/media event lines (sanitized to always be a single stdout line, even a multi-segment voice transcript - TGT-039; naming the message's own `message_id` - TGT-040; plus a `(replying to ... [msg #N]: ...)` suffix when the message is itself a reply, naming the original message's own id (TGT-041) and preferring our own stored message history over Telegram's bare payload - TGT-029/TGT-038), the `REPLY WITH` template (now including `--reply-to-message-id` - TGT-040), non-fatal error handling for voice/media, a specific error for files over Telegram's 20MB `getFile` limit (TGT-037); before a voice message's (potentially multi-minute, blocking) transcription attempt, prints a `NEW TG VOICE [chat_id] sender: transcribing... (this may take a few minutes)` notice so the watching agent notices immediately instead of the whole wait being silent (TGT-100, live user request). `run_once_safe` wraps it so a failure is retried after a short backoff instead of killing the poller (TGT-028); a known-transient failure (network timeout, 5xx status) retries silently with no STDERR output, while a genuinely unexpected/non-transient failure is still logged as `POLL ERROR` (TGT-097, via `D2TG::Config::is_transient_error`). A media download failure, when a store is present, is also queued via `D2TG::Store::record_failed_download` (TGT-104) for later retry - wrapped in its own `eval` (a Codex review finding: a locked/full SQLite database must not turn an already-non-fatal download error into a poll-cycle failure). A downloaded photo/document's real local path is never printed (TGT-133) - `_print_attachment_template` prints a `GET ATTACHMENT WITH: d2 tg.attachment <chat_id> <message_id>` instruction instead, and `record_message` receives the path separately via its own `local_path` argument, never folded into the printed/stored summary text. All 4 `record_message` call sites (text/voice/media/fallback) go through a private `_record_message_safe` eval-wrapper (TGT-132, found via an ad-hoc bug-hunt) matching `record_failed_download`'s own established pattern - a store write failure is logged non-fatally to STDERR instead of aborting `run_once`, which would otherwise make `run_once_safe` redeliver and reprint the entire batch next cycle. A forwarded message's sender name now also names the original author, not just the forwarder (TGT-142, a live question answered by Michael) - `_forward_origin_name` reads Telegram's own `forward_origin` field (all 4 `MessageOrigin` types: a real user by name never id, a privacy-restricted user's Telegram-supplied name only, or the originating chat/channel), applied to both the main sender line and `_reply_context_suffix`'s own `$original_sender`; a non-forwarded message is unaffected. |
| `D2TG::Store` | SQLite-backed allow-list/pending/offset/message-history persistence; the constructor now sets `PRAGMA busy_timeout = 5000` and `PRAGMA journal_mode = WAL` on every connection (TGT-129, found via an ad-hoc bug-hunt) - without these, a concurrent writer (the long-running poller vs. an independently-invoked `d2 tg.*` command against the same `db_path`) got an immediate "database is locked" error instead of a brief, usually-successful wait, closing a concurrency robustness gap flagged in this project's own research notes on the original Python blueprint; `is_allowed`/`add_pending`/`approve`/the constructor's `admin_chat_id` seeding all accept an optional `bot_key` (default `DEFAULT_BOT_KEY`, a named constant currently `''`, the single-bot sentinel - TGT-101) - `allow_list`/`pending` carry a composite `(chat_id, bot_key)` PRIMARY KEY (TGT-098), migrated in place from any pre-existing single-column-PK database so a Telegram group shared by more than one configured bot can no longer have an approval leak from one bot to another; `approve` is atomic and rolls back cleanly on any failure; `record_message`/`get_message` store a short summary of each processed message keyed by chat_id+message_id (TGT-038); `record_message` also accepts an optional `local_path` (TGT-133), stored in a separate column never included in `summary` - `get_attachment_path($chat_id, $message_id)` is the only accessor that ever returns it, backing `cli/attachment.pl`; re-recording a message without a `local_path` preserves whichever one (if any) was already stored, rather than wiping it; `mark_read`/`is_read` track read/unread status, set only after a reply actually succeeds (TGT-046); `unread_messages` lists every not-yet-read message, oldest first (TGT-047; ties on the same-second `created_at` broken by `message_id` ascending, TGT-075); `recent_messages`/`messages_in_range` back `d2 tg.history`'s default-last-10 and date-range views (TGT-048; `messages_in_range` shares the same same-second `message_id` tiebreaker, TGT-075); `admin_chat_id` (constructor) also accepts an arrayref to seed multiple chat ids allowed; `get_offset`/`set_offset` accept an optional per-bot key (SHA256-hashed before storage, never plaintext) for independent multi-bot offsets (TGT-049); `disconnect` closes the DB handle cleanly (used before the poller re-execs itself, TGT-036). `record_failed_download`/`failed_downloads`/`remove_failed_download` (TGT-104) persist/list/clear the retry queue for a failed inbound media download; `failed_downloads` is keyed uniquely by `(chat_id, message_id)` (a Codex review finding - Telegram's at-least-once delivery could otherwise insert a duplicate row on redelivery), so `record_failed_download` is an upsert (`INSERT ... ON CONFLICT DO UPDATE`), refreshing an existing row's `file_id`/error/timestamp rather than duplicating it; ordered by `id` (not `created_at`, whose second precision isn't a reliable tiebreaker - another Codex finding). `record_sent_text`/`record_sent_voice`/`text_only_replies` (TGT-105) back the text-only-reply audit trail via a `sent_replies` table keyed by `(chat_id, bot_key, text_message_id)` - a row whose `voice_message_id` is still `NULL` IS the text-only flag; `bot_key` scoping (a Codex review finding, the same TGT-098 lesson) keeps one bot's flags from colliding with another's for a chat shared across bots; `record_sent_voice` warns on STDERR (non-fatal) rather than silently no-op'ing when no matching row exists (another Codex finding). `is_recent_duplicate_reply` (TGT-114) checks whether the exact same text was already sent to a chat/bot within a short window (default 10s, via a `text` column added to `sent_replies`) - backs `send_reply`'s own duplicate-send refusal; `window_seconds` is validated non-negative-numeric (a Codex finding); the `text` column is added via an `ALTER TABLE`-with-duplicate-tolerance migration (a Codex finding - the bare `CREATE TABLE IF NOT EXISTS` above is a no-op against a database that already has `sent_replies` from an earlier TGT-105-only install). |
| `D2TG::TTS` | `synthesize` — text → gTTS → ffmpeg → Ogg/Opus, fatal on failure; `_run`'s subprocess output is suppressed, never leaks onto the caller's stdout/stderr (TGT-033). `synthesize_to_file` (TGT-106) wraps `synthesize` unchanged with "write to a given path, or return a sensible default" plumbing — `cli/tts.pl`'s own backing function. `_run` (TGT-127, same failure class as TGT-035/044/126) now forks and execs gtts-cli/ffmpeg itself, in their own process group (both parent and child call `setpgrp` on it immediately after `fork`, closing a race a Codex review caught between the child's own `setpgrp` and a timeout that could otherwise fire first), under a SIGALRM hard timeout (`$D2TG::TTS::HARD_TIMEOUT`, default 60s) - a hung external command dies with a clear timeout message and has its whole process group killed, rather than blocking every outbound voice reply forever the way a bare `system()` call could. |
| `D2TG::Reply` | `send_reply` — text sent first, then the voice note is synthesized and sent (TGT-083; reversed from the original voice-first order). No flag or code path skips voice, and a synthesis/`send_voice` failure still fails the whole reply loudly, but it can no longer prevent the text half from having already reached the user. Threads an optional `reply_to_message_id` through both sends for a native Telegram reply (TGT-040); given a `store` too, marks that message read only after both sends succeed (TGT-046). `parse_cli_args` — parses `cli/reply.pl`'s argv, recognizing `--reply-to-message-id` only in trailing position (TGT-042); decodes every argument as UTF-8 first (TGT-073), fixing a real bug where non-ASCII reply text (accents, CJK, emoji) arrived on Telegram as mojibake since `@ARGV`'s raw bytes were never decoded before reaching `encode_json`. `format_send_error` (TGT-096) appends an explicit "try again" instruction to a `send_reply` failure's error text when it looks transient (a network timeout or a `5\d\d` status, matching `D2TG::Telegram`'s own die message shapes) - a permanent failure (bad token, invalid chat_id) is returned unchanged, with no misleading retry suggestion; `cli/reply.pl` now wraps `send_reply` in `eval` and routes any failure through this before printing to STDERR. `resend_voice` (TGT-109) - synthesizes and sends only the voice half, never calling `send_message` - recovers a reply whose text already delivered but whose voice failed, without duplicating the text; exposed as `cli/reply.pl --voice-only`. Both `send_reply` and `resend_voice` (TGT-105) also record the text-only-reply audit trail when `store` is given - `send_reply` records the text send immediately after it succeeds (before synthesis/`send_voice` can fail) and the voice send once that also succeeds; `resend_voice` clears the flag left by an earlier failed attempt on a successful recovery, given `text_message_id`/`bot_key`. The `message_id` extraction from `send_message`'s return is `eval`-guarded and skipped entirely if it fails, so a caller's `telegram` double returning any other shape (existing tests that never opt into this feature) is never broken by it - a self-caught bug during this ticket's own full-suite run. `send_reply` (TGT-114) also refuses to send at all - dies before `send_message` is ever called - when `D2TG::Store::is_recent_duplicate_reply` finds the exact same text already sent to this chat/bot within the last few seconds; only checked when `store` is given. |
| `D2TG::Download` | `download_file` — any Telegram `file_id` → local file. Given a `dir` (TGT-051), the file is content-addressed by its own SHA256 hash and deduplicated; without one, an OS-temp-dir file as before. A dedup hit refreshes the existing file's modification time to now (TGT-054), so a repeatedly re-sent file counts as recently used. `prune_vault` keeps a directory at or under a byte cap (100MB default), deleting oldest-modified files first (TGT-052). `retry_failed_download` (TGT-104) retries one `D2TG::Store::failed_downloads` row - on success, restores the message into the store's own history via `record_message` before removing the queue row (a Codex review caught an earlier design only did the latter, leaving nothing for `d2 tg.history`/`d2 tg.unread` to show), passing the newly-downloaded path via `record_message`'s `local_path` argument rather than folding it into the summary text (TGT-133); on failure, returns the error and leaves the row untouched. Backs `cli/retry-download.pl`. The HTTP GET itself is now protected the same way `D2TG::Telegram`'s own Bot API calls are (TGT-126, same failure class as TGT-044): `LWP::UserAgent` gets an explicit timeout, and the request is wrapped in a private `_with_hard_timeout` SIGALRM guard, so a connection stuck in `connect()` dies with a clear timeout message instead of hanging the poll cycle indefinitely. |
| `D2TG::Transcribe` | `transcribe` — local `whisper` CLI, refuses `*.en` models; `_run` is timeout-bounded and killable (`kill_current`, TGT-031). `select_model($duration_seconds)` (TGT-100) tiers the model by audio length - `<=300s` 'medium', `<=900s` 'small', longer 'base' - as a starting-point guess; `transcribe()` probes duration via `_probe_duration` (an `ffprobe` list-form pipe open, no shell) unless an explicit `model` argument is given. Per-host Whisper throughput varies too much for the duration guess alone to guarantee correctness (measured: `medium` at ~5.6x real time on one host, no GPU) - so `transcribe()` also automatically retries at the next faster tier (`medium` → `small` → `base`, via `_next_tier`) whenever an automatically-selected model times out, dying with `TRANSCRIBE ERROR` only if even `base` times out. An explicitly-passed `model` is never automatically retried. The per-attempt timeout itself is also duration-scaled for an automatically-selected model (TGT-140, an external review finding confirmed live by Michael - the flat 300s timeout stayed independent of `select_model`'s own duration tiering even after TGT-100 shipped): `duration * 8`, floored at `$TIMEOUT` itself (never a hard-coded constant, so a caller-configured `$TIMEOUT` is always respected as the minimum - a Codex QA-stage review finding) and capped at `max(3600, $TIMEOUT)` (so the cap can never undercut a `$TIMEOUT` configured above the default ceiling either); an explicitly-passed `model` keeps the flat `$TIMEOUT` default unchanged. `_run` (TGT-128, same failure class as TGT-035/044/126/127) now puts the whisper subprocess in its own process group (both parent and child call `setpgrp` immediately after `fork`, closing the same race the sibling `D2TG::TTS` fix's own review caught) and signals the whole process group - plus the direct pid as a fallback - on both the `TERM` and `KILL` timeout steps, so a child process whisper itself spawns (e.g. for audio decoding) is terminated too, not left orphaned. `kill_current` (TGT-131, a consistency follow-up found via an ad-hoc bug-hunt) now signals that same process group too, not just the tracked direct pid - `cli/poller.pl`'s own SIGTERM/SIGINT shutdown handlers call `kill_current` directly, so a clean poller shutdown mid-transcription now reaches a whisper-spawned child exactly like a timeout-triggered kill already did. |
| `D2TG::Lock` | `acquire`/`release` — single-instance PID-file lock for `cli/poller.pl`, so a stopped/suspended or otherwise still-live previous instance never silently competes for the same bot's `getUpdates` slot (TGT-062). `acquire` re-acquiring the caller's own already-held lock (exactly what `cli/poller.pl`'s version-triggered self-restart produces every time, since `exec()` preserves the PID) returns success immediately without ever touching the lock file (TGT-102 - previously fell through into the fallback reclaim path and unlinked+recreated the file even though it wasn't stale, opening a narrow race window where an independently-started second poller could SIGKILL the legitimately self-restarting one). A lock held by a genuinely different, still-live PID is taken over "last one wins" - `SIGKILL`, then a short bounded wait for death (TGT-084). A lock naming a dead PID is reclaimed via an atomic unlink+`O_CREAT|O_EXCL` retry, never a non-atomic in-place overwrite. `release` only removes the file if it still names the caller's own PID. `is_held` (TGT-111) is a pure, read-only liveness probe for `d2 tg.status` - returns the PID of a live process matching the lock, `undef` otherwise, via a harmless `kill(0, $pid)` check (treating `EPERM` as "alive, different user" per a Codex review finding, not "dead") that never touches the lock file and never calls `acquire` (which could evict a live poller just to answer a status question). Like `acquire`'s own liveness check, this can't distinguish the original poller from an unrelated process that happens to reuse the same PID after the original died - inherent to a bare-PID lock file, not something this ticket introduces or fixes. `find_other_pollers` (TGT-113) scans `/proc/<pid>/cmdline` for other live processes whose argv matches a poller-shaped pattern, independent of the lock file entirely - a Codex review caught the first draft's unanchored substring match (joined-with-spaces cmdline) false-positiving on names like `not-a-poller.pl`/`poller.pl.bak`/`--note=poller.pl`, fixed by matching each NUL-split argv element individually against an anchored `(?:^|/)poller\.pl$` pattern; a caller-supplied `pattern`/`proc_dir` override both work for testing or a differently-named entrypoint. Report-only by design - never kills or refuses, since a cmdline match alone isn't strong enough evidence for an unprompted kill. `classify_other_poller_token` (TGT-141, an external review finding live-reproduced by a sibling project and confirmed by Michael) reads a flagged PID's own `D2TG_TOKEN` from `/proc/<pid>/environ` and compares it against the running instance's own - returns `same` (a real `getUpdates` collision, worth investigating), `different` (almost certainly a sibling project's own poller sharing this skill on the same host, not a real conflict), or `unknown` (unreadable environ, no `D2TG_TOKEN` in it, or the caller's own token itself unknown - never guessed either way). `cli/poller.pl` uses this to split its own warning: a same-token match still gets the urgent `WARNING` framing, everything else gets a reassuring `NOTE` naming the sibling-project explanation - the never-kill, report-only design itself is unchanged. |

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
