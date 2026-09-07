# tg — command reference

All commands are dispatched via Developer Dashboard as `d2 tg.<name>`
(the `cli/<name>` script in this repo).

## `d2 tg.poller [--db <alias> | -d <alias>] [--chat_id <id> --bot <token> ...]`

`--db <alias>`/`-d <alias>` (TGT-051, or `D2TG_DB=<alias>` as a
fallback) relocates both the SQLite state file and downloaded
attachments under that Developer Dashboard path alias's directory -
**mandatory** (TGT-059): every `d2 tg.*` command refuses to start
(exit 1, clear STDERR message pointing at `d2 paths`) when neither this
flag nor `D2TG_DB` is given at all, and the same happens when an alias
*is* given but isn't a known one. There is no default-storage-location
fallback. See the Environment variables section below.

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
independently of the env var). Also refuses to start (TGT-062) if
another `d2 tg.poller` instance already holds an exclusive lock
(`poller.pid` under the resolved `--db`/`-d`/`D2TG_DB` storage location)
and is still alive - the message names the exact PID to kill. A lock
left by an unclean death (e.g. `kill -9`, a crash) is reclaimed
automatically on the next start rather than blocking it; only a
genuinely still-running process refuses. On startup, prints `d2tg poller starting
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
- `NEW TG MEDIA [chat_id] sender: <photo|document> <local_path>` — an
  allowed sender's photo/document message, downloaded to `local_path`.
  For a photo, the largest available resolution is downloaded.
  `local_path` is content-addressed (TGT-051, named by the file's own
  SHA256 hash) under `D2TG::Config::attachments_dir` - identical content
  downloaded any number of times, from any sender, only ever occupies
  one copy of disk space.
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
  group configured) the template also names the exact bot that received
  the message (`--bot <token>`, TGT-057) - `d2 tg.reply` has no other way
  to know which of the pool's bots to send through, since single-bot
  mode's `D2TG_TOKEN` fallback doesn't apply when the poller was
  configured purely via CLI flags. Single-bot/env-only mode is
  unchanged - no `--bot` is ever printed there, since `D2TG_TOKEN` alone
  is already unambiguous.

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

## `d2 tg.approve <chat_id> [--db <alias> | -d <alias>]`

Moves `chat_id` from pending into the allow-list. Prints `Approved N`
and exits 0 on success. Exits 1 (message on STDERR) if `chat_id` was
already allowed, or was never pending at all. `--db`/`-d` (TGT-051)
resolves the same way `d2 tg.poller`'s does.

## `d2 tg.reply [--db <alias> | -d <alias>] [--bot <token>] <chat_id> <text...> [--reply-to-message-id <id>]`

(`--reply-to-message-id`, when given, must be the last two arguments -
see below; `--db`/`-d` and `--bot` are the opposite - recognized only in
the *leading* position, before `chat_id`, for the same collision-avoidance
reason, and in either order)

`--bot <token>` (TGT-057) sends via that bot token instead of
`D2TG_TOKEN` - required when replying to a message received under
`d2 tg.poller`'s multi-bot mode (TGT-049) by a bot other than the one
`D2TG_TOKEN` happens to name; the poller's own `REPLY WITH` template
already fills this in when it applies. Omitting it is unchanged from
before this ticket - falls back to `D2TG_TOKEN`, exactly as every
single-bot-mode reply always has. A bare trailing `--bot` with no value
following it is rejected with the usual `Usage` error instead of
hanging (TGT-068, a real live-reproduced infinite loop before this fix).

Sends `text` to `chat_id` as **both** a text message and a gTTS voice
note — never text-only. If speech synthesis (`gtts-cli` then `ffmpeg`)
fails for any reason, the command dies before sending anything at all;
there is no partial/degraded reply. Text longer than 4000 UTF-16 code
units is split across multiple `sendMessage` calls without ever breaking
a single character (a supplementary-plane character, which is a UTF-16
surrogate pair, is always kept in one chunk).

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
  whose directory relocates both the SQLite state file and downloaded
  attachments; fallback for every `d2 tg.*` command's `--db`/`-d` flag
  when the flag isn't given. **Required** (TGT-059) — every `d2 tg.*`
  command refuses to start if neither this nor `--db`/`-d` is given at
  all, the same as an unknown alias already refused.

## Module reference

Full behavior/signature detail lives in each module's own POD
(`perldoc lib/D2TG/<Name>.pm`); this is a one-line-each map of what's
implemented and where:

| Module | What it does |
| --- | --- |
| `D2TG::Config` | Reads `D2TG_TOKEN`/`D2TG_CHAT_ID`; startup guard; resolves `state/store.sqlite`'s path; `skill_version` reads `.env`'s installed VERSION (TGT-036); `masked_token` masks a token to its first/last 4 chars for safe display (TGT-045); `extract_db_flag`/`resolve_alias_dir`/`attachments_dir` resolve an optional `--db`/`-d`/`D2TG_DB` Developer Dashboard path alias for both storage and attachments (TGT-051); `bot_groups` parses repeatable `--chat_id`/`--bot` CLI args, folding in `D2TG_CHAT_ID`/`D2TG_TOKEN` as an implicit trailing pair through the same grouping algorithm (TGT-049). |
| `D2TG::Telegram` | Raw HTTP Bot API client (`LWP::UserAgent`, no SDK, explicit 50s timeout - TGT-035/TGT-066, backed by a real SIGALRM-based hard timeout since a stuck TCP connect() was found to bypass it in production - TGT-044): `get_me`, `get_updates`, `get_file`, `file_download_url`, `send_message` (auto-split, optional `reply_to_message_id` - TGT-040), `send_voice` (multipart, optional `reply_to_message_id` - TGT-040). |
| `D2TG::Poller` | `run_once` — one poll cycle: access-control gate, text/voice/media event lines (sanitized to always be a single stdout line, even a multi-segment voice transcript - TGT-039; naming the message's own `message_id` - TGT-040; plus a `(replying to ... [msg #N]: ...)` suffix when the message is itself a reply, naming the original message's own id (TGT-041) and preferring our own stored message history over Telegram's bare payload - TGT-029/TGT-038), the `REPLY WITH` template (now including `--reply-to-message-id` - TGT-040), non-fatal error handling for voice/media, a specific error for files over Telegram's 20MB `getFile` limit (TGT-037). `run_once_safe` wraps it so a transient failure (network blip, etc.) is logged as `POLL ERROR` and retried after a short backoff instead of killing the poller (TGT-028). |
| `D2TG::Store` | SQLite-backed allow-list/pending/offset/message-history persistence; `approve` is atomic and rolls back cleanly on any failure; `record_message`/`get_message` store a short summary of each processed message keyed by chat_id+message_id (TGT-038); `mark_read`/`is_read` track read/unread status, set only after a reply actually succeeds (TGT-046); `unread_messages` lists every not-yet-read message, oldest first (TGT-047); `recent_messages`/`messages_in_range` back `d2 tg.history`'s default-last-10 and date-range views (TGT-048); `admin_chat_id` (constructor) also accepts an arrayref to seed multiple chat ids allowed; `get_offset`/`set_offset` accept an optional per-bot key (SHA256-hashed before storage, never plaintext) for independent multi-bot offsets (TGT-049); `disconnect` closes the DB handle cleanly (used before the poller re-execs itself, TGT-036). |
| `D2TG::TTS` | `synthesize` — text → gTTS → ffmpeg → Ogg/Opus, fatal on failure; `_run`'s subprocess output is suppressed, never leaks onto the caller's stdout/stderr (TGT-033). |
| `D2TG::Reply` | `send_reply` — voice sent first, text only after voice succeeds; never text-only. Threads an optional `reply_to_message_id` through both sends for a native Telegram reply (TGT-040); given a `store` too, marks that message read only after both sends succeed (TGT-046). `parse_cli_args` — parses `cli/reply`'s argv, recognizing `--reply-to-message-id` only in trailing position (TGT-042). |
| `D2TG::Download` | `download_file` — any Telegram `file_id` → local file. Given a `dir` (TGT-051), the file is content-addressed by its own SHA256 hash and deduplicated; without one, an OS-temp-dir file as before. A dedup hit refreshes the existing file's modification time to now (TGT-054), so a repeatedly re-sent file counts as recently used. `prune_vault` keeps a directory at or under a byte cap (100MB default), deleting oldest-modified files first (TGT-052). |
| `D2TG::Transcribe` | `transcribe` — local `whisper` CLI, refuses `*.en` models; `_run` is timeout-bounded and killable (`kill_current`, TGT-031). |

`cli/poller`, `cli/approve`, `cli/reply`, `cli/unread`, `cli/history`
are the thin `d2 tg.*` entrypoints described above; each just wires the
relevant modules together.

## Troubleshooting

### `HTTP request failed (status 401 Unauthorized)`

This means **Telegram itself rejected the token** - `D2TG_TOKEN` is
wrong, was regenerated, or was revoked. It is not a code bug: confirmed
(TGT-026) by running a direct `curl
https://api.telegram.org/bot<token>/getMe` alongside `cli/poller` in a
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
