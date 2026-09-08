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

`--help`/`-h` (TGT-107, a live-experienced incident) prints a short
usage summary and exits 0 - checked before anything else, including
before `--db`/`-d` is parsed. Any OTHER unrecognized argument refuses
(STDERR names the specific token, exit 1) before the storage
location/lock are ever touched - previously, an unrecognized flag
(including `--help` itself) was silently accepted and the process fell
through into a real poll loop, which, per this skill's own "last one
wins" lock (TGT-084), could `SIGKILL` a live, legitimate poller by
typo. Every previously-recognized flag below is unchanged.

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

Self-refreshes on a new install (TGT-036): after each poll cycle, it
compares its own on-disk `VERSION` against the one it started with. If
`dashboard skills install tg` has installed a newer version in the
meantime, it prints a notice and re-execs itself in place (same PID) -
no manual restart needed to pick up a new release.

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
- `NEW TG MEDIA [chat_id] sender: <photo|document> <local_path> [- caption: <text>]` —
  an allowed sender's photo/document message, downloaded to `local_path`.
  For a photo, the largest available resolution is downloaded.
  `local_path` is content-addressed (TGT-051, named by the file's own
  SHA256 hash) under `D2TG::Config::attachments_dir` - identical content
  downloaded any number of times, from any sender, only ever occupies
  one copy of disk space. If the sender attached a caption to the photo/
  document (TGT-092, a live production incident: a caption was silently
  dropped before this fix, causing a real miscommunication), it's
  appended as `- caption: <text>`, sanitized the same way inbound text is
  (TGT-039); omitted entirely when there is no caption, which is the
  common case.
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
previously downloaded document shows its actual `local_path`, and a
reply to a previously transcribed voice note shows its actual
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

Voice transcription is bounded by `$D2TG::Transcribe::TIMEOUT` (default
300s, TGT-031): if `whisper` runs longer than that, it is killed and a
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
`format_send_error` path as the normal send.

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
this command.

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

`--db`/`-d` and `--bot` match `d2 tg.reply`'s own leading-position shape
and validation. `--caption <text>` is optional free text attached to the
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

## `d2 tg.unread [--db <alias> | -d <alias>]`

Lists every stored message (TGT-038) not yet marked read (TGT-046),
oldest first: chat id, message id, sender, timestamp, and the stored
summary. Prints `No unread messages.` and exits 0 when there are none,
rather than a blank/confusing output. `--db`/`-d` (TGT-051) resolves
the same way `d2 tg.poller`'s does.

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
silently running unscoped or matching nothing (TGT-070).

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
| `D2TG::Config` | Reads `D2TG_TOKEN`/`D2TG_CHAT_ID`; startup guard; resolves `state/store.sqlite`'s path (or, for a resolved `--db`/`-d`/`D2TG_DB`/`TIRA_HOME` base_dir, `.tira/telegram.messages.db` and `.tira/attachments/` - TGT-081); `skill_version` reads `.env`'s installed VERSION (TGT-036); `masked_token` masks a token to its first/last 4 chars for safe display (TGT-045); `owner_name` reads `D2TG_OWNER` (TGT-079); `extract_db_flag`/`resolve_alias_dir`/`attachments_dir` resolve an optional `--db`/`-d`/`D2TG_DB` Developer Dashboard path alias (or a `TIRA_HOME` fallback, TGT-081) for both storage and attachments (TGT-051); `bot_groups` parses repeatable `--chat_id`/`--bot` CLI args, folding in `D2TG_CHAT_ID`/`D2TG_TOKEN` as an implicit trailing pair through the same grouping algorithm (TGT-049); `shift_flag_value` (TGT-072) is a shared helper backing `extract_db_flag`'s `--db`/`-d`, `bot_groups`'s `--chat_id` and (TGT-074) `--bot`, `cli/reply.pl`'s own `--db`, `cli/history.pl`'s `--since`/`--until`, and `D2TG::Reply::extract_bot_flag`'s `--bot` validation - one implementation instead of many independent hand-rolled copies; `lock_path` resolves `cli/poller.pl`'s single-instance lock file path, mirroring `state_db_path`/`attachments_dir`'s own base_dir/`.tira/` resolution exactly (`.tira/telegram.pid` for a resolved base_dir, TGT-087); `require_existing_base_dir` (TGT-090) dies if the resolved base_dir doesn't already exist on disk - called by every `cli/*` script right after `resolve_alias_dir`, so a bogus `TIRA_HOME`/alias target is refused instead of silently `mkdir -p`'d into existence; `resolve_self_exec_path` (TGT-094) checks whether a given basename (`poller.pl`) exists in a given bin directory, returning that fresh path if so and a supplied fallback otherwise - `cli/poller.pl`'s version-change restart uses this instead of blindly `exec()`ing the literal `$0` path captured at launch, so a running poller survives an install that renames its own entrypoint file out from under it; `is_transient_error` (TGT-097) classifies an error message as transient (matches `/timed out/i` or `/status 5\d\d/`) or not - a shared predicate now used by both `D2TG::Reply::format_send_error` (TGT-096) and `D2TG::Poller::run_once_safe` (TGT-097), avoiding duplicated regex. |
| `D2TG::Telegram` | Raw HTTP Bot API client (`LWP::UserAgent`, no SDK, explicit 50s timeout - TGT-035/TGT-066, backed by a real SIGALRM-based hard timeout since a stuck TCP connect() was found to bypass it in production - TGT-044): `get_me`, `get_updates`, `get_file`, `file_download_url`, `send_message` (auto-split, optional `reply_to_message_id` - TGT-040), `send_voice` (multipart, optional `reply_to_message_id` - TGT-040), `send_photo`/`send_document` (TGT-103, multipart via a shared `_send_file` helper, optional `caption`/`reply_to_message_id`) - the outbound counterpart to `D2TG::Download`'s inbound media handling. |
| `D2TG::Poller` | `run_once` — one poll cycle: access-control gate (its `is_allowed`/`add_pending` calls pass the pair's own `bot_token` through as the store's `bot_key`, TGT-098 - so a multi-bot config's per-bot access scoping is enforced on the inbound side too, not just at `cli/approve`), text/voice/media event lines (sanitized to always be a single stdout line, even a multi-segment voice transcript - TGT-039; naming the message's own `message_id` - TGT-040; plus a `(replying to ... [msg #N]: ...)` suffix when the message is itself a reply, naming the original message's own id (TGT-041) and preferring our own stored message history over Telegram's bare payload - TGT-029/TGT-038), the `REPLY WITH` template (now including `--reply-to-message-id` - TGT-040), non-fatal error handling for voice/media, a specific error for files over Telegram's 20MB `getFile` limit (TGT-037); before a voice message's (potentially multi-minute, blocking) transcription attempt, prints a `NEW TG VOICE [chat_id] sender: transcribing... (this may take a few minutes)` notice so the watching agent notices immediately instead of the whole wait being silent (TGT-100, live user request). `run_once_safe` wraps it so a failure is retried after a short backoff instead of killing the poller (TGT-028); a known-transient failure (network timeout, 5xx status) retries silently with no STDERR output, while a genuinely unexpected/non-transient failure is still logged as `POLL ERROR` (TGT-097, via `D2TG::Config::is_transient_error`). |
| `D2TG::Store` | SQLite-backed allow-list/pending/offset/message-history persistence; `is_allowed`/`add_pending`/`approve`/the constructor's `admin_chat_id` seeding all accept an optional `bot_key` (default `DEFAULT_BOT_KEY`, a named constant currently `''`, the single-bot sentinel - TGT-101) - `allow_list`/`pending` carry a composite `(chat_id, bot_key)` PRIMARY KEY (TGT-098), migrated in place from any pre-existing single-column-PK database so a Telegram group shared by more than one configured bot can no longer have an approval leak from one bot to another; `approve` is atomic and rolls back cleanly on any failure; `record_message`/`get_message` store a short summary of each processed message keyed by chat_id+message_id (TGT-038); `mark_read`/`is_read` track read/unread status, set only after a reply actually succeeds (TGT-046); `unread_messages` lists every not-yet-read message, oldest first (TGT-047; ties on the same-second `created_at` broken by `message_id` ascending, TGT-075); `recent_messages`/`messages_in_range` back `d2 tg.history`'s default-last-10 and date-range views (TGT-048; `messages_in_range` shares the same same-second `message_id` tiebreaker, TGT-075); `admin_chat_id` (constructor) also accepts an arrayref to seed multiple chat ids allowed; `get_offset`/`set_offset` accept an optional per-bot key (SHA256-hashed before storage, never plaintext) for independent multi-bot offsets (TGT-049); `disconnect` closes the DB handle cleanly (used before the poller re-execs itself, TGT-036). |
| `D2TG::TTS` | `synthesize` — text → gTTS → ffmpeg → Ogg/Opus, fatal on failure; `_run`'s subprocess output is suppressed, never leaks onto the caller's stdout/stderr (TGT-033). |
| `D2TG::Reply` | `send_reply` — text sent first, then the voice note is synthesized and sent (TGT-083; reversed from the original voice-first order). No flag or code path skips voice, and a synthesis/`send_voice` failure still fails the whole reply loudly, but it can no longer prevent the text half from having already reached the user. Threads an optional `reply_to_message_id` through both sends for a native Telegram reply (TGT-040); given a `store` too, marks that message read only after both sends succeed (TGT-046). `parse_cli_args` — parses `cli/reply.pl`'s argv, recognizing `--reply-to-message-id` only in trailing position (TGT-042); decodes every argument as UTF-8 first (TGT-073), fixing a real bug where non-ASCII reply text (accents, CJK, emoji) arrived on Telegram as mojibake since `@ARGV`'s raw bytes were never decoded before reaching `encode_json`. `format_send_error` (TGT-096) appends an explicit "try again" instruction to a `send_reply` failure's error text when it looks transient (a network timeout or a `5\d\d` status, matching `D2TG::Telegram`'s own die message shapes) - a permanent failure (bad token, invalid chat_id) is returned unchanged, with no misleading retry suggestion; `cli/reply.pl` now wraps `send_reply` in `eval` and routes any failure through this before printing to STDERR. `resend_voice` (TGT-109) - same arguments minus `store`, synthesizes and sends only the voice half, never calling `send_message` - recovers a reply whose text already delivered but whose voice failed, without duplicating the text; exposed as `cli/reply.pl --voice-only`. |
| `D2TG::Download` | `download_file` — any Telegram `file_id` → local file. Given a `dir` (TGT-051), the file is content-addressed by its own SHA256 hash and deduplicated; without one, an OS-temp-dir file as before. A dedup hit refreshes the existing file's modification time to now (TGT-054), so a repeatedly re-sent file counts as recently used. `prune_vault` keeps a directory at or under a byte cap (100MB default), deleting oldest-modified files first (TGT-052). |
| `D2TG::Transcribe` | `transcribe` — local `whisper` CLI, refuses `*.en` models; `_run` is timeout-bounded and killable (`kill_current`, TGT-031). `select_model($duration_seconds)` (TGT-100) tiers the model by audio length - `<=300s` 'medium', `<=900s` 'small', longer 'base' - as a starting-point guess; `transcribe()` probes duration via `_probe_duration` (an `ffprobe` list-form pipe open, no shell) unless an explicit `model` argument is given. Per-host Whisper throughput varies too much for the duration guess alone to guarantee correctness (measured: `medium` at ~5.6x real time on one host, no GPU) - so `transcribe()` also automatically retries at the next faster tier (`medium` → `small` → `base`, via `_next_tier`) whenever an automatically-selected model times out, dying with `TRANSCRIBE ERROR` only if even `base` times out. An explicitly-passed `model` is never automatically retried. |
| `D2TG::Lock` | `acquire`/`release` — single-instance PID-file lock for `cli/poller.pl`, so a stopped/suspended or otherwise still-live previous instance never silently competes for the same bot's `getUpdates` slot (TGT-062). `acquire` re-acquiring the caller's own already-held lock (exactly what `cli/poller.pl`'s version-triggered self-restart produces every time, since `exec()` preserves the PID) returns success immediately without ever touching the lock file (TGT-102 - previously fell through into the fallback reclaim path and unlinked+recreated the file even though it wasn't stale, opening a narrow race window where an independently-started second poller could SIGKILL the legitimately self-restarting one). A lock held by a genuinely different, still-live PID is taken over "last one wins" - `SIGKILL`, then a short bounded wait for death (TGT-084). A lock naming a dead PID is reclaimed via an atomic unlink+`O_CREAT|O_EXCL` retry, never a non-atomic in-place overwrite. `release` only removes the file if it still names the caller's own PID. |

`cli/poller.pl`, `cli/approve.pl`, `cli/reply.pl`, `cli/send.pl`, `cli/unread.pl`, `cli/history.pl`, `cli/help.pl`
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
