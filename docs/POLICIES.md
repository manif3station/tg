# tg — operational policies

These are the behavioral rules this skill's code enforces, distinct from
the Tira board's own SDLC/delivery policies (see this project's board,
"D2 TG Skill", for those). They come from the owner's original design
brief for this skill.

## The multi-bot reply path names its own bot, not just its own chat

Bug-hunt finding (TGT-057): TGT-049's multi-bot mode (`d2 tg.poller
--chat_id ... --bot ...`) can serve chats purely via CLI flags, with
`D2TG_TOKEN` left entirely unset - but `d2 tg.reply` always sent via
`D2TG_TOKEN` alone, so replying to a message from such a chat died
immediately (`D2TG::Telegram->new requires a token`). The poller's
`REPLY WITH` template now names the receiving bot (`--bot <token>`)
whenever it's running in multi-bot mode, and `d2 tg.reply` accepts that
flag to send via the named bot instead. Single-bot/env-only mode is
completely unaffected - no `--bot` is ever printed or required there.

## Multi-bot access control is scoped per bot, not shared across them (TGT-098)

Bug-hunt finding (JOB-003, cross-module interaction investigation): the
same blind spot TGT-057 found in the multi-bot *reply* path also existed
in *access control*. `D2TG::Store`'s `allow_list`/`pending` tables used
to be keyed only by `chat_id` - but a Telegram **group** chat's
`chat_id` is a property of the group itself, shared by every bot that's
a member of it (unlike a private chat's `chat_id`, which Telegram
allocates uniquely per bot-user pair). If a multi-bot config
(TGT-049) had two of this skill's own bots in the same group,
approving that group for one bot (`d2 tg.approve <chat_id>`) silently
also approved it for the other - the operator had no way to scope the
grant to just one bot.

Both tables now carry a composite `(chat_id, bot_key)` PRIMARY KEY,
with `bot_key=''` as the single-bot sentinel - deliberately not SQL
`NULL`, since SQLite's own uniqueness checks don't treat two `NULL`s as
equal, which would have silently defeated this exact constraint. A
pre-existing database (the old single-column-PK shape) is migrated in
place the first time it's opened: SQLite can't `ALTER` a `PRIMARY KEY`,
so the old table is renamed aside, replaced with the new shape, every
row copied across with `bot_key=''`, and the old table dropped -
matching what every existing single-bot install already had, just now
explicitly scoped. The whole rename/create/copy/drop sequence is
wrapped in one transaction, so a failure partway through (a real
concern, unlike the project's other, single-statement schema
migrations) rolls back cleanly rather than leaving a half-migrated
database - a subsequent open retries the migration from the original,
untouched state. `d2 tg.approve` gains an optional `--bot <token>`
flag (the same shape as `d2 tg.reply`'s own) to grant access scoped to
one bot; omitting it behaves exactly as before this ticket.

(TGT-101: the `bot_key=''` sentinel above is now `D2TG::Store::DEFAULT_BOT_KEY`,
a single named constant, rather than a bare `''` literal repeated at
every call site - a pure refactor, no behavior change.)

## Access control: not everyone can talk to the bot

`D2TG_CHAT_ID` is auto-seeded as allowed on every start. Any other chat
id that messages the bot is silently recorded as **pending** — nothing
it sends reaches stdout — until an operator runs `d2 tg.approve
<chat_id>`. The first time a given pending chat id messages the bot, one
`NEW TG PENDING [chat_id] awaiting approval` line is printed so the
operator notices; repeat messages from the same still-pending sender do
not repeat the notification.

## Oversized files are rejected clearly, before a doomed download attempt

Telegram's Bot API `getFile` endpoint has a hard, documented 20MB limit
- anything larger returns an opaque `400 Bad Request` no matter what
this skill does (TGT-037, live bug report: a large file produced an
unexplained `MEDIA DOWNLOAD ERROR`). Before attempting to download a
photo/document, the poller checks the message's own declared
`file_size`; if it's over 20MB, it reports a specific, actionable
`MEDIA DOWNLOAD ERROR ... file too large` message and never attempts the
download at all, rather than letting the operator guess whether a raw
400 means "expected size limit" or "something is actually broken."

## A reply-to-message carries its own context on the way in

When a sender replies to a specific earlier Telegram message (TGT-029,
live usability report), the poller's `NEW TG`/`NEW TG VOICE`/`NEW TG
MEDIA` line names what that reply targets - the original sender and a
snippet of the original text (or its media kind) - so the monitoring
agent never has to cross-reference an earlier line to know which
message in the conversation a reply responds to.

## The reply-context prefers our own message history over Telegram's bare payload

Live feedback (TGT-038): replying to an uploaded document previously
showed only the generic media kind - "(replying to X: document)" - with
no way to tell which document, even though this skill had already
downloaded it moments earlier. Every message this skill successfully
processes (text, a transcribed voice note, or a downloaded photo/
document) is now recorded in `D2TG::Store` against its own chat_id and
message_id. When building a reply-context suffix, the poller looks up
the replied-to message there first; only when nothing was ever stored
for it (it predates this feature, or its sender was never allow-listed
at the time) does it fall back to Telegram's own `reply_to_message`
payload, unchanged from before.

## Both Telegram send methods validate reply_to_message_id the same way

Improvement-hunt finding (TGT-055): `D2TG::Telegram::send_voice` already
validated `reply_to_message_id` is numeric before use, dying with a
clear D2TG-level error otherwise; `send_message` did not, and would have
silently forwarded a bad value into Telegram's API instead, surfacing
only as an opaque remote error. `send_message` now validates the same
way `send_voice` always has - both existing callers (`cli/reply.pl`, the
poller's own `REPLY WITH` template) already validate upstream, so this
closes a latent gap rather than changing any live caller's behavior.

## d2 tg.reply's --reply-to-message-id flag only ever means what it looks like

Hourly bug-hunt finding (TGT-042): the flag (TGT-040) was originally
recognized anywhere in `cli/reply.pl`'s argument list, which made it
ambiguous with free reply text - text passed as multiple unquoted shell
words could, in principle, contain the literal token
`--reply-to-message-id` and have it (and the following word) silently
stripped out and misread as the flag, corrupting the sent message
without any error. It is now recognized only in the trailing position -
the last two arguments - matching exactly how the poller's own `REPLY
WITH` template always appends it, so there is no longer any ambiguity
between "this is reply text" and "this is the flag."

## The reply-context suffix names the original message's own id too

Live example (TGT-041): "where is msg80 at msg81 when 81 is replying to
80" - TGT-040 named each message's own id, but the reply-context suffix
itself still only named the original sender and a content description,
not that message's own id. The suffix now reads "(replying to bob [msg
#80]: document ...)" - the bracketed id is the original message's own
`message_id`, sourced directly from Telegram's `reply_to_message`
payload (always present on a native reply, independent of whether a
stored record was found for the store-lookup-first behavior above).

## message_id is Telegram's own counter - --db/-d/D2TG_DB has no effect on it

Live question (TGT-063): "even i switch to different vault dir. the
message id still the same increment from last?" - yes, and this is
expected, not a bug. `message_id` is assigned entirely on Telegram's own
servers, as a per-bot sequence that increments with every message that
bot ever sends or receives, across every chat - this skill never
generates, offsets, or otherwise touches it (grep-verifiable: every
`message_id` in `D2TG::Poller` is read directly from
`$message->{message_id}`, Telegram's own payload). `--db`/`-d`/`D2TG_DB`
(TGT-051, TGT-059) only relocates where this skill's own local SQLite
state and downloaded attachments live - it has no relationship to, and
no ability to influence, Telegram's own counter for that bot. Switching
storage locations, or even switching which bot token is in use (TGT-049
multi-bot mode), never resets or changes where a given bot's own
`message_id` sequence continues from.

## --db/-d always requires a real value, everywhere it's recognized

Hourly bug-hunt finding (TGT-071): `D2TG::Config::extract_db_flag` - the
shared `--db`/`-d` parser used by `cli/poller.pl`, `cli/approve.pl`,
`cli/unread.pl`, and `cli/history.pl` - shifted the token immediately after
`--db`/`-d` with no validation, same as `cli/reply.pl`'s own separate
leading-position `--db` extraction. A bare trailing `--db`, or `--db`
immediately followed by another real flag, silently swallowed that
flag's own name as the alias instead of erroring - e.g. `cli/history.pl
--db --since 2026-01-01` dropped `--since` entirely and failed with
`Unknown --db/-d alias '--since'`, naming the wrong problem. Both
`extract_db_flag` and `cli/reply.pl`'s own loop now die/exit with a clear
`--db/-d requires a value` message whenever the shifted value is
missing, empty, or itself flag-like - the same validation shape already
applied to `--chat_id` (TGT-069) and `--since`/`--until` (TGT-070).

## The flag-value-requires-a-value check now lives in one place

Improvement-hunt finding (TGT-072), filed immediately after TGT-071
shipped: the "shift a flag's value and validate it isn't
missing/empty/flag-like" pattern had been independently hand-rolled at
4 separate call sites across TGT-068 (`cli/reply.pl`'s `--db`), TGT-069
(`bot_groups`'s `--chat_id`), TGT-070 (`cli/history.pl`'s
`--since`/`--until`), and TGT-071 (`extract_db_flag`'s `--db`/`-d`) -
each with slightly different predicate logic, two checking a generic
"looks like a flag" pattern and two hardcoding the exact sibling flag
names instead. Extracted into `D2TG::Config::shift_flag_value`, now the
single implementation all 4 call sites share - any future flag added
anywhere in this skill gets the same guard for free instead of needing
its own copy.

## --bot's own token needed the same shared validation, found right after

Bug-hunt finding (TGT-074), same class as TGT-069/071/072: `bot_groups`'s
`--bot` branch and `D2TG::Reply::extract_bot_flag` both spliced/shifted
the next token as the bot token with zero validation, even after
`shift_flag_value` existed - `bot_groups(argv=>['--chat_id','1234',
'--bot'])` silently produced `{chat_id=>1234, bots=>[undef]}`, and
`extract_bot_flag('--bot','--db','myalias',...)` silently returned
`'--db'` as the token. Both now route through
`D2TG::Config::shift_flag_value`, same as every other flag this skill
validates.

## The vault nests under .tira/, and TIRA_HOME is a real fallback

Live requests (TGT-081): a resolved `--db`/`-d`/`D2TG_DB` base directory
no longer stores files flat (`store.sqlite`, `files/`) - both now live
under a `.tira/` subdirectory, renamed (`telegram.messages.db`,
`attachments/`). Separately, when none of `--db`/`-d`/`D2TG_DB` is
given at all, `TIRA_HOME` (if set) is used as the base directory
directly instead of refusing to start - only when no alias was given
at all; an unknown alias still refuses rather than falling through to
`TIRA_HOME`. If neither an alias nor `TIRA_HOME` is available, the
poller (and every `d2 tg.*` command) still refuses to start with a
clear error, exactly as TGT-059 originally established - there is no
silent fallback to an undefined or default location.

**Update, TGT-087 (2026-09-08), a live follow-up request:** the single-
instance lock file (`D2TG::Lock`, TGT-062/TGT-084) was the one
vault-resident file TGT-081 missed - it stayed flat (`poller.pid`
directly under the base directory) while the state DB and attachments
moved under `.tira/`. It now lives at `.tira/telegram.pid`, resolved by
a new `D2TG::Config::lock_path` that mirrors `state_db_path`/
`attachments_dir`'s own pattern exactly. All three vault-resident
artifacts are consistently nested under `.tira/` as of this ticket.

**Update, TGT-090 (2026-09-08), live user request + live reproduction:**
resolving a base directory - either a `--db`/`-d`/`D2TG_DB` alias's real
path, or the `TIRA_HOME` fallback above - must be pure lookup, never
creation. Michael: *"tg.* will not create any folder. It take the value
of them as alias and resolve the path and start running on it. No
mkdir."* Before this fix, that wasn't true: `TIRA_HOME`'s value was
used completely unvalidated, and `state_db_path`/`attachments_dir`/
`lock_path`'s own `make_path` calls on the `.tira/` subdirectory would
silently create the *entire* tree - including a `TIRA_HOME` base
directory that had never actually existed. Reproduced live in a
`tira:latest` container: `TIRA_HOME=foobar` (a bogus relative path) made
`d2 tg.unread` silently `mkdir -p ./foobar/.tira/` and create
`telegram.messages.db` inside it, rooted at whatever the current
working directory happened to be, with no error and no confirmation.
Fixed with a new `D2TG::Config::require_existing_base_dir`, called by
every `cli/*` script immediately after `resolve_alias_dir` returns: it
dies if the resolved base_dir is not already a real, existing
directory. The `.tira/` subdirectory *under* an already-real base_dir is
still created as before - that's this skill's own controlled state
folder, not the bug; the bug was the base_dir itself never being
checked to actually pre-exist.

**Update, TGT-091 (2026-09-08), a second live production incident:**
this fix immediately exposed a deeper, pre-existing flaw in how
`TIRA_HOME` itself gets resolved. Michael's own `zen-framework` project
sets `TIRA_HOME=tira-zen` - `tira-zen` is a real, registered `d2 paths`
alias (resolving to `/home/mv/.tira/zenandi`, which genuinely exists),
not a literal filesystem path. TGT-081's original design assumed
`TIRA_HOME` would always hold a raw path ("already a filesystem path,
not a `d2 paths` alias name") and returned it as-is; TGT-090's new
existence check then correctly rejected the literal string `tira-zen`
as a nonexistent directory, which meant `d2 tg.poller` could not start
at all in `zen-framework` - an active production incident, not a
hypothetical. `resolve_alias_dir`'s `TIRA_HOME` branch now looks the
value up against the `d2 paths` table first, exactly like an explicit
`--db`/`-d`/`D2TG_DB` alias would be, and only falls back to treating it
as a literal filesystem path if it matches no registered alias -
preserving TGT-081's original behavior for anyone who genuinely does set
`TIRA_HOME` to a raw path, while fixing the apparently more common real
usage where it names an alias instead.

## A content-addressed download can never leave a corrupted, silently-trusted file

Live-reproduced finding (TGT-080): a process killed mid-download used
to leave a truncated file at the hash-derived path whose real content
no longer matched its own filename's claimed hash - and since the
dedup check only tests whether the file exists (never re-hashes it),
that corrupted file was silently trusted as "already correctly
downloaded" forever after, with no repair and no detection. Confirmed
via a real forked-process kill in `developer-dashboard:latest`. The
first-time write now goes through a temp-file-then-rename sequence
(`D2TG::Download::_atomic_write`) - `rename` is atomic on POSIX
filesystems, so any interruption before it runs leaves nothing at the
final path at all, never a truncated one.

## The owner's own name can be shown instead of their Telegram username

Live request (TGT-079): `D2TG_OWNER`, when set, replaces the raw
Telegram username with a friendlier configured name in every printed
sender line - but only for messages from the `D2TG_CHAT_ID` chat.
Every other sender's username is always shown unchanged, and this is
purely a display substitution: it has no effect on access control,
allow-listing, or anything keyed on the numeric chat id, which is
untouched by this feature.

## Same-second messages need a message_id tiebreaker, not just created_at

Search-fork finding (TGT-075): `unread_messages` and `messages_in_range`
both `ORDER BY created_at` alone - a second-resolution column with no
secondary tiebreaker - while `recent_messages`, querying the same table,
already adds `, message_id DESC` for exactly this reason. Whenever two
or more messages land within the same second (a realistic burst, e.g.
two rapid messages in one poll cycle), SQLite's tie-break order for
equal `ORDER BY` keys is not guaranteed to match chronological order,
so `d2 tg.unread`/`d2 tg.history` could silently show a same-second
burst out of sequence despite promising "oldest first." Both now add
`message_id` (ascending, since they're oldest-first views) as the
tiebreaker, matching `recent_messages`'s own already-correct pattern.

## Non-ASCII reply text needs a UTF-8 decode before it reaches JSON

Hourly bug-hunt finding (TGT-073): `@ARGV` is always raw bytes - Perl
never decodes it as UTF-8 on its own. `D2TG::Reply::parse_cli_args`
composed `$text` directly from `@ARGV`, so any accented, CJK, Cyrillic,
or emoji character in reply text reached `D2TG::Telegram`'s
`encode_json` call still as un-decoded bytes. `JSON::PP::encode_json`
treats an un-decoded string as Latin-1 codepoints and re-encodes it as
UTF-8, double-encoding every multi-byte character - live-reproduced as
`encode_json({text=>"h\xc3\xa9llo"})` (raw UTF-8 bytes for "héllo")
producing `{"text":"hÃ©llo"}` instead of `{"text":"héllo"}`.
`parse_cli_args` now decodes every argument as UTF-8 first, fixing it
at the one chokepoint every `d2 tg.reply` invocation passes through.

## A reply can thread natively under the original Telegram message

Live follow-up question (TGT-040): "where is the message id?" - every
content line and the `REPLY WITH` template now name the inbound
message's own `message_id`, and `d2 tg.reply` accepts an optional
`--reply-to-message-id <id>` that threads through to Telegram's own
`reply_to_message_id` on both the voice and text sends. Without it, a
reply always arrived as a fresh, unthreaded message even when the
operator was clearly answering a specific prior message - copying the
poller's own `REPLY WITH` template (which already fills the id in) now
produces a reply that shows up threaded in Telegram's UI. Omitting the
flag is unchanged from before this ticket.

## A voice transcript is always exactly one stdout line, like text is

Code-review bug hunt finding (TGT-039): inbound text messages have their
newlines escaped to a literal `\n` before being printed, since every
`NEW TG` line must be exactly one line for the Tira monitor job's feeder
to parse correctly - but voice transcripts weren't sanitized the same
way, even though whisper's own output can legitimately span multiple
lines (one per segment) for a longer voice note. The same sanitization
(`_sanitize_for_stdout` in `D2TG::Poller`) now applies to both text and
voice-transcript content before printing or storing it, so a `NEW TG
VOICE` line - and the summary it stores for later reply-context lookups
(TGT-038) - is always single-line.

## CLI commands validate chat_id locally before any network call

Both `d2 tg.approve` and `d2 tg.reply` reject a non-numeric `chat_id`
argument immediately (exit 2, `Usage` message on STDERR) rather than
letting it reach the Telegram API and fail there (TGT-027) - a mistyped
or missing chat id should read as a clear local usage error, not an
opaque remote failure.

## A reply always sends text first, then voice (TGT-083)

`d2 tg.reply` (via `D2TG::Reply::send_reply`) sends the text message
first, then synthesizes the voice note, then sends the voice note — a
deliberate, explicit reversal (live user request, 2026-09-08: *"text goes
out first and create voice note and send voice note afterward. not other
way round"*) of this module's original order (synthesize and send voice
first, text only once voice succeeded).

There is still deliberately no flag or code path that skips voice, and a
synthesis or `send_voice` failure still fails the whole reply loudly
(`cli/reply.pl` exits non-zero) rather than silently reporting success. What
changed: because the text message is now sent *before* synthesis/voice
can fail, a failure at either of those later steps can no longer prevent
the text from having already reached the user — Telegram messages can't
be unsent by this code. The guarantee is now "voice always follows a
successful text send, and any failure after that point is always
reported loudly," not "a text-only reply can never happen at all." See
`tg-skill-design.md`'s "Reply design lessons" section (and its TGT-083
update) for the full incident history this guarantee is built on and why
it changed.

## A failed reply tells the agent whether retrying is worth it (TGT-096)

Live user request, 2026-09-08: Michael hit a real `d2 tg.reply` failure
in a different project (`sendVoice: HTTP request failed - status 500,
request timed out after 50s`) and asked, via the Telegram bridge: *"Instead
of showing the error only. Also instruction to ask the agent try again."*
Before this, `cli/reply.pl` called `D2TG::Reply::send_reply` completely
unwrapped - any failure (transient network timeout, or a permanent
problem like a bad token) propagated as a raw, uncaught Perl fatal, with
no signal to the calling agent about which kind of failure it was looking
at.

`D2TG::Reply::format_send_error` now classifies the error text:
transient-shaped errors (a network timeout, or an HTTP `5\d\d` status -
the same shapes `D2TG::Telegram`'s own die messages already use) get an
explicit retry instruction appended; anything else (a `4\d\d` status like
a bad token or invalid chat id) is left unchanged, so the agent is never
misled into retrying something a retry can't fix. `cli/reply.pl` now
wraps `send_reply` in `eval` and routes any failure through this function
before printing to STDERR and exiting non-zero - the exit code itself is
unaffected, only the message content. The classification itself
(`D2TG::Config::is_transient_error`) is a shared helper, not private to
`D2TG::Reply` - see the next section for its other caller.

## A known-transient poll failure retries silently instead of logging noise (TGT-097)

Live user request via the Telegram bridge, 2026-09-08, verbatim: *"also,
instead of showing the polling error. just silent it if that is
unavoidable and focus on recovery instead."* `d2 tg.poller`'s
`run_once_safe` already retries automatically after any poll-cycle
failure (TGT-028) - the retry loop itself was never the problem. What
Michael was reacting to was the `POLL ERROR: ...` line it printed on
*every* transient failure (a network timeout, a 5xx from Telegram's
side) - during a period of network/host contention this repeats many
times in a row, and each one reaches the project's `tira.policy.bridge`
as its own separate `monitor-output` event: pure noise, since nothing
actionable is gained from reporting a failure the poller is already
recovering from on its own.

`run_once_safe` now checks `D2TG::Config::is_transient_error($@)`
(TGT-096's shared classifier, moved to `D2TG::Config` for this reuse)
before printing: a transient-shaped failure retries completely silently
- no STDERR output at all, same sleep-and-continue behavior as before. A
genuinely unexpected/non-transient failure (a malformed response, an
auth problem) is still logged as `POLL ERROR`, exactly as before this
ticket - that class of failure is something an operator should actually
see, since the poller can't self-heal from it the way it can from a
routine timeout.

**Re-checked after a real repeated-timeout incident window (TGT-108,
2026-09-08 13:00-15:50 - several separate `POLL ERROR` occurrences over
that window, not one single call blocking the whole time)**:
investigated whether this silencing merely hid a still-occurring problem
rather than reflecting an actual fix. Confirmed via git history that
TGT-097 changed nothing about the underlying timeout/retry frequency,
only whether it prints - and that the timeout margin
(`DEFAULT_HARD_TIMEOUT`/`DEFAULT_LONG_POLL_MARGIN` below) had already
been widened once before, in TGT-066, for this exact symptom shape. The
same symptom recurred anyway using that already-widened margin - most
plausibly a genuine Telegram-side or network delay exceeding even a
generous bound, though the true cause wasn't directly observed and
remains an inference; this recurrence does not by itself indicate a
design flaw in the margin choice. No message loss occurred (the offset
only advances on a successful `getUpdates` call). Widening the margin
further was considered and rejected: TGT-035's own reason for bounding
this timeout at all is `cli/poller.pl`'s `SIGTERM`/`SIGINT` shutdown
responsiveness, so every second added here is a second added to
worst-case shutdown delay, and there's no evidence a wider bound would
have prevented this specific incident. No code change made: this
confirms that silencing routine transient poll failures remains
appropriate, rather than masking an unaddressed change to timeout or
retry behavior.

## Only one poller may ever hold the lock, and the last one to try wins (TGT-084)

Live production incident (TGT-062): "it is not always works. when send
message. the poller no showing new messages. i need to kill it and
reload." Root-caused live - a previous `d2 tg.poller` process had been
suspended via job control (`Ctrl-Z`, not killed) rather than terminated,
and still held an open connection to Telegram, silently competing with
a freshly started poller for the same bot's `getUpdates` slot (Telegram
allows only one active long-poll consumer per bot token). A stopped
process cannot be interrupted by any signal-based fix - including
TGT-044's own hard timeout - since the OS never schedules a stopped
process to run, so this had to be closed at startup instead. `d2
tg.poller` acquires an exclusive PID-file lock (`poller.pid`, under the
resolved `--db`/`-d`/`D2TG_DB` storage location) before doing anything
else. A lock naming a PID that's no longer alive (an unclean death, e.g.
`kill -9`) is reclaimed automatically - a stale lock must never itself
prevent recovery from a crash.

**Update, TGT-084 (2026-09-08), a second live production incident:** a
monitor job kept restarting `d2 tg.poller` while a still-live previous
instance held the lock, and TGT-062's original "refuse to start, name the
PID to kill manually" behavior meant every restart attempt just failed
again in a loop (`D2TG::Lock: could not acquire ... - contended for too
long`), with nobody actually killing the stale instance by hand. Michael,
live: *"only 1 poller can be run and the last one to run is the winner
and the one is running will be killed and replaced by the new
process."* `D2TG::Lock::acquire` no longer refuses when it finds a live
conflicting PID - it sends that process `SIGKILL` immediately (not
`SIGTERM`: `D2TG::Poller`'s own known limitation means graceful shutdown
handling can be delayed up to `DEFAULT_HARD_TIMEOUT` by an in-flight
long-poll call, which would make "last one wins" take just as long to
actually happen), waits in a short bounded loop for the process to
actually die, then reclaims the lock. If the target refuses to die within
that bound, `acquire` still dies naming the PID - this should be rare,
since `SIGKILL` cannot be caught or blocked.

This makes "more than one live process can transiently believe it holds
the lock" a normal, expected outcome when multiple fresh instances start
at nearly the same instant (each is entitled to try to take over from
whoever it finds), not a bug - what must still hold, and does, is that
the race always settles to exactly one process left alive holding a lock
file that names it. Reclaiming a now-dead PID's lock file was also
hardened to route through the same kernel-atomic `O_CREAT|O_EXCL` create
used for a brand-new lock (unlink the stale file, then retry from the
top) instead of a plain, non-atomic overwrite - before TGT-084, that
overwrite path could only ever be reached by one live process at a time
(any rival simply refused instead of racing to reclaim), so its lack of
atomicity was latent; TGT-084 makes several racers reaching it at once a
real, exercised scenario.

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
keep serving the rest of them. `cli/poller.pl` reports such a failure on
stderr (`TRANSCRIBE ERROR [chat_id] sender: <message>`) and continues.

## A single transcription can never block shutdown, or run unbounded

Voice transcription shells out to `whisper`, which can be slow (TGT-031,
a real production incident: it was found genuinely blocking the whole
poll loop, and `cli/poller.pl` was unresponsive to Ctrl+C for as long as
it ran). `D2TG::Transcribe::_run` is bounded by `$TIMEOUT` (default
300s) - a run that exceeds it is killed and reported as a normal
`TRANSCRIBE ERROR`, never blocks forever. `cli/poller.pl`'s `SIGTERM`/
`SIGINT` handlers also call `D2TG::Transcribe::kill_current` so an
in-flight transcription is killed immediately at shutdown time rather
than waited out.

## A long voice note gets a faster model instead of getting killed (TGT-100)

Live user request via the Telegram bridge, 2026-09-08, verbatim: *"Seems
like the tg poller cannot process any voice note bigger than 10 minutes.
Can it be dynamic, check the length of the voice note and use different
size of model?"* Root cause: `transcribe()` always used a fixed default
`medium` model regardless of audio length, and `$TIMEOUT` (300s, see the
section above) kills whatever `whisper` is running once it runs too long
- a long clip transcribed with `medium` could exceed that budget and be
killed, losing the transcript entirely instead of finishing more slowly.

`D2TG::Transcribe::select_model($duration_seconds)` tiers the model as a
starting guess: up to 5 minutes stays `medium` (today's quality,
unchanged for the common case), up to 15 minutes drops to `small`,
longer uses `base`. `transcribe()` measures the audio's actual duration
via `ffprobe` (a list-form pipe `open`, never a shell string, so the
audio path can never reach a shell) before choosing, unless the caller
passes an explicit `model` argument, which always wins.

**Follow-up (same ticket, after Michael measured this directly on his
own host):** duration-based tiering alone turned out to be
insufficient. The real limiting factor is per-host Whisper *throughput*,
not audio length, and that varies far more than a fixed duration
threshold can predict - `medium` measured at ~5.6x real time on his
host (no GPU, FP16 unsupported, falls back to FP32), so a 102.48-second
clip took 9m31s real time, well inside the original "stays on medium up
to 300s" threshold. His own reproduction: `time whisper <file> --model
medium ...` compared against `ffprobe`'s reported duration.

`transcribe()` now automatically retries at the next faster tier
(`medium` → `small` → `base`) whenever an *automatically-selected*
model's `whisper` run times out, instead of dying on the first timeout -
only a timeout at `base` itself (the fastest tier) produces a final,
single `TRANSCRIBE ERROR`. This guarantees correctness regardless of a
given host's actual measured speed, which the code can never know in
advance - the duration guess just picks a sensible starting point,
saving a doomed first attempt on an obviously-long clip. An
explicitly-passed `model` is never automatically retried on timeout -
explicit still means explicit, unchanged from before this follow-up.

## A voice note gets an immediate "processing" notice, not silence (TGT-100)

Live user request via the Telegram bridge, 2026-09-08, verbatim (msg
#137/#138): *"So in this incident print a message notify the agent it
will take long to transcribe instead of blind wait, before starting the
long transcription. So the agent will notice and tell the user the got
it but need time to process so everyone would be informed."* -> *"Fold
this in too."* Folded into the same ticket as the throughput/retry work
above, per his own instruction.

Transcription can genuinely block a poll cycle for several real minutes
(measured: ~9m31s for a 102-second clip on a slow host). Before this,
the only stdout output for a voice message was the final `NEW TG VOICE`
line once transcription finished (or failed) - the watching agent had no
way to know a voice note had even been received until the whole wait was
over. `D2TG::Poller::run_once` now prints `NEW TG VOICE [chat_id]
sender: transcribing... (this may take a few minutes)` immediately, before
the blocking `transcribe_voice` call, so the agent can acknowledge
receipt right away ("got it, processing") instead of the sender hearing
nothing until the real transcript line arrives afterward.

## A transcription's own console output never reaches the watched stream

`whisper` prints its own chatter (warnings, language-detection lines,
per-segment transcript output) to its own stdout/stderr by default.
Confirmed live (TGT-030, Michael sent a voice message): this was
inherited straight onto the poller's real stdout, polluting the exact
stream a Tira monitor job's feeder reads. `D2TG::Transcribe::_run`'s
forked child now reopens its own stdout/stderr onto `/dev/null` before
exec, so only this project's own structured lines (`NEW TG VOICE`,
`TRANSCRIBE ERROR`, etc.) ever reach the real stream. `D2TG::TTS::_run`
(TGT-033) applies the same principle on the outbound side - `gtts-cli`/
`ffmpeg`'s own console output never leaks onto `d2 tg.reply`'s
stdout/stderr either.

## The poll loop itself survives transient failures

Beyond individual voice/media failures (above), the poll cycle itself
(`get_updates`) can fail transiently - a network blip, a momentary
Telegram-side error. `run_once_safe` (TGT-028, a real production
incident: an uncaught transient failure once silently killed the whole
poller) catches this, logs `POLL ERROR: <message>` to stderr, waits a
short backoff, and retries - the poller process itself must never die
from a failure that will very likely resolve on its own.

## A single poll cycle can never block shutdown for longer than ~50s

Confirmed live (TGT-035, a real production incident caught on screen
recording): even after TGT-031's transcription-timeout fix, `Ctrl+C`
still would not stop the poller - Michael had to force-kill it. Root
cause: `D2TG::Telegram`'s default `LWP::UserAgent` had no explicit
timeout, so a single `get_updates` call (which Telegram itself may hold
open for up to its own `timeout` parameter, default 30s) could block
for LWP's own 180s default instead - and since Perl defers signal
handling until the current blocking call returns, that also bounded how
long `SIGINT`/`SIGTERM` could be delayed. `D2TG::Telegram::new` now sets
an explicit `timeout => DEFAULT_HARD_TIMEOUT` on its default `ua`, so a
single poll cycle - and therefore shutdown delay - is genuinely bounded,
not merely assumed to be.

That bound turned out to still have a gap (TGT-044, a second live
production incident): `LWP::UserAgent`'s own `timeout` did not reliably
cover a request stuck in the initial TCP `connect()` phase - the live
poller was found with its socket wedged in `SYN-SENT` far past the bound,
and even `SIGTERM` could not stop it (Perl only delivers a pending signal
once the blocking syscall it's inside of returns - `SIGKILL` was needed).
`D2TG::Telegram::_call` now wraps its request in an explicit
`alarm()`/`SIGALRM`-based hard timeout, which reliably interrupts any
blocking syscall - including a stuck `connect()` - regardless of which
phase it's stuck in, so the bound above is now actually enforced in
every case, not just the ones LWP's own timeout happens to cover.

A third live incident (TGT-066) found the bound itself (35s at the time)
left only a 5s margin over `get_updates`' own 30s long-poll wait - too
tight for real network/TLS/latency overhead, so a perfectly legitimate,
successful long-poll response occasionally exceeded 35s total and was
mistaken for a genuinely stuck connection, producing repeated "request
timed out after 35s" errors under completely normal operation.
`DEFAULT_HARD_TIMEOUT` is now 50s - a 15s margin - and both the real
production `ua`'s own timeout and the SIGALRM fallback derive from the
exact same constant, so the two values can never silently drift apart
again the way a bare `timeout => 35` literal once could.

## The startup line confirms which credentials actually loaded, without exposing them

Live request (TGT-045, raised while diagnosing TGT-044's incident): the
startup line used to only confirm C<D2TG_TOKEN> was non-empty
("token set: yes"), giving no way to tell WHICH token or chat id
actually loaded - relevant precisely when debugging a stale-terminal or
wrong-project situation. It now prints the token masked to its first and
last 4 characters and the chat_id in full (not a secret, a Telegram user
id), so an operator can confirm the right credentials without a live
secret ever appearing in full on the console/monitor feed.

## A message is only marked read once the agent has actually replied to it

Live design request (TGT-046): now that every message has a known id
(TGT-040) and is recorded in D2TG::Store (TGT-038), it also carries a
read/unread status. `d2 tg.reply --reply-to-message-id <id>` marks that
message read - but only *after* the reply has actually been sent
successfully (both the voice and text sends). If synthesis or either
send fails, the message stays unread, matching this skill's existing
"never claim success that didn't happen" principle for replies
themselves. A message nothing has ever replied to stays unread
indefinitely - there is no separate "mark as seen" action.

## Unread messages are always discoverable, not just visible in scrollback

Live design follow-up (TGT-047): before `d2 tg.unread`, the only way to
know what was still outstanding was to remember or scroll back through
the poller's own stdout/monitor-bridge history. `d2 tg.unread` now lists
every stored message not yet marked read (TGT-046), so "what's still
waiting for a reply?" always has a direct answer instead of relying on
scrollback.

## Stored message history is browsable, not just queryable by unread status

Live design follow-up (TGT-048): `d2 tg.unread` (TGT-047) answers "what's
outstanding" but not "what happened recently" or "what happened in this
window." `d2 tg.history` fills that gap: defaults to the 10 most recent
stored messages, or an explicit `--since`/`--until` range, independent of
read/unread status.

## Storage must relocate to a named Developer Dashboard path - there is no default

Live design request (TGT-051): every `d2 tg.*` command accepts
`--db <alias>`/`-d <alias>` (or `D2TG_DB=<alias>` as a fallback), naming
one of `d2 paths`' own entries. When given, both the SQLite state file
and downloaded attachments relocate under that alias's directory
instead of the skill's own install location - an unknown alias refuses
to start rather than silently falling back to the default, so a typo
can never silently write to the wrong place.

Live follow-up (TGT-059): the owner's original request was that omitting
`--db`/`-d`/`D2TG_DB` entirely should also refuse to start, matching
`D2TG_CHAT_ID`'s existing hard guard - TGT-051's shipped implementation
missed this, silently falling back to the skill's own install directory
instead. Every `d2 tg.*` command now refuses to start (same STDERR
message shape, pointing at `d2 paths`) whenever neither the flag nor the
env var is given at all, not only when a given alias is unknown. There
is no longer any way to run a `d2 tg.*` command without an explicit
storage location.

## Downloaded attachments are deduplicated by content, not just by name

Live design request (TGT-051): a photo/document download is named by
its own SHA256 content hash rather than a random/original filename -
identical content sent by any sender, at any time, only ever occupies
one copy of disk space. This applies only to attachments that are
actually kept (photo/document); the transient voice download used only
for transcription (and deleted immediately after) deliberately does not
use this shared, deduplicated location, to avoid the unlink after
transcription ever risking deletion of a still-referenced file that
happens to share the same content hash.

## The attachment vault never grows unbounded

Live design request (TGT-052, following TGT-051's content-addressed
storage): the poller prunes the attachment vault after every poll
cycle, keeping it at or under a 100MB cap. Once exceeded, the oldest
files (by modification time) are deleted first until back under the
cap - a vault already under the cap is left completely untouched.
Because attachments are content-addressed (TGT-051), pruning an old
copy can never orphan anything still referenced elsewhere: the same
content, if needed again later, is simply re-downloaded and re-written
under its same hash-derived name.

## A re-sent (deduplicated) attachment counts as freshly used, not stale

Bugfix (TGT-054, found via a scheduled bug-hunt pass, not user-reported):
when a photo/document is re-sent and its content already exists in the
vault (a dedup hit), the existing file's modification time is refreshed
to now, even though its content is not rewritten. Without this, a
popular file re-sent many times would keep the modification time of its
very first download, making pruning (above) treat it as the *oldest*
file in the vault - deleting it ahead of a truly stale file that was
only ever downloaded once, just more recently. Refreshing the
modification time on every dedup hit makes pruning behave as intended:
least-recently-used, not least-recently-created.

## One poller process can serve multiple bots and chats

Live design request (TGT-049, confirmed via follow-up Q&A): `d2
tg.poller` accepts repeatable `--chat_id`/`--bot` pairs, polling every
bot under its own chat id's allow-list, sequentially round-robin in one
process each poll cycle - never a forked child per bot, keeping the
same simple single-loop architecture this skill has always used.
`D2TG_CHAT_ID`/`D2TG_TOKEN` are never a special-cased fallback: they
fold into the exact same grouping rule as an implicit trailing
`--chat_id`/`--bot` pair, which is precisely what makes today's plain
env-var-only usage (no CLI args at all) come out byte-identical to this
skill's original single-bot behavior - an existing install upgrades
with no migration step, and there is exactly one grouping code path to
reason about, not two.

## Each bot's own poll offset, and a live token, are never confused

A companion consequence of TGT-049: since Telegram gives every bot
token its own independent update sequence, each bot now gets its own
persisted poll offset - but the offset's storage key is the bot's
token run through SHA256 first, never the raw token itself, so a live
credential is never written into the SQLite `meta` table in plaintext.
The original single-bot case keeps using the exact same unhashed
`offset` key it always has, so nothing about upgrading an existing
install changes.

## A bot token never appears in full on a shared board (TGT-086)

Found by the scheduled hourly bug hunt, 2026-09-08: the multi-bot
`REPLY WITH` template (TGT-057) was printing the receiving bot's full,
unmasked token to stdout on every single inbound message. Poller stdout
is designed (per this project's own architecture decision) to flow into
the target project's `tira.policy.bridge` as `monitor-output` events -
a shared board, not a private log - so this broadcast a real credential
(whoever has it can send/receive as that bot) far more often than the
one place this project had already taken care to mask a token
(`cli/poller.pl`'s own startup line, TGT-045).

Fixed by routing the `--bot <token>` value in the printed template
through the same `D2TG::Config::masked_token` helper the startup line
already uses (first 4...last 4 characters). This closes the leak
completely, but at a real cost: the printed template in multi-bot mode
is no longer directly runnable as-is - whoever runs `d2 tg.reply` for
that chat must supply the real token themselves (their own
`D2TG_TOKEN`, or direct knowledge of which bot serves which chat). A
design that would keep the template fully self-contained (e.g. `d2
tg.reply` resolving a masked value back to the real token from a locally
known bot pool) was considered and rejected for this ticket's scope -
`cli/reply.pl` runs as its own fresh process with no access to the poller's
own `--chat_id`/`--bot` CLI arguments, which today exist only in that
other, already-exited process's argv, not in anything `cli/reply.pl` could
read. Single-bot/env-only mode (`D2TG_TOKEN` alone) was never affected -
it never printed `--bot` at all.

## No systemd, no cron

The poller is meant to be registered as a Tira monitor-kind job on the
project it serves, not started by systemd or cron. This keeps the
poller's lifecycle visible on the same board that tracks everything else
about the project, instead of in an OS-level service list nobody is
watching (Q-003).

## The poller refreshes itself when a new version is installed

Owner request (TGT-036): since there is deliberately no systemd/cron to
restart the poller for you, it restarts itself instead. After every poll
cycle it compares its own on-disk `VERSION` to the one it started with;
if `dashboard skills install tg` has installed something newer in the
meantime, it disconnects its DB handle and re-execs itself in place
(same PID, same Tira monitor-job tracking) - a fresh Perl interpreter
then loads the newly-installed code. A version change never interrupts
an in-progress shutdown (`SIGTERM`/`SIGINT` still takes priority).

**BUGFIX (TGT-094, live production incident):** the re-exec originally
targeted the literal `$0` path captured at launch. `TGT-093` renamed
every `cli/*` script to add a `.pl` extension while a real poller
(JOB-007) was mid-poll; its version check fired, tried to
`exec($^X, $0, ...)` against the now-renamed-away `cli/poller`, and died
with `Can't open perl script ... No such file or directory` instead of
restarting - a real ~1 minute outage, recovered manually via
`d2 tira.job.stop`/`.start` (whose own command, `d2 tg.poller`,
re-dispatches through `SkillDispatcher` rather than trusting a stale
path). Fixed: the restart now calls
`D2TG::Config::resolve_self_exec_path`, which re-checks its own bin
directory for the current `poller.pl` basename at restart time -
resilient to a rename because only the filename changed, not the
directory - falling back to `$0` only if that lookup fails.

## Re-acquiring the poller's own lock never touches the lock file (TGT-102)

Bug-hunt finding (JOB-003, investigating `D2TG::Lock.pm` fresh): the
version-triggered self-restart above (TGT-036/TGT-094) `exec()`s in
place, keeping the same PID - which means every such restart re-enters
`D2TG::Lock::acquire` holding a lock file that already names its own
`$$`. Before this fix, `acquire` had no explicit fast-path for that case:
it fell through into the fallback reclaim path and
unlinked+recreated the lock file even though the PID was neither stale
nor dead. That opened a narrow race window - between the unlink and the
atomic `O_CREAT|O_EXCL` recreate - where an independently-started second
poller instance's own `acquire()` could land, read the just-recreated
PID as a live conflict, and (per TGT-084's own "last one wins" policy)
correctly issue a real `SIGKILL` against the legitimately self-restarting
process. Reproduced live in a `developer-dashboard:latest`-equivalent
Docker container: one process repeatedly re-acquiring its own held lock,
a second timed to land mid-churn - it read the recreated PID and killed
the first, exactly as designed for a genuine conflict, but this was not
one. This is plausibly the real root cause of this project's earlier,
previously-unexplained "poller monitor job died silently, no Perl-level
error" incidents.

`acquire` now returns success immediately when the lock file already
names the caller's own PID, before ever reaching the reclaim or
live-conflict-kill logic - the file is never unlinked, recreated, or
otherwise touched on that path. TGT-084's existing behavior for a
genuinely different, live PID (kill-and-take-over) and for a genuinely
dead PID (atomic reclaim) is unchanged.

## An unrecognized poller flag refuses instead of silently starting a poll loop (TGT-107)

Live-experienced incident (user-supplied feedback, 2026-09-08): running
`d2 tg.poller --help` to check usage did not print help and did not
error - `--help` was silently accepted as an ordinary, ignored
argument, and the process proceeded to acquire the lock and start a
real, long-running poll loop. Because this skill's own lock enforces
"last one wins" (TGT-084 - a new poller `SIGKILL`s whichever process
already holds the lock), that stray instance immediately killed the
legitimate, Tira-job-managed poller already running. The stray instance
then ran unnoticed until it was caught as a leftover background task,
and the real poller had to be restarted by hand.

`cli/poller.pl` now validates its own arguments fully before the
storage location or lock are ever touched: `--help`/`-h` (checked
first, before even `--db`/`-d` is parsed) prints a short usage summary
and exits 0; any other argument that isn't `--db`/`-d` or a valid
`--chat_id`/`--bot` group refuses with a clear error naming the
specific unrecognized token, exit 1. Acquiring the lock is itself the
dangerous side effect here, not merely entering the poll loop - so the
fix validates argv completely first, rather than only guarding the
point where polling itself would begin. A related, pre-existing
ordering quirk was tightened as a byproduct: the `D2TG_CHAT_ID`-missing
guard used to run *after* the lock was already acquired (so a
misconfigured poller could still evict a live one before then failing
its own guard) - it now runs before the lock too. Every
previously-recognized flag (`--db`/`-d`/`--chat_id`/`--bot`) keeps its
exact existing behavior.

## Recovering from a voice-only send failure never duplicates the text (TGT-109)

Live-experienced incident (user-supplied feedback, 2026-09-08): a reply
sent through `d2 tg.reply` had its text half delivered successfully,
then its voice half timed out (`sendVoice ... timed out after 50s`).
TGT-083's deliberate text-first-then-voice ordering makes this possible
by design - a voice failure can no longer prevent the text half from
having already gone out - but it also means there was no way to retry
*only* the voice half afterward: running the same `d2 tg.reply` command
again would resend the text too, producing a visible duplicate.

`d2 tg.reply --voice-only <chat_id> <text...>` (via
`D2TG::Reply::resend_voice`) synthesizes and sends only a voice note for
`text`, never calling `send_message` at all. A synthesis or `send_voice`
failure on this path still dies loudly (non-zero exit), matching the
normal reply's own fail-loud convention - it just never risks
duplicating text that already reached the chat.

## Pushing a local file back to a chat (TGT-103)

User-supplied feature-gap analysis, 2026-09-08: the old `~/skills/tg`
blueprint had two dedicated senders (one for images, one for any other
file type) that took a local file path and pushed it to Telegram as a
photo or document message. This skill had no outbound-media primitive
at all until `d2 tg.send` - inbound media (arriving FROM the owner) has
always worked fully via `D2TG::Download`; the gap was entirely on the
outbound side.

`D2TG::Telegram::send_photo`/`send_document` mirror `send_voice`'s own
multipart pattern via a shared `_send_file` helper. Whether a file sends
as a photo or a document is decided purely by its extension
(`.jpg`/`.jpeg`/`.png`/`.gif`/`.webp` send as a photo, everything else
as a document) - no content sniffing, since Telegram accepts any file
type via `sendDocument` regardless of what it actually contains.
`chat_id` is validated numeric and the file's existence on disk is
checked before any network call, matching this skill's existing
fail-fast conventions (the same shape as `cli/reply.pl`'s own guards).

## A monitor job's own command must not trust the shell that (re)starts it (TGT-118)

Live operational incident, 2026-09-08: this project's own message history
and attachment vault were found sitting at `/tmp/.tira/` instead of the
project's real, durable storage location. Root cause was **not** a bug
in `D2TG::Config::resolve_alias_dir` (it resolved exactly as designed)
and **not** a persistent misconfiguration in any project `.env` file
(none set `D2TG_DB` at all) - it was an environment variable
(`D2TG_DB=test`, a real `d2 paths` alias that legitimately resolves to
`/tmp`) present in one interactive session's own shell. Every time that
session restarted the poller's Tira monitor job from that shell (`d2
tira.job.stop`/`.start`, done to recover from an unrelated stuck-poller
incident), the newly-spawned process inherited whatever env that shell
happened to have - including a variable nobody had deliberately set for
this project.

Fixed at the most durable point available: the job's own command
definition (`d2 tira.job.update --id JOB-007 --command "env -u D2TG_DB
d2 tg.poller ..."`) now explicitly strips `D2TG_DB` before every future
invocation, regardless of which shell or session restarts it - not a
one-off manual `unset` that the next restart could just as easily
reintroduce. Verified live: a fresh restart's own `/proc/<pid>/environ`
confirmed `D2TG_DB` absent and `TIRA_HOME=tg` used instead, with
`telegram.messages.db` landing at the correct, durable path. The `/tmp`
history accumulated during the misconfigured window was not migrated,
per the owner's own explicit choice - accepted as low-value, not lost by
oversight.

**Lesson for any future job restart on this or another project**: a Tira
monitor job's own command is a more durable place to pin required
environment state than trusting whatever env the shell issuing `job.stop`/
`job.start` happens to carry - that shell's env is not part of this
project's own configuration and can silently vary between sessions,
terminals, or restart circumstances.

## Checking whether the poller is alive never risks evicting it (TGT-111)

User-supplied feature-gap analysis, 2026-09-08: the only way to know
whether the poller was actually alive used to be reaching into Tira job
metadata (`pid`/`last_output_at`) from outside this skill entirely -
useful, but not something the skill itself could answer.

`d2 tg.status` answers it directly via a new `D2TG::Lock::is_held` - a
pure, read-only liveness probe. This deliberately does **not** reuse
`D2TG::Lock::acquire` to check: doing so would risk evicting a
genuinely live poller under this skill's own "last one wins" policy
(TGT-084) just to answer a status question, which would make checking
status itself a way to take the bot offline - exactly the class of
danger TGT-107 already closed for `cli/poller.pl`'s own argv handling.
`is_held` only ever sends a harmless `kill(0, $pid)` probe (no real
signal delivered) and never touches the lock file itself.

## "Alive" and "still genuinely cycling" are different questions (TGT-116)

Live-experienced incident: a poller was confirmed alive (holding its
lock, in a normal sleeping process state) and had been for over 80
minutes, but had not produced a single line of output - not even a
routine `POLL ERROR` - in that entire window, and a real voice note sent
during it never arrived anywhere. Nothing distinguished "genuinely
cycling through poll cycles" from "silently wedged" from outside, since
a live PID and a held lock are both true in either case.

`cli/poller.pl` now writes a heartbeat (`D2TG::Config::write_heartbeat`,
mirroring `lock_path`'s own `.tira/` vault resolution, written atomically
via a temp file + `rename`) after each bot/chat pair's own poll cycle,
unconditionally - regardless of whether any message or error activity
happened. `d2 tg.status` reports the heartbeat's age and flags it
`STALE` past 1200 seconds. (A Codex review caught that writing only once
per full multi-pair cycle, against a tighter 600s threshold, could
falsely flag a healthy, actively-transcribing poller as stale - a single
voice transcription's retry ladder alone can take up to ~900s.)

Deliberately **not** built here: an automatic restart when the heartbeat
goes stale. A genuinely stuck poller cannot restart itself - that's the
nature of the failure - so acting on staleness needs an external actor:
either a second, always-running watchdog process (which would recreate
exactly the kind of standing supervisor this project's architecture
deliberately avoids, per Q-003's own "no systemd/crontab" decision), or
a Tira-scheduled job that periodically checks `d2 tg.status` and
restarts the monitor job if stale. Either is an operational/architecture
decision, not a code change to make unilaterally - flagged as a
follow-up requiring the owner's own input, matching this project's
standing pattern for exactly this class of decision (e.g. TGT-098's
Q-008, TGT-118's Q-009/Q-010).

## An agent can always self-serve this skill's own documentation

Live request (TGT-089): `d2 tg.help` prints `SKILLS.md` then
`docs/commands.md` in full, so an agent unfamiliar with this skill can
learn how to use it without already knowing the skill's own install
path on disk - a fresh Developer Dashboard skill install gives no other
way to reach either file via `d2 tg.*` itself. Deliberately requires no
environment variables or `--db`/`-d`/`D2TG_DB` at all (unlike every
other `d2 tg.*` command) - it touches no state, network, or credentials,
only two static files that ship with the skill, so the mandatory
storage-location guard (TGT-059) does not apply here.

## A photo/document's caption is never silently dropped

Live production incident (TGT-092): Michael sent a photo with a
Telegram caption describing a real problem to solve - the poller's
`NEW TG MEDIA` line only ever printed the media kind and downloaded
local path, never `$message->{caption}` (a field the Bot API attaches
to photo/document messages, separate from `$message->{text}`, which is
only present for plain text messages). The caption was silently
dropped: never printed, never stored, never reaching the agent watching
the bridge - a genuine, in-the-moment miscommunication, not a
hypothetical. Fixed: a present caption is sanitized the same way
inbound text already is (TGT-039) and appended to both the printed line
and the stored message summary; a message with no caption (the common
case) is unaffected.

## An orphaned poller instance is reported, never silently killed on a guess

Live-experienced incident (TGT-113): a poller crashed mid-version-bump
race, never auto-restarted, and a SEPARATE orphaned instance - under a
different PID, with a stale command line missing `-d tira` - was found
still running the entire time, competing for the same bot token's
`getUpdates` queue. TGT-084's own "last one wins" lock-eviction only
ever sees whichever single PID the lock FILE currently names; it has no
way to notice a second live process that never touched that file at all.

`D2TG::Lock::find_other_pollers` scans `/proc/<pid>/cmdline` for other
live processes whose argv contains an element matching a poller-shaped
pattern (default `(?:^|/)poller\.pl$`, anchored to a whole basename or
path ending in it), excluding the caller's own PID. `cli/poller.pl` runs
this check immediately after acquiring its own lock and, if it finds
anything, warns on STDERR naming the PID(s) - it deliberately never acts
on this by killing anything itself: a cmdline pattern match is a
point-in-time, best-effort signal, not proof of identity (a matching
process can start or exit around the scan, and PIDs can be reused), so
this skill only ever surfaces the finding for a human to investigate.

A Codex review caught that the first draft matched an unanchored
substring against the whole cmdline joined with spaces (replacing the
kernel's own NUL separators) - false-positiving on `not-a-poller.pl`,
`poller.pl.bak`, `--note=poller.pl`, and even a match spanning two
unrelated argv elements. Fixed by matching each NUL-split argv element
on its own against the anchored pattern.

## A failed media download is queued for retry, not lost after one report

User-supplied feature-gap analysis (TGT-104): the old `~/skills/tg`
blueprint kept a small on-disk queue recording which message and
Telegram's own internal file handle failed to download. The new
`d2 tg.*` skill reported a download failure once (`MEDIA DOWNLOAD
ERROR ...`) and moved on - no queue, no retry, exactly the loss mode the
old queue existed to close (motivated by a real prior incident: a
receipt sent for safekeeping was lost when its download failed and was
never retried).

`D2TG::Poller` now attempts to persist each such failure (a database
write failure at this point is itself non-fatal, matching the download
failure it's recording - see below) - chat_id, message_id, file_id,
sender, media kind, caption, the original error - to `D2TG::Store`'s
`failed_downloads` queue, keyed uniquely by `(chat_id, message_id)` so
Telegram's own at-least-once delivery redelivering the same failed
update refreshes the existing row instead of duplicating it (a Codex
review finding). The queue write itself is wrapped in its own `eval` -
a locked/full SQLite database must not turn an already-non-fatal
download error into a poll-cycle failure (another Codex finding).

`d2 tg.retry-download` lists the queue and retries a given id (or
`--all`) via `D2TG::Download::retry_failed_download`, which requests a
fresh download using the saved `file_id` (a Codex review, backed by a
web search of Telegram's own Bot API docs, corrected an earlier draft
of this project's own reasoning: a `file_id` itself isn't documented as
expiring on a short fixed clock - it's the one-hour-valid `file_path` a
`getFile` call resolves it to that's short-lived, and a fresh `getFile`
call, which every retry already makes, gets a fresh one; retrying is
still genuinely useful for the transient failures - network hiccups,
momentary server errors - this queue actually targets). A successful
retry restores the message into `D2TG::Store`'s own history via
`record_message` - the same thing a first-time success already does -
before removing the queue row (a Codex review caught an earlier design
only deleted the row, leaving nothing for `d2 tg.history`/`d2 tg.unread`
to ever show for a recovered file). A failed retry leaves the row
untouched. If Telegram's own response to the retry says the file is
permanently gone ("file is no longer available"/"wrong file_id"), the
message says `RETRY EXPIRED` - a classification of that specific
response text, not proof a time-based expiry occurred - deliberately
NOT for "file is temporarily unavailable" (a Codex review caught an
earlier draft treating that genuinely transient wording as permanent
too, which would have told an operator to give up on something that
might still work).

## A reply that went out text-only is flagged after the fact

User-supplied feature-gap analysis (TGT-105): TGT-083 deliberately
reordered `D2TG::Reply::send_reply` to send text first, then
synthesize+send voice - a synthesis or `send_voice` failure after that
point can leave a reply text-only, always reported loudly (non-zero
exit) at the moment it happens. If that loud failure is missed (the
agent wasn't watching, the error scrolled past), there was previously no
way to find out later - exactly the gap the old blueprint's own checker
was built to close.

`D2TG::Store`'s new `sent_replies` table tracks this: `record_sent_text`
is called immediately after a text send succeeds, `record_sent_voice`
once the matching voice send also succeeds - a row whose
`voice_message_id` is still `NULL` IS the text-only condition, not a
separate boolean flag that could fall out of sync. `resend_voice`
(TGT-109's own recovery path) clears the flag the same way on a
successful recovery. `d2 tg.text-only-replies` lists every currently
flagged reply, exit 1 if anything is flagged.

Scoped by `bot_key` the same way `allow_list`/`pending` already are
(TGT-098's own lesson, a Codex review finding for this ticket): without
this, one bot's `--voice-only` recovery could select and clear a
DIFFERENT bot's still-genuinely-text-only flag for a chat_id shared by
more than one of this skill's configured bots. `record_sent_voice` also
warns loudly on STDERR (non-fatal) rather than silently no-op'ing when
no matching row exists (another Codex finding) - a locked/full database,
or a bot_key mismatch, used to hide exactly the kind of persistence gap
this feature exists to surface.

Known, accepted limitation (a Codex review finding): the text send and
its store record are two separate, non-atomic steps against two
separate systems - a process kill or a database error in the narrow
window between them would leave a genuinely-sent text message invisible
to this checker if its voice half then also fails. This mirrors `d2
tg.retry-download`'s own accepted best-effort tradeoff for its queue
write (TGT-104) - a substantial improvement over no record at all, not
a guarantee.

## The same reply text is never sent to the same chat twice within seconds

User-supplied feature-gap analysis (TGT-114): an accidentally re-run `d2
tg.reply` command, or a retry after a confirmed prior success whose
voice half then failed (TGT-083's own text-first-then-voice ordering,
TGT-105's own audit trail for exactly this outcome), previously had no
way to avoid delivering the identical text a second time.

`D2TG::Store::is_recent_duplicate_reply` checks whether the exact same
text was already sent to a chat under a given `bot_key` within a short
window (default 10 seconds), sourced from the same `sent_replies` table
TGT-105 already records into. `D2TG::Reply::send_reply` checks this
*before* calling `send_message` at all - dies immediately if a match is
found, so the duplicate never reaches Telegram in the first place.
Scoped by `bot_key` for the same TGT-098 reason every other multi-bot
check in this skill is: a Telegram group shared by more than one
configured bot must never let one bot's own recent send be mistaken for
a duplicate of a different bot's identical text to the same `chat_id`.

Accepted, documented limitations (a Codex review found these real but
out of proportion to solve for this skill's actual usage pattern - a
human-paced, single-operator CLI tool):

- Does not protect against retrying after an *ambiguous* `send_message`
  failure (the request errored/timed out without confirming whether
  Telegram actually received it) - only a *confirmed* prior success is
  ever checked against.
- Not an atomic guarantee under genuine concurrent callers - two truly
  simultaneous `send_reply` calls for the same text could both pass the
  check before either records its own send.
- The window comparison is second-granular (SQLite's own timestamp
  functions discard fractional seconds), so the true elapsed time can
  exceed the stated window by under a second.

A Codex review also caught a critical schema-migration gap before this
shipped: the `text` column this feature adds to `sent_replies` needed
the same `ALTER TABLE`-with-duplicate-tolerance pattern
`messages.read_at` already uses - a bare `CREATE TABLE IF NOT EXISTS` is
a no-op against a database that already has `sent_replies` from an
earlier install of TGT-105 alone, without this column.

## A read-only sanity check answers "which project is this poller for" safely

User-supplied feature-gap analysis (TGT-115): with several projects on
one host each running their own installed copy of this skill under
different Developer Dashboard path aliases, there was no cheap way to
confirm which project's bot token/chat id/storage location a given
shell's env vars actually resolve to - short of reading env vars by
hand, or risking a real poller startup or reply send just to find out.

`d2 tg.whoami` prints the masked token, the configured `chat_id`, and
the resolved storage/attachments location. It makes **no HTTP request
at all** - `cli/whoami.pl` never loads `D2TG::Telegram` (a Codex review
strengthened this project's own test to also tripwire on any of the
other raw HTTP-client modules this project uses elsewhere, or a
`system()`/shell-out, not just `D2TG::Telegram` specifically), so it is
always safe to run, even with a completely unconfigured or
misconfigured token - the intended first sanity check before trusting
anything else this skill reports.

`chat_id` and the resolved storage paths are printed in full, not
masked - a deliberate choice, not an oversight (a Codex review raised
this as an information-disclosure question): printing an unmasked
`chat_id` matches `cli/poller.pl`'s own existing startup-line precedent
(TGT-045). The resolved storage/attachments paths are additional
operational information this command adds beyond that precedent, not
something already exposed elsewhere - a second Codex review pass caught
that an earlier draft overstated this as "no more exposure overall,"
which only actually holds for the token/chat_id half of the output.

## Poller stdout/stderr always carry an explicit UTF-8 layer (TGT-117)

Live-experienced incident: a real inbound Cantonese voice-note
transcript triggered a repeated `Wide character in print at
.../D2TG/Poller.pm line 83` warning - `D2TG::Poller` prints message
text via an unqualified `print` (Perl's currently selected default
output handle, ordinarily `STDOUT`) without opening it with a UTF-8
layer itself; that's this project's own entrypoint's job, not the
library's. Never fatal (the message was still
processed and delivered correctly regardless), just noise on every
non-Latin-1 message, and noise that could mask a genuinely new warning
of the same shape later. `cli/poller.pl` now opens both `STDOUT` and
`STDERR` with `:encoding(UTF-8)` at startup (before option handling and
any poller work), so every print/warn path reached through this
entrypoint - including `--help`'s own usage text and the
`POLL ERROR`/`MEDIA DOWNLOAD ERROR` lines already documented above - is
covered. `D2TG::Poller` itself remains intentionally handle/layer-agnostic
for any other caller. This is scoped to `cli/poller.pl`'s own output streams only;
it does not change the unrelated UTF-8 *decode* fix `D2TG::Reply` already
has for outbound reply text (TGT-073, documented above).

## The fallback media branch records history the same way every other branch does (TGT-120)

Found via a scheduled bug-hunt: `D2TG::Poller::run_once`'s catch-all
`else` branch (fires when a photo/document/voice message arrives whose
applicable callback - `download_media` for photo/document,
`transcribe_voice` for voice - was not given) printed the
`NEW TG MEDIA` line and the `REPLY WITH` template, but - unlike every
other successful branch (text, transcribed voice, downloaded photo/
document) - never called `$store->record_message`. A message handled
this way was invisible to `d2 tg.history`/`d2 tg.unread` afterward, and
a later reply-context lookup for it would fall back to a generic media-
kind label instead of the actual stored summary. Not exercised by this
project's own `cli/poller.pl`, which always supplies both callbacks -
but it was a genuine, silently-unverified gap in `run_once`'s
general-purpose API contract, confirmed by extending
`t/09-media-recognition.t`'s existing no-callback test cases to assert
on the store, not just stdout. Now fixed: this branch records the
message the same way every other branch does.

## The --help usage text and its own POD SYNOPSIS are kept consistent by a test (TGT-119)

Found via a scheduled improvement hunt reviewing TGT-107: `cli/poller.pl`
prints its `--help` usage text via a series of `print` statements, and
separately documents the same flag list in its own POD `SYNOPSIS` -
nothing enforced the two stayed consistent with each other, so a flag
added, renamed, or removed in one and forgotten in the other would
silently drift with no test failure. `t/88-poller-help-pod-parity.t`
extracts every flag name from both and asserts they name the same set -
it caught a real drift immediately (`-h` was documented in `--help`'s
own text but missing from the `SYNOPSIS`), now fixed. The test itself
is the ongoing enforcement mechanism: any future edit to one without the
other now fails the suite.

## d2 tg.history refuses on an unrecognized flag or leftover argument (TGT-122)

Found via a scheduled hourly bug-hunt: `cli/history.pl` parsed
`--since`/`--until` into a local accumulator but never checked
afterward that nothing unrecognized remained in `@ARGV` - unlike
`cli/send.pl` (checks `@extra`, refuses) or `cli/poller.pl` (refuses on
any unrecognized flag, TGT-107). Live-reproduced before the fix: both a
typo'd flag (`--totally-bogus-flag`) and garbage positional arguments
printed `No messages found.` and exited 0, exactly as if a well-formed,
correctly-scoped query had simply matched nothing - silently masking
operator error instead of surfacing it. Now exits 2 with a `Usage:`
message. `--db`/`-d` is unaffected: it is consumed by
`D2TG::Config::extract_db_flag` earlier still, before the
`--since`/`--until` loop (and this new check) ever run.
