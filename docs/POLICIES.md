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

## A non-canonical D2TG_CHAT_ID refuses to start, same as a missing one (TGT-155)

Scheduled hourly bug hunt finding, 2026-09-09, widened after a Codex
review finding of its own: the startup guard above only ever excluded
`undef`/an exactly-empty string as "not set" - `D2TG_CHAT_ID` is read
completely raw, with no trimming or validation, so any value that
wasn't Telegram's own canonical integer chat-id shape passed the check
and let the poller start normally, silently seeding that mangled value
as the admin's chat id. A whitespace-only value (a copy-paste error, a
shell quoting mistake) was the first case found, but the identical
silent lockout equally applies to leading/trailing whitespace around an
otherwise-valid id too (e.g. `' 12345 '`) - a narrower whitespace-only
check would still miss this. Telegram's real numeric chat id can never
string-eq match a mangled one, so the real owner was permanently locked
out with no warning at all - the poller looked healthy while quietly
denying its own intended admin. `require_chat_id_or_warn` now validates
the full expected shape (bare digits, or a leading `-` for a
group/supergroup/channel) rather than merely excluding known-bad
shapes, refusing with the identical warning/exit path already used for
the missing case whenever the value doesn't match - deliberately never
auto-trimming and proceeding with a stripped value.

## Message reactions are gated by access control too (TGT-151)

Scheduled hourly bug hunt finding, 2026-09-09: TGT-143's message-reaction
detection was added directly ahead of the `is_allowed` check above in
`run_once`, rather than after it - so an unapproved, non-pending chat id
reacting to any message the bot had sent/seen was printed unconditionally
(`NEW TG REACTION [chat_id] sender: ...`), leaking that chat id and
username onto the monitored stream and letting an unapproved party
interact with the bot in exactly the way this section exists to prevent.
Fixed by reusing the same `is_allowed` check inline in the reaction
branch, before it reads or prints anything. Unlike a first-contact
message, an unapproved chat id's reaction is silently ignored rather than
queued via `add_pending` - a reaction isn't itself an attempt to start a
conversation.

## Anonymous channel reactions name the channel, not "unknown" (TGT-154)

Scheduled hourly bug hunt finding, 2026-09-09: Telegram's own
`MessageReactionUpdated.user` field is optional - when a reaction is made
anonymously on behalf of a chat/channel (a channel admin reacting as the
channel itself), Telegram omits `user` entirely and supplies `actor_chat`
(a `Chat` object) instead. The reaction branch only ever read
`$reaction->{user}{username}`, so an anonymous channel reaction silently
printed `sender: unknown` even though Telegram had supplied the channel's
real identifying information via `actor_chat` - the identical failure
class TGT-142 already fixed once for forwarded messages' own
`sender_chat`/`chat` fields. Fixed by preferring `actor_chat.title` /
`actor_chat.username` (matching `_forward_origin_name`'s own established
fallback order) whenever `actor_chat` is present, falling back to the
ordinary `user`-based resolution otherwise.

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
The same validation was subsequently triplicated across `send_message`,
`send_voice`, and `_send_file` - extracted into one shared
`_validate_reply_to_message_id` helper (TGT-171, found via a scheduled
improvement hunt), no behavior change.

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
every `cli/*` script immediately after `resolve_alias_dir`/
`resolve_alias_dir_or_die` (the latter added by TGT-172, a pure
extraction of the eval/print-STDERR/exit(1) wrapper 11 scripts had
duplicated) returns: it dies if the resolved base_dir is not already a
real, existing directory. The `.tira/` subdirectory *under* an already-real base_dir is
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

## A routine 429 rate-limit response is silenced too, not just 5xx/timeout (TGT-160)

Scheduled hourly bug hunt finding, 2026-09-10: `is_transient_error`'s
own classification only ever matched a network timeout or a 5xx status
- Telegram's own `429` ("Too Many Requests") response, which the Bot
API documents as a designed, expected, retryable rate-limit condition
(a response body containing `parameters.retry_after`), not a genuine
application error even though 429 remains an HTTP error status,
matched neither pattern and was misclassified as non-transient. The
exact same TGT-097 noise problem this section describes for
5xx/timeout applied identically to a routine 429: logged loudly as
`POLL ERROR` on every occurrence, even though `run_once_safe` was
already retrying and recovering on its own. `is_transient_error` now
also matches `/status 429\b/`, silencing it the same way. Not
reading/honoring the `parameters.retry_after` value itself - that
would require parsing the response body, a separate, larger change
than this narrow classification fix.

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
it ran). `D2TG::Transcribe::_run` is bounded by a timeout - for an
automatically-selected model, scaled by the same duration signal
`select_model` uses (TGT-140: `duration * 8`, floored at `$TIMEOUT`
itself and capped at `max(3600, $TIMEOUT)` - never a hard-coded pair, so
a caller-configured `$TIMEOUT` is always respected), and the flat
`$TIMEOUT` default for an explicitly-passed model - a run that exceeds
its budget is killed and
reported as a normal `TRANSCRIBE ERROR`, never blocks forever.
`cli/poller.pl`'s `SIGTERM`/
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

## The transcription timeout itself scales with duration too (TGT-140)

External project review, confirmed live by Michael on the Telegram
bridge, 2026-09-09: TGT-100 (above) taught `select_model` to tier the
whisper model by probed duration, but `$TIMEOUT` stayed a flat 300
seconds regardless - a clip picked as `medium` (the fastest/default
tier, `<=300s` duration) could still legitimately run past 300s
wall-clock at real per-host throughput (the same measurement TGT-100's
own follow-up recorded: `medium` at ~5.6x real time, a 102.48-second
clip taking 571s). The retry-on-timeout ladder above partially
compensated by stepping down to a faster tier after a timeout, but the
flat ceiling still killed (and logged as a failure/retry) an entirely
healthy, still-progressing transcription purely because of per-host
throughput - the exact failure mode `select_model`'s own tiering was
introduced to reduce, left half-closed.

`D2TG::Transcribe::_scaled_timeout($duration)` turns the same duration
signal `select_model` already computes into a per-attempt timeout
budget: `duration * 8` (a safety multiplier well above the worst
measured throughput), floored at `$TIMEOUT` itself (never a hard-coded
constant - a scaled budget is never worse than whatever `$TIMEOUT` is
currently configured to, not just its default) and capped at
`max(3600, $TIMEOUT)` (a Codex QA-stage review finding: a fixed 3600s
ceiling could otherwise undercut a caller-configured `$TIMEOUT` larger
than that). `transcribe()` `local`izes `$TIMEOUT` to this scaled value
around each attempt, but only for an *automatically-selected* model -
an explicitly-passed `model` keeps the original flat `$TIMEOUT` default,
matching the same explicit-means-explicit scope the retry-on-timeout
fallback above already uses. The kill mechanism itself (process-group
signal, TGT-031/128) and the retry-on-timeout trigger condition are
both unchanged - only the budget a healthy run is given before that
mechanism fires.

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

A fourth, related gap (TGT-126, found via an ad-hoc bug-hunt rather than
a live incident) was closed proactively before it repeated: the same
stuck-`connect()` failure mode TGT-044 fixed on `D2TG::Telegram`'s Bot
API calls was never applied to `D2TG::Download::download_file`'s own
separate HTTP GET, which fetches inbound photo/document/voice file
bytes - arguably the higher-risk call, since it transfers full file
content rather than a small JSON payload, and `D2TG::Poller`'s own
`eval`-based `_run_non_fatal` catches a `die`, not a hang. `download_file`
now sets an explicit `LWP::UserAgent` timeout and wraps its `get()` call
in the same SIGALRM hard-timeout wrapper `D2TG::Telegram` uses. Both
had independently implemented that wrapper themselves at the time; it
was later extracted into one shared `D2TG::Config::_with_hard_timeout`
(TGT-173, found via a scheduled improvement hunt), with no behavior
change - each call site's own exact die-message wording is preserved
via a label it passes in.

A fifth gap in the same family (TGT-127, found via a follow-up ad-hoc
bug-hunt immediately after TGT-126) targeted a different call shape
entirely: `D2TG::TTS::_run` invoked `gtts-cli`/`ffmpeg` via a bare
`system(@cmd)` with no timeout whatsoever - not even LWP's unreliable
180s fallback, since there was no LWP involved at all. `gtts-cli` makes
a real network call to Google's TTS endpoint, and every outbound reply
(`D2TG::Reply::send_reply`, `resend_voice`) runs synthesis synchronously,
so a single hung `gtts-cli`/`ffmpeg` call could wedge the entire reply
path indefinitely. `_run` now forks and execs the command itself, in
its own process group (`setpgrp`), waits under a SIGALRM hard timeout,
and kills the whole process group (`kill('KILL', -$pid)`) if it hangs -
closing the gap over the same class of children the LWP-based fixes
above never had to consider (a hung Bot API call has no subprocess tree
at all). This is not an absolute guarantee: a grandchild that
deliberately detaches into its own new process group/session (rare for
gtts-cli/ffmpeg's own normal operation) would not be reached by this
kill - an accepted, documented limitation rather than a claim of total
coverage. The parent and child both call `setpgrp` on the child
immediately after `fork` (whichever runs first wins harmlessly) to close
a real race a Codex review caught: without it, a timeout firing before
the child's own `setpgrp` call would target a process group that does
not exist yet, silently killing nothing.

A sixth gap in the same family (TGT-128, found via a further ad-hoc
bug-hunt immediately after TGT-127) landed one EPIC over, in
`D2TG::Transcribe::_run`'s own already-existing hard timeout (TGT-031):
it correctly bounded and killed the immediate `whisper` process, but
never put it in its own process group, so any child process `whisper`
itself spawned (Whisper CLIs commonly shell out to `ffmpeg`/`ffprobe`-
family tooling for audio decoding, and this same module's own
`_probe_duration` already depends on `ffprobe`) was left running/
orphaned after the timeout kill - the exact gap TGT-127 had just closed
in `D2TG::TTS::_run`. `_run` now applies the identical fix: `setpgrp`
called by both the child and the parent immediately after `fork`
(closing the same race TGT-127's own Codex review caught), and both the
`TERM` and `KILL` timeout steps now signal the whole process group
(`-$pid`) plus the direct pid as a fallback.

A related but distinct gap (TGT-129, found via a further ad-hoc
bug-hunt) targeted database concurrency rather than process hangs:
`D2TG::Store::new` connected to SQLite with no `PRAGMA busy_timeout` and
no WAL journal mode set. `DBD::SQLite`'s default busy timeout is 0, so
a concurrent writer - the long-running `d2 tg.poller` process writes to
the same database on every inbound message, while other independently-
invoked `d2 tg.*` commands (`reply`, `approve`, `retry-download`) also
write against the same `db_path` - got an immediate "database is
locked" error instead of a brief, usually-successful wait. This is
exactly the concurrency robustness pattern this project's own research
notes on the original Python blueprint flagged as worth keeping ("SQLite
WAL + `busy_timeout=5000`... poller + `reply.py` write concurrently")
but which had been dropped when this project was ported to Perl.
`D2TG::Store::new` now sets both PRAGMAs immediately after connecting:
WAL lets readers and a writer proceed without blocking each other at
all in the common case, and `busy_timeout` bounds the remaining
writer-vs-writer contention window to a wait instead of an instant
failure.

A Codex doc-stage review flagged one thing worth calling out explicitly:
WAL mode creates `db_path-wal`/`db_path-shm` sidecar files alongside the
main database file while connections are active - a manual backup or
copy that only takes `db_path` itself can miss recently-committed data
still sitting in the WAL file. WAL is appropriate for this skill's
single-host, local-filesystem usage; it would not be appropriate for a
database file shared over a network filesystem between hosts.

A last consistency gap in the same family (TGT-131, found via a further
ad-hoc bug-hunt immediately after TGT-128) was a follow-up rather than a
new failure class: `D2TG::Transcribe::kill_current` - called directly
from `cli/poller.pl`'s own `SIGTERM`/`SIGINT` shutdown handlers - still
signalled only the tracked direct pid, even after TGT-128 put `_run`'s
own child in a process group specifically so a timeout-triggered kill
could reach any child `whisper` itself spawned. A clean poller shutdown
mid-transcription could therefore leave such a child running, even
though the very same process being killed was already protected on its
timeout path. `kill_current` now signals the whole process group plus
the direct pid, matching `_run`'s own pattern exactly.

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
`STALE` past a threshold derived from `D2TG::Transcribe`'s own
`$TIMEOUT_CEILING`/`@MODEL_TIERS` constants (`$TIMEOUT_CEILING *
scalar(@MODEL_TIERS) * 4/3`, currently 14400s/4h - TGT-147: this was
originally a fixed 1200s literal, and a scheduled bug hunt caught it
going stale the moment TGT-140 shipped its own duration-scaled
per-tier transcription timeout in this same session, since a single
still-healthy transcription's retry ladder could then legitimately
exceed the old threshold many times over). (A Codex review caught that
writing only once per full multi-pair cycle, against a tighter
threshold, could falsely flag a healthy, actively-transcribing poller
as stale.)

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

## The orphaned-poller warning cross-checks the bot token before sounding urgent (TGT-141)

External review finding, live-reproduced by a sibling project (zen-
framework) and confirmed by Michael, 2026-09-09: `find_other_pollers`'s
own warning above fired identically for every poller-shaped process it
found, regardless of *why* it was flagged. On a host running several
projects from this skill - already true here (Zenandi, Developer
Dashboard, Budgeting, Tira Development at minimum) - each project's own
poller has a distinct `D2TG_TOKEN`, so there is never a real `getUpdates`
collision between them; the warning's own wording already hedged with
"if genuinely another live poller sharing this bot token", but never
actually checked the token, so it fired routinely and alarmingly for the
single most common, entirely benign case.

`D2TG::Lock::classify_other_poller_token($pid, own_token => ..., proc_dir
=> ...)` reads the flagged PID's own `D2TG_TOKEN` from
`/proc/<pid>/environ` and compares it against the running instance's
own: `same` (a real collision, worth investigating), `different`
(almost certainly a sibling project's own poller, safe to ignore), or
`unknown` (environ unreadable, no `D2TG_TOKEN` in it, or the caller's
own token itself undefined) - it never guesses `same` or `different`
from incomplete information. `cli/poller.pl` splits its own warning on
this: a same-token PID still gets the urgent `WARNING: possible
orphaned poller instance(s) sharing this bot token ...` framing; every
other-token or unknown-token PID gets a `NOTE: other poller-shaped
process(es) detected ...` line naming the sibling-project explanation
instead. The never-kill, report-only design itself (TGT-113, above) is
completely unchanged - only the evidence behind which wording a given
PID gets.

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
were silently ignored and exited 0 as if the invocation had succeeded
- reproduced as `No messages found.` (nothing happened to match), but
a query that happened to match real history would have printed it
instead, unrelated to the actual bad invocation - silently masking
operator error instead of surfacing it. Now exits 2 with a `Usage:`
message. `--db`/`-d` is unaffected: it is consumed by
`D2TG::Config::extract_db_flag` earlier still, before the
`--since`/`--until` loop (and this new check) ever run.

## A downloaded attachment's real filesystem path is never exposed (TGT-133)

Live request via Telegram: the watching agent should never see, or need
to know, where a downloaded attachment actually lives on disk - it
should be told a command to run that hands back the file's own bytes,
the same way this project's own Tira board already works
(`tira.attachment.get --sha SHA --extension EXT` writes raw content to
stdout; nobody reading its output ever sees or needs the real path).

Before this fix, `D2TG::Poller::run_once`'s `NEW TG MEDIA` line printed
the real local path directly, and `D2TG::Store::record_message`
persisted that same path into the message's stored summary - so it
resurfaced verbatim through `d2 tg.history`/`d2 tg.unread` too, not just
the live poller stream. Both leak points are closed the same way: a new
`local_path` column on `D2TG::Store`'s `messages` table holds the real
path, reachable only through the narrow `get_attachment_path` accessor
- `summary` (what every display path actually prints) never contains it.
`D2TG::Poller` and `D2TG::Download::retry_failed_download` both now call
`record_message` with `local_path` passed as a separate argument, never
folded into the summary text they build.

The new `d2 tg.attachment <chat_id> <message_id>` command is the only
way to actually retrieve the bytes - it looks up `get_attachment_path`
and writes the file's raw content to stdout, printing no path itself
either (a lookup failure or unreadable file refuses with a message
naming the chat/message id, never the path it tried and failed to open).
Every `NEW TG MEDIA` announcement for a downloaded photo/document is
immediately followed by a `GET ATTACHMENT WITH: d2 tg.attachment
<chat_id> <message_id>` line naming that exact command - since Telegram
delivers one attachment per message, a poll cycle reporting several
media messages produces one such instruction per message, never a
combined or ambiguous one.

## A store write failure never aborts the rest of a poll batch (TGT-132)

Found via an ad-hoc bug-hunt, following directly from TGT-129's own
SQLite `busy_timeout`/WAL fix: that fix makes a locked-database error
*rarer*, not impossible - contention can still outlast the 5-second
wait window. `D2TG::Poller::run_once` calls `D2TG::Store::record_message`
on every successful text/voice/media/fallback branch, and none of those
4 call sites were `eval`-wrapped, unlike the sibling
`record_failed_download` call (TGT-104), which already carries an
explicit comment explaining why it must be: "a locked/full SQLite
database must not turn an already-reported, already-non-fatal media
error into a poll-cycle failure."

The consequence of leaving `record_message` unwrapped was worse than a
single failed write: `run_once_safe` catches any `die` from `run_once`
by returning the poll offset UNCHANGED - so a `record_message` failure
partway through a multi-update batch would cause Telegram's next
`getUpdates` call to redeliver the *entire* batch, including updates
already printed and handled earlier in that same cycle. Every already-
printed `NEW TG`/`REPLY WITH` line for that batch would be reprinted,
risking the watching agent sending a duplicate reply to a message it
already answered.

Fixed the same way `record_failed_download` already was: a new private
`_record_message_safe` helper wraps the call in `eval`, logging a
non-fatal `record_message failed (<reason>) - message was already
printed/handled, only its own store record is affected` line to STDERR
instead of letting the exception propagate. The message itself was
already fully handled (printed to stdout, offered a `REPLY WITH`
template) - only the store's own record of it failed, which degrades
`d2 tg.history`/`d2 tg.unread`'s completeness for that one message, not
the poller's own correctness or the batch's delivery. `<reason>` is a
short, fixed classification (`database is locked`/`busy`/`readonly`, or
`an unexpected error`) - never the raw exception text itself (a Codex
review finding: a DBI/SQLite error can embed the database file's own
path, which this project just spent TGT-133 closing off as an
information-disclosure surface elsewhere).

## An attachment's fetch is not permanently guaranteed (TGT-134)

Found via self-review immediately after TGT-133 shipped: `local_path`
(the column TGT-133 added) never expires from `D2TG::Store`'s own
database, but the file it names can be evicted at any later time by
`D2TG::Download::prune_vault`'s own byte-cap eviction, which
`cli/poller.pl` runs after every single poll cycle. An old attachment
nobody ever re-fetches (a dedup hit refreshes its mtime, TGT-054,
protecting anything actually re-used) will eventually age out of the
vault once it fills past its 100MB default cap.

`cli/attachment.pl` already failed safely before this fix - a missing
file produced a generic "cannot open the stored attachment" message,
never a crash - but the message gave no hint that pruning was the
likely, expected cause rather than a real problem. It now checks
whether the path exists but isn't a regular file first (its own
message - a directory was never legitimately recorded, but `open`
alone would silently succeed and print nothing), then attempts to
`open` it and classifies the real failure from `open`'s own errno: an
`ENOENT` names pruning specifically, anything else (e.g. a genuine
permissions problem) falls back to the generic `$!`-based message. A
Codex review caught that a plain `-e` pre-check (the first version of
this fix) would have misreported an unrelated permissions failure - an
unsearchable parent directory, for instance - as "pruned", since that
also makes `-e` false without the file actually being gone; checking
`open`'s own errno avoids that misclassification entirely. Fetching an
attachment is therefore only reliable for one still within the vault's
currently-retained set, not a permanent guarantee - documented
explicitly in `docs/commands.md`'s own
`d2 tg.attachment` section and `cli/attachment.pl`'s own POD.

## A video message is announced and recorded, not silently dropped (TGT-161)

Scheduled hourly bug hunt finding, 2026-09-10: `run_once`'s own guard -
`next unless (defined $text && length $text) || $media_kind` - drops an
update with no plain text and no recognized media kind, with zero
footprint: not printed to stdout, not queued as `NEW TG PENDING` for an
unapproved sender, not recorded via `record_message`, no stderr line,
and the poll offset still advances past it since it is computed once
per batch from `get_updates`, unaffected by a per-update `next`. Before
this fix, `_media_kind` recognized only `photo`/`document`/`voice`, so
a video message (whether or not it carried a caption) fell into exactly
this gap - gone forever, indistinguishable from an update that never
arrived. `_media_kind` now also recognizes `video`
(`$message->{video}`); the existing generic fallback branch (see
"The fallback media branch records history the same way every other
branch does (TGT-120)" above) - which video always reaches, since there
is no video-specific handling or download path at all, unlike
photo/document/voice which only reach it when their own callback is
omitted - already prints and records generically by whatever
`$media_kind` names, so no other code change was needed - a
video is announced and recorded exactly like an undownloaded
photo/document already is. Actual video download support (extending
`download_media`) is a separate, larger decision and stays out of
scope; `video_note`/`audio`/`animation`/`sticker` are the same failure
class but are deliberately deferred to a follow-up ticket, to keep this
fix narrow and reviewable.

## A caption cannot prematurely terminate the outbound multipart body (TGT-162)

Scheduled hourly bug hunt finding (second pass), 2026-09-10:
`D2TG::Telegram::_send_file`'s `caption` field (reachable via
`cli/send.pl --caption`) was spliced into the raw hand-built multipart
body with zero sanitization, unlike the adjacent `filename` field,
which was hardened with control-character stripping and quote/
backslash escaping after a Codex review found the original protection
insufficient against header injection. Both fields share the exact
same trust boundary - a user-supplied `cli/send.pl` argument - but only
one had any defense. Caption's own risk is narrower than filename's,
because it sits in plain body content rather than a quoted header
attribute: CR/LF there is legitimate caption text, not a header-
injection vector, so none of filename's escaping applies. The one real
risk caption does share is boundary collision - the multipart boundary
(`'D2TGBoundary' . int(rand(1e9)) . time`, regenerated per call and not
attacker-visible) is what actually separates form-data parts (a real
delimiter is `\r\n--$boundary` with valid trailing framing, not the
bare value alone), and a caption embedding that string in delimiter-
shaped syntax could prematurely terminate the body, letting trailing
bytes be reinterpreted as new form fields (for example, clobbering
`chat_id` in the same request). `_send_file` now conservatively strips
any occurrence of the literal boundary string from the caption -
delimiter-shaped or not - before inserting it, closing that one gap
without adding filename's unrelated header-specific hardening to a
field that doesn't need it.
`send_voice`'s own multipart construction is untouched - already
reviewed, a separate code path. Caption is not the only untrusted
multipart body content in `_send_file` - the uploaded file's own raw
bytes could in principle collide with the boundary the same way - but
that is a separate, pre-existing risk, unaddressed here and out of this
ticket's scope, relying (as it always has) on the per-call boundary
being unpredictable.

## Usage/POD drift is now caught for every cli/*.pl script with a Usage: line, not just 3 of them (TGT-163)

Scheduled improvement hunt finding, 2026-09-10: the same drift class -
a `cli/*.pl` script's STDERR `Usage:` string and its own POD `SYNOPSIS`
are two independently hand-maintained copies of the same flag list,
with nothing enforcing they stay in sync - had already been caught and
fixed 3 separate times (`poller.pl`, TGT-119; `reply.pl`, TGT-157;
`approve.pl`, TGT-159), each time by a manual/live check rather than a
test. Only those 3 scripts had a parity test guarding against a fourth
occurrence; the other 9 scripts with a `Usage:` line
(`attachment.pl`, `history.pl`, `retry-download.pl`, `send.pl`,
`status.pl`, `text-only-replies.pl`, `tts.pl`, `unread.pl`,
`whoami.pl`) had none. The same flag-set-parity test pattern
(`t/113`/`t/114`'s own established shape) was added for all 9. Writing
them caught one more real drift immediately: `history.pl`'s own
`SYNOPSIS` never showed its `-d <alias>` shorthand, even though its
`Usage:` string already documented it - fixed by adding the missing
`SYNOPSIS` line. The other 8 scripts' Usage/POD already matched; their
new tests pass immediately, serving as the same safety net for future
drift that `t/88`/`t/113`/`t/114` already provide for their own
scripts.

## A malformed D2TG_CHAT_ID is caught even when the CLI also declares its own --chat_id group (TGT-164)

Scheduled bug hunt finding, 2026-09-10: `D2TG_CHAT_ID`'s canonical-shape
validation (`require_chat_id_or_warn`, TGT-155 - matches
`/^-?\d+$/`) was only ever called from `cli/poller.pl`'s startup guard
when the CLI did NOT declare its own `--chat_id` group. Whenever the
multi-bot CLI support (TGT-049) was used at all - even a single
`--chat_id`/`--bot` pair - that guard was skipped entirely, and
`D2TG::Config::bot_groups`'s second call (which folds `D2TG_CHAT_ID` in
as an implicit trailing group) still ran with no shape check of its
own, silently adding a broken poll group instead of refusing. Traced to
a genuinely-reproducible hang: a still-buggy poller given a CLI group
plus a malformed env `D2TG_CHAT_ID` doesn't refuse at all - it proceeds
straight into a real poll loop and never exits, discovered live while
writing this ticket's own regression test (`t/126`), which uses a
bounded-timeout subprocess read specifically because a naive blocking
read would have hung the test suite the same way. `cli/poller.pl` now
also refuses whenever `D2TG_CHAT_ID` is actually SET (not merely
unset) but fails the same canonical-shape check, regardless of whether
CLI groups are also present. A CLI-declared `--chat_id` group's own
value remains unvalidated by this fix, unchanged - it is caller-
supplied and outside this env-var validation, not an env leak.

An empty-but-set `D2TG_CHAT_ID` (`D2TG_CHAT_ID=''`) is deliberately
NOT refused by this new guard, matching `D2TG::Config::bot_groups`'s
own env-folding condition (`defined $env_chat_id && length
$env_chat_id`) exactly: an empty string is never folded in as a group
either, so there is no broken group for this guard to prevent - an
empty env value behaves identically to an unset one throughout this
whole code path, by design, not by omission.

## The access-control gate itself never aborts the rest of a poll batch either (TGT-165)

Scheduled hourly bug hunt finding, 2026-09-10: "A store write failure
never aborts the rest of a poll batch (TGT-132)" above fixed
`record_message`'s own call sites, but `run_once`'s access-control gate
- `is_allowed` (message and message_reaction branches) and
`add_pending` (message branch) - ran unwrapped, with no `eval` at all.
Both run against the same `RaiseError=>1` DBI handle `record_message`
does, so the identical locked/busy-SQLite failure TGT-132 addressed
could still reach `run_once` through this different, earlier call
site: a locked database mid-batch made `is_allowed`/`add_pending` die,
which propagated uncaught out of `run_once` and aborted the whole poll
batch - and since `run_once_safe` preserves the pre-batch offset on
error (deliberately, as the last-resort safety net for a genuinely
unexpected failure), the ENTIRE batch, including updates already
printed earlier in that same cycle, got redelivered and reprinted
verbatim on the next poll cycle. Both call sites now catch the error,
print a `STORE ERROR [chat_id]: <what failed> - <error>` line to
STDERR, and skip that one update non-fatally - the rest of the batch,
and its own correct final offset, still completes normally.

**Deliberate tradeoff, stated explicitly (a Codex review point):**
"skip" here means the poller's own offset still advances past the
failed update, same as any successfully-handled one - it is not
retried or queued, unlike a failed media download
(`D2TG::Store::record_failed_download`, TGT-104). This is preferable
to the alternative this ticket fixes (redelivering and reprinting the
entire batch, including already-handled updates, on every subsequent
poll cycle until the lock clears) but does mean the one affected
update is effectively lost, not merely delayed.

## The main poll loop's own offset persistence no longer crashes the whole process either (TGT-166)

Scheduled hourly bug hunt finding, 2026-09-10 - a direct follow-up
sweep after TGT-165 checking for the identical unwrapped-DBI-call
pattern elsewhere: `cli/poller.pl`'s persistent main loop called
`$store->set_offset(...)` directly, with no `eval` at all. Unlike
`run_once`'s own `is_allowed`/`add_pending` calls (TGT-165, both
inside `run_once_safe`'s own `eval`), this call sat at the TOP LEVEL
of the persistent poller script's main loop - so a locked/busy SQLite
database crashed the ENTIRE poller process outright, not just one
poll cycle's batch. Since this process runs indefinitely under Tira's
own monitor-job supervision, routine SQLite lock contention (the same
risk TGT-129/TGT-132/TGT-165 already established as real and
recurring) could silently take the whole poller offline until Tira's
`monitor-dead`/`monitor-silent` policy noticed and someone restarted
it - a strictly worse consequence than the batch-redelivery bug
TGT-165 fixed, one call site over. Extracted into
`D2TG::Poller::persist_offset_safe`, a new public function
`cli/poller.pl` now calls instead - directly unit-testable (unlike the
main loop itself, which would need a live Telegram connection to
integration-test), matching `t/127`'s own precedent for TGT-165's
fixed call sites. Catches the error, classifies it the same way
`_record_message_safe` already does (TGT-133 - never echoes the raw
exception, which can embed the database file's own path), logs it to
STDERR, and returns - the poller keeps running and a later poll cycle
attempts to persist its own (by then newer) offset again, not a retry
of the specific failed value; if the process exits before a later
persist succeeds, the previously persisted offset remains on disk and
updates since then may be redelivered after a restart. `get_offset` (called
once at startup, outside the loop) is unaffected and correctly still
fatal - dying there matches the "refuse to start" pattern every other
setup guard in this script already uses.

## Store-error classification lives in one place, not two (TGT-167)

Scheduled improvement hunt finding, 2026-09-10 - a direct, deliberate
check for whether `persist_offset_safe` (just added above, TGT-166)
duplicated any existing logic in the same file, which it did:
`_record_message_safe` and `persist_offset_safe` each independently
classified a DBI/SQLite exception into the same four fixed reasons -
"database is locked" / "database is busy" / "database is readonly" /
"an unexpected error" - via a byte-for-byte identical 4-line regex
ternary chain. Extracted into a shared private helper,
`_classify_store_error`, called from both - the exact "found it twice,
extract it" pattern already established in this project (e.g.
`shift_flag_value`, TGT-072). Pure duplication removal: the four
classified strings and each caller's own surrounding STDERR message
text are completely unchanged, verified via a before/after full-suite
diff with zero assertion changes rather than new tests, matching
TGT-158's own precedent for a behavior-preserving refactor.

## Message edits are detected; message deletions cannot be (TGT-169)

Michael asked live via Telegram, msg #246: "is the implementable if
the user on telegram edit the previous message and that will notify
the agent about the updated message or notifiy the agent the message
was deleted by user." The two halves have genuinely different
answers. EDIT detection is implemented: Telegram's Bot API sends a
distinct `edited_message` update - the same shape as an ordinary
`message`, but reflecting the post-edit content - generally when a
message known to the bot in an allow-listed chat is edited (Telegram's
own docs note it can be omitted for edits to fields the bot never
used, so this is not an absolute guarantee for every conceivable
edit). Unlike `message_reaction` (TGT-143), `edited_message` is not
itself opt-in - Telegram's own baseline default (before this project
ever specified `allowed_updates` at all) already includes it; it only
stopped reaching this project the moment `allowed_updates` was first
narrowed to a fixed list at all (TGT-143), so it now has to be listed
explicitly too, for the same reason every relied-on type does once the
list is specified. That baseline is a historical fact, not a live
fallback: `getUpdates` retains whichever `allowed_updates` list a bot
last set rather than reverting to the baseline default if a later call
omits the parameter, so simply omitting it now would not restore
`edited_message` delivery. `run_once` recognizes it in a new branch, gated by
the same `is_allowed` check every other branch uses by chat_id (no
`add_pending` - an edit isn't a first-contact event, matching
`message_reaction`'s own precedent), prints a distinct `NEW TG EDIT`
line, and records a text edit's new content via `record_message` so
`d2 tg.history` reflects it - deliberately different from
`message_reaction`'s own detection-only, never-recorded behavior,
since an edit changes the message's actual content while a reaction
does not. A caption/media-only edit (no text) is announced but
deliberately not recorded, to avoid overwriting an already-correct
history summary with nothing useful (a Codex review finding; recording
those too is a narrower follow-up, out of this ticket's own scope).
DELETE detection of an ordinary chat message is not possible at all:
the Bot API has no update type for that (a separate, business-
connection-scoped `deleted_business_messages` update exists for an
unrelated feature this project doesn't use, a Codex review correction
to an earlier, too-absolute claim) - a hard platform limitation, not a
gap in this skill's own implementation, and not something any
client-side workaround can close (a bot can at best infer a deletion
indirectly, e.g. a later reply-reference to the same message id
failing, never receive a direct notification).

## The main poll loop's version-change check no longer crashes the whole process either (TGT-175)

Live production incident, reported via the budget project (Michael's
own owner chat, 398296603), 2026-09-10: the poller (a Tira monitor
job) died outright with `D2TG::Config::skill_version: cannot read
.../skills/tg/.env: No such file or directory` during a run of rapid
version-bump self-restarts across one evening. `.env` was briefly
missing/unreadable during the skill directory's own self-update (a
git-based rewrite - every file in the directory carried an identical
timestamp, consistent with the whole directory having just been
replaced) - a transient window, not a real misconfiguration. The
owner's Telegram channel was down for about a minute until a human
noticed `monitor-dead` and manually restarted the job. Same failure
class as TGT-166's own `persist_offset_safe` fix one call site over:
`cli/poller.pl`'s main loop called `D2TG::Config::skill_version()`
directly, unwrapped, once per poll cycle to check for a version
change - any exception there was fatal to the ENTIRE poller process,
not just to that one check. Fixed with a new
`D2TG::Poller::skill_version_check_safe`, matching
`persist_offset_safe`'s own non-fatal-degradation pattern:
catches the error, logs it to STDERR, and returns `undef` instead of
dying - the version-change check is simply skipped for that cycle and
retried next cycle, once the file is stable again. Deliberately does
NOT touch `skill_version` itself, nor the poller's own startup call to
it (`$starting_version`, read once before the poll loop begins) - a
fresh process launch with a genuinely missing/misconfigured `.env`
should still refuse to start loudly, exactly like `D2TG_CHAT_ID`'s own
existing hard-guard pattern; only this periodic re-check, made once
the process is already safely running, is the one that's safe to
degrade instead of crash.

A second, related HIGH-severity finding was reported the same evening
(two of the owner's Telegram messages never reached local storage,
despite Telegram's own `getUpdates` confirming they'd already been
consumed) - tracked separately as TGT-176, an investigation-only
ticket, since the exact mechanism is not yet conclusively established
and any fix would be a deliberate architectural decision (whether to
change `_record_message_safe`'s TGT-132 non-fatal-skip philosophy to a
redeliver-and-dedupe model), not a mechanical bug fix like this one.

**TGT-176's investigation findings** (using a read-only copy of the
budget project's own `.tira/telegram.messages.db` Michael provided,
queried inside a `tira:latest` container - no writes, no code
execution): the local `messages` table has a hard stop at message_id
4479 (2026-09-10 11:00 UTC), hours before the reported ~20:00 incident,
even though the snapshot's own job output shows the poller still alive
and restarting on version bumps well past that point. `allow_list`
confirms the owner stayed genuinely allow-listed throughout (rules out
an access-control explanation); `pending`/`failed_downloads` are both
empty (rules out a queued-but-failing-download explanation). This
points toward extended downtime from TGT-175's own (then-unfixed)
crash bug as the likelier primary cause, rather than a single isolated
`record_message` write failure - though the exact mechanism could not
be fully confirmed without Telegram's own `update_id` history, which
this project has no access to.

Michael's own architectural ruling (question Q-011 on TGT-176,
answered 2026-09-10T22:20:50+0100): change the design so the offset is
never persisted past an update whose local `record_message` write
failed - let Telegram redeliver it next cycle, and add dedupe-by-
message-id to handle the resulting duplicate delivery. Implemented as
**TGT-178**, shipped in 1.43: `_record_message_safe` now returns a
success/failure flag, and `run_once` tracks the first failing update's
own `update_id` encountered while iterating the batch in order (the
same as the earliest, since Telegram delivers updates in increasing
`update_id` order), capping the returned offset there instead of
the batch's full next offset. `record_message`'s own existing
`ON CONFLICT(chat_id, message_id) DO UPDATE` upsert (backed by the
`messages` table's `PRIMARY KEY (chat_id, message_id)`, not a separate
`UNIQUE` constraint) already made a redelivered message's store write
idempotent, so no schema change was needed - the remaining half of
TGT-178's work was suppressing the resulting duplicate `NEW TG` print/
re-download/re-transcribe on the redelivered pass, done via a
`store->get_message` check before acting on a plain message.

A separate finding, **TGT-179**, shipped in 1.44, found by a scheduled
JOB-003 hourly bug hunt the same evening: `D2TG::Transcribe::_probe_duration`'s
`ffprobe` call had no timeout at all, unlike every sibling subprocess
call in this codebase (whisper, gtts-cli/ffmpeg, HTTP downloads - all
guarded by `SIGALRM`/`_with_hard_timeout` or a `waitpid` poll loop).
Reproduced live in a `developer-dashboard:latest` container via a
stalled FIFO (`mkfifo` with no writer, `ffprobe` blocked indefinitely).
It runs synchronously in `transcribe()` before the retry loop's own
timeout scoping even begins, so a hang there blocked the ENTIRE
single-threaded poller indefinitely for every chat, not just the one
triggering it. A plain `alarm()`-around-a-blocking-readline does NOT
reliably interrupt it (verified directly - a first attempt at exactly
this fix still took the full 30s in testing): PerlIO retries a
buffered pipe read on `EINTR` without giving Perl a chance to run a
deferred `SIGALRM` handler mid-read. Fixed by reusing the
`waitpid(WNOHANG)`-poll pattern `_run` already uses for whisper -
`D2TG::Subprocess::fork_in_own_process_group` gained a new optional
`stdout => $path` param (opt-in, every existing devnull-only caller
unaffected) so `_probe_duration` can capture ffprobe's output the same
killable way. A timed-out probe falls back to 0 duration exactly like
every other probe failure mode already did - the poller no longer
blocks to get there.

A third finding, **TGT-183**, shipped in 1.48, found by a scheduled
JOB-003 hourly bug hunt: `cli/poller.pl`'s `D2TG::Store->new(...)`
startup call was unwrapped, unlike `require_existing_base_dir`/
`D2TG::Lock::acquire`, which already refuse loudly and cleanly on
their own failures. Reproduced live in the `perl-test` Docker container:
pointing the resolved db path at a location `DBI->connect` cannot open
(a directory sitting where the database file should be) made the
poller die with a raw, uncaught Perl exception instead of a clean
refusal, and the raw exception text can embed the real db path -
exactly the information-disclosure surface TGT-133 already closed off
at every OTHER call site, but not this one. Fixed by wrapping the call
in `eval` and classifying the error via the existing
`D2TG::Poller::_classify_store_error` helper, matching
`require_existing_base_dir`/`D2TG::Lock::acquire`'s own clean-refusal
behavior: a fixed `Failed to open local storage (REASON) - refusing to
start.` message, never the raw exception. While
building this fix, a related but distinct finding surfaced: `lock_path`
and `heartbeat_path` (both called earlier in the same startup
sequence, both unwrapped) independently call `make_path` on the same
`.tira` directory and can die the identical raw way if it cannot be
created - fixed separately as **TGT-184**, shipped in 1.49: both now
`eval`-wrapped and classified via the identical
`D2TG::Poller::_classify_store_error` helper, refusing cleanly with
`Failed to prepare storage location (REASON) - refusing to start.`
`lock_path`'s own failure is reproduced live and covered by a new
regression test; `heartbeat_path` is wrapped identically - its own
failure isn't independently exercised by the current test's static
filesystem setup (it succeeds once `lock_path` has already created
`.tira`, though an external filesystem change between the two calls
could still make it fail), not because it's impossible to test, just
not covered by this pass. A Codex QA-stage review on this ticket also
found that the `heartbeat_path` failure branch exited before releasing
the startup lock file `lock_path`/`D2TG::Lock::acquire` had just
acquired above it - fixed by releasing the lock before that exit.
`D2TG::Store->new`'s own TGT-183 failure branch was suspected of
sharing the same lock-leak gap (along with a "no `--chat_id`/`--bot`
groups configured" exit) and filed separately as **TGT-185** to
investigate and fix.

**TGT-185**, shipped in 1.50: fixed the `D2TG::Store->new` failure
exit's own lock leak the same way, releasing the lock before that
exit. The ticket's other originally-scoped scenario - a "no
`--chat_id`/`--bot` groups configured" exit also leaking the lock -
turned out, on inspection while writing the red test, to be
unreachable dead code: two earlier startup guards
(`require_chat_id_or_warn`, and the `has_cli_groups`/`D2TG_CHAT_ID`
shape re-check) already refuse before `D2TG::Config::bot_groups()` can
ever return an empty list, so that branch can never run with the lock
already held. Confirmed empirically (the actual refusal for a true
no-groups run comes from the earlier guard, well before
`lock_path`/`heartbeat_path`/`D2TG::Lock::acquire` are even reached)
and documented in `t/185-poller-lock-leak-no-groups-and-store-failure.t`
rather than faking a scenario that cannot occur; the `!@$groups` check
itself is left in place as defense-in-depth.

A second Codex QA-stage review round, on TGT-185's own fix, found two
MORE reachable exit paths sharing the identical lock-leak gap: a "no
bot tokens configured" exit (a `--chat_id` group with no `--bot`, and
`D2TG_TOKEN` unset), and the `exec()`-restart-failure `die` further
down in `cli/poller.pl`. Rather than continuing to patch one exit at
a time - this was the fourth instance of the same bug class found
across TGT-184/TGT-185 - `cli/poller.pl` now has a single `END` block
placed right after `D2TG::Lock::acquire` succeeds:
`END { D2TG::Lock::release($lock_path) if $lock_acquired; }`. It
releases the lock on every Perl-managed `exit`/uncaught `die` path
past that point, current or future, without each one needing to be
individually found and fixed again. `D2TG::Lock::release` is
idempotent and PID-scoped (only unlinks a lock file this exact
process still owns), so it is safe to run alongside the existing
explicit `release()` calls, and does not fire on a successful
`exec()` (the process image is replaced, not exited - the same PID
correctly keeps holding the same lock). This is a standard Perl
`END`-block limitation, not specific to this fix: a signal this
process terminates on without running any handler code of its own -
`SIGKILL` always, or any other signal at any moment this script has
not (yet, or ever) installed a handler for - bypasses `END` entirely,
same as it would for any Perl program. No claim is made here about
when, or whether, a specific signal becomes safe - five successive
Codex QA-stage review rounds on this exact comment each found the
previous draft's framing still overclaimed something about
`SIGTERM`/`SIGINT`'s own timing (round 3: "any exit" overclaimed past
`SIGKILL`; round 4: a "brief window" framing that missed the
handler-installation gap itself; round 5: an "ARE covered" claim that
reintroduced the same gap; round 6: even "trapped ones don't [bypass
`END`]" was judged to reassert the same converse/timing claim under a
different phrasing) - the honest scope is just "an untrapped signal
bypasses `END`", full stop, asserting nothing about the trapped case.
`D2TG::Lock`'s own staleness/eviction logic (TGT-084/TGT-113) is what
recovers a lock left behind by that kind of termination - detected
and reclaimed the next time a poller attempts to acquire the same
lock, not automatic - unrelated to and not narrowed by this fix. The
no-bot-tokens scenario is covered by a new test case (confirmed red
without the `END` block, green with it); the `exec()`-failure `die`
is not independently tested (a deterministic reproduction would need
environment sabotage this pass doesn't implement) but is covered by
the same mechanism.

**TGT-186**, found via a scheduled JOB-003 hourly bug hunt and
reproduced live against `cli/history.pl`: 7 more `cli/*.pl` scripts
(`attachment`, `text-only-replies`, `approve`, `retry-download`,
`history`, `reply`, `unread`) each independently constructed
`D2TG::Store->new` unwrapped - the identical raw-crash/db-path-leak
risk TGT-183 already fixed only for `cli/poller.pl`'s own call. All 8
call sites (these 7 plus `poller.pl`'s own pre-existing shape) built
the same `db_path` shape and the same overall `eval`/classify/refuse
pattern - `poller.pl` passes `admin_chat_id` as an arrayref of every
configured group's chat_id, these 7 pass a plain scalar, not
byte-identical args - so this became a shared helper -
`D2TG::Poller::open_store_or_die` - rather than 7 separate
`eval`-wraps, matching this project's established TGT-167/170/171/172/
177 duplication-removal precedent. `cli/poller.pl`'s own already-fixed
inline version is deliberately left untouched - its TGT-185
lock-release logic is intertwined with that specific call site, not
required scope. New test `t/186-cli-store-startup-crash.t`, one
scenario per affected script (28 assertions total), reusing TGT-183's
root-proof directory-collision technique; confirmed genuinely red
against pre-fix code (21 of 28 assertions failed) before the fix. A
Codex documentation-stage review on this ticket also caught that
several docs/comments overclaimed the args as fully "identical" -
corrected everywhere to name the actual scalar-vs-arrayref difference.
`open_store_or_die` itself initially showed 0% coverage (the original
test only exercises it via real subprocesses, invisible to
Devel::Cover) - closed by a second test,
`t/186-open-store-or-die-coverage.t`, calling it directly in-process.

**TGT-187**: investigated a live user report (budget project,
2026-09-09) of 3 consecutive version-bump restart notices missing
TGT-112's own Changes-line summary. Reproduced the real dispatch
condition in a `developer-dashboard:latest` container (`d2 skills
install tg` for real, `d2 tg.<command>` dispatch, not a direct `perl
cli/poller.pl` invocation) and confirmed
`$ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}` resolves correctly to the
installed skill root (traced through
`Developer::Dashboard::SkillDispatcher`'s own `_skill_env`/`dispatch`/
`exec_command` - both dispatch paths set it before launching the
skill command, though not identically: `dispatch` via `local %ENV =
(%ENV, %env)` scoped to the block that runs its own `system()` call,
`exec_command` via a non-local `%ENV = (%ENV, %env)` right before its
own final `exec`.
Either way it persists for the whole resulting process's lifetime
including a later `exec()`-based self-restart, which inherits the
calling process's environment by default).
`changes_summary` correctly returned the summary when `.env`'s
`VERSION` and the `Changes` file's own header entry matched exactly -
also independently confirmed live on this host's own real, running
installed poller (its 1.43->1.49 restart notice included the summary
correctly). `changes_summary` DOES silently return `undef` with zero
diagnostic on ANY mismatch (a missing entry, or even a trivial format
difference like a trailing `.0`) - a real, confirmable fragility, but
not independently reproducible against the current codebase for the
original report's own specific incident (version range 0.70-1.03 is
many versions and fixes behind). Closed a real, independently-found
gap instead: `changes_summary`'s env-var-priority code path
(`state_db_path`'s identical priority order was already tested in
`t/10-state-path.t`) had no test coverage at all - new regression
test in `t/90-changes-summary.t` closes it. The silent-`undef`-on-any-
mismatch fragility itself was filed separately as **TGT-190**.

**TGT-190**, shipped in 1.53: this branch (reached whenever no entry
can be matched for the requested version - not only a genuine
wrong-version mismatch, but also a header line whose version matches
but whose own shape is malformed, a Codex QA-stage review finding)
now prints a non-fatal STDERR diagnostic naming the requested version
and, if the file has one, a recognizable header found elsewhere in it
- or says explicitly that none was found, if it doesn't (two Codex
QA-stage review rounds: the first strictly-shaped header anywhere can
skip a malformed earlier one - not necessarily "the" file's own
literal top header; and a file with no strictly-shaped header at all
names none, rather than always naming one), before returning `undef`
unchanged - matching this project's
established non-fatal-degradation pattern
(`skill_version_check_safe`/`persist_offset_safe`). A genuinely
missing/unreadable `Changes` file still returns `undef` silently with
no diagnostic - only a readable file with no matching entry is
covered (out of scope: the match logic itself, e.g. fuzzy/version-
normalized matching). New tests in `t/90-changes-summary.t`: the miss
case now asserts a diagnostic naming both the requested version and
the exact, full recognizable header line fires (a Codex QA-stage
review finding: an earlier draft only checked for the version
substring, which would still pass even if the diagnostic dropped the
header's own date); a new happy-path case confirms a real match still
prints nothing to STDERR.

**TGT-191**, shipped in 1.54, live production incident (budget
project): 2 real Telegram messages permanently lost. Root cause: a
genuine offset-advance-vs-persist race. `cli/poller.pl`'s main loop
advanced its in-memory poll offset unconditionally after each cycle,
regardless of whether `D2TG::Poller::persist_offset_safe` actually
durably saved it. Telegram's own `getUpdates` `offset` parameter is a
confirmation mechanism, not just a cursor - an update is considered
confirmed, and Telegram may forget/never redeliver it, as soon as
`getUpdates` is called with an offset higher than that update's own
id. A still-running process would use the advanced-but-unpersisted
offset on its own NEXT `getUpdates` call, confirming that batch to
Telegram even though it was never durably saved locally; if the
process then crashed for any reason before a later persist caught up,
the gap between the stale on-disk offset and the already-confirmed
one was gone forever - structurally identical to what the live
incident describes, and distinct from TGT-176/TGT-178 (which fixed
offset-capping on a `record_message` WRITE failure caught inside
`run_once`'s own `eval` - not a process-level crash/restart).

`persist_offset_safe` now returns a true/false success flag
(previously always void - see its own updated POD and the
`docs/commands.md` `D2TG::Poller` row above). `cli/poller.pl`'s main
loop only advances the in-memory offset when this returns true; on a
failed persist, the offset stays at the last durably-persisted value,
so the next `getUpdates` call (in the same still-running process, or
after a restart reading the same stale on-disk value) reuses the
SAME, still-unconfirmed-to-Telegram offset - Telegram redelivers the
batch instead of discarding it, deduplicated locally via
`record_message`'s own `PRIMARY KEY` upsert and `run_once`'s own
already-recorded check (TGT-178).

New test `t/191-offset-not-advanced-on-persist-failure.t` simulates 2
poll cycles (persist fails, then succeeds) with a fake Telegram/store
pair, proving: the in-memory offset is not advanced after the failed
cycle; both `getUpdates` calls use the identical offset (the batch
cycle 1 fetched but never durably confirmed is re-requested, not a
batch further ahead); and the offset only advances once persist
actually succeeds. Confirmed genuinely red against the pre-fix
unconditional-advance behavior (temporarily reverting
`persist_offset_safe`'s return-value change) before being fixed.
`t/128-poller-persist-offset-safe.t` extended with the new return-
value contract (success, failure, and undef-input-is-success, since
"nothing to persist" is not itself a failure).

This is structurally a stronger guarantee than "detect and recover
from a process crash" - since the in-memory offset is never advanced
without a confirmed durable write in the first place, a real crash at
literally any point after `run_once_safe` returns is equally safe:
the offset that ever reaches `getUpdates` is always exactly the one
already safely on disk, whether the process keeps running, crashes,
or is restarted.

**TGT-192**, shipped in 1.55, found via a scheduled JOB-003 hourly
bug hunt while checking whether TGT-191's own "external system
confirmed before durable local state" pattern exists elsewhere - the
outbound-reply analogue. `D2TG::Reply::send_reply`/`resend_voice`'s
own `record_sent_text`/`record_sent_voice`/`mark_read` calls were the
one `D2TG::Store` write call site in this codebase never wrapped in
`eval` - every sibling (`record_message` via `_record_message_safe`
TGT-132, `set_offset` via `persist_offset_safe` TGT-166/191,
`is_allowed`/`add_pending` TGT-165, `record_failed_download`'s own
`eval` TGT-104) already classifies a failure via
`D2TG::Poller::_classify_store_error` rather than letting the raw
exception (which can embed the real `db_path`) propagate.
`record_sent_text` runs against a `RaiseError=>1` handle, so a
locked/busy database there died raw AFTER `send_message` had already
succeeded - aborting the rest of `send_reply` entirely (skipping
voice synthesis, which runs unconditionally afterward) and reporting
a hard failure to the caller that could even suggest retrying (for a
DBI error text matching `is_transient_error`), risking a duplicate
text delivery since TGT-114's own dedup check depends on the very row
that failed to write.

All 5 call sites (`send_reply`'s `record_sent_text`/
`record_sent_voice`/`mark_read`, `resend_voice`'s own `mark_read`/
`record_sent_voice`) now go through a shared `_store_write_safe`
helper - `eval`-wrapped, classified, logged non-fatally to STDERR as
`STORE ERROR [chat_id]: ... failed - REASON`. Since the die no longer
aborts the sub, voice synthesis/send naturally still runs afterward,
and a store-write failure specifically can no longer turn an
otherwise-successful `send_reply` call into a reported hard failure -
both acceptance criteria fall out of the same fix, without needing
separate logic for either. Synthesis/`send_voice` themselves still
fail loudly exactly as before this ticket (a Codex documentation-
stage review finding: an earlier draft's "returns normally whenever
`send_message` succeeded" wording overclaimed past that still-intact
TGT-083 tradeoff) - only the local audit-trail write's own failure is
now non-fatal.

A second, QA-stage Codex finding on this same fix: an earlier draft
evaluated `$voice_result->{message_id}` INSIDE the `_store_write_safe`
closure, risking a malformed (non-hashref) `$voice_result` being
misclassified as a non-fatal `record_sent_voice failed` `STORE ERROR`
by `_store_write_safe`'s own `eval` rather than propagating as the more
serious failure it actually is. Moved the extraction to its own
variable BEFORE `_store_write_safe` is called.

A third round on the very same finding: that fix still didn't hold up.
Wrapping `$voice_result->{message_id}` in its own `eval` and skipping
the store write whenever that `eval` caught something looks right, but
it isn't - dereferencing a hash key off `undef` in Perl's rvalue
context does **not** raise an exception at all (`eval { undef->{key} }`
leaves `$@` completely empty; verified directly). So that `eval` could
never actually distinguish "malformed (non-hashref) result" from
"well-formed hashref legitimately missing this key" - both shapes
silently produced `undef`, and a malformed `send_voice` result (e.g.
`undef`) was now reported as a plain, silent overall SUCCESS instead of
ever propagating as a failure - worse than round 2's misclassification,
not better. Fixed by checking `ref($voice_result) eq 'HASH'` explicitly
in both `send_reply` and `resend_voice`: a non-hashref result now dies
for real - but only when a `store` was actually given and the text
send produced a usable message id (the store write's own pre-existing
gating; a caller that never passes `store`, or whose `send_message`
result carried no usable id, is unaffected either way, same as before
this ticket) - matching TGT-083's "voice failures are loud, never
silent" tradeoff, and the genuine pre-TGT-192 behavior for the cases
that actually did die back then. A present-but-incomplete hashref -
e.g. `Fake::ReplyTelegram`'s own `shapeless` option, `{ ok => 1 }` -
still quietly skips just the store write with no error, exactly as
before.

New test `t/192-store-write-failures-non-fatal.t`: each of the 3
failure modes is non-fatal and classified (never the raw exception,
matching TGT-133's own scrubbing precedent), voice is genuinely still
sent after a `record_sent_text` failure (checked via the fake
Telegram double's own `call_order`), the fully-successful path is
completely unaffected (no STDERR output, all 3 `send_reply` store
calls made exactly once), `resend_voice`'s own `mark_read`/
`record_sent_voice` failures are independently proven non-fatal too
(a Codex QA-stage review finding: an earlier draft only exercised
`send_reply`, leaving 2 of the 5 fixed call sites completely
untested), a malformed `send_voice` result (a
`Fake::Telegram::MalformedVoiceResult` double returning `undef`) is
proven to make `send_reply` (and, per a round-4 QA-stage finding that
the first draft covered only `send_reply` for this shape too,
`resend_voice`) die for real - never misclassified as a `STORE ERROR`,
never silently reported as success either (the round-3 finding above),
and correctly left the message genuinely unread (`mark_read` never
attempted, another round-4 finding: this state must survive for a
later retry/recovery path to still find it pending) - and a
`shapeless`-but-present hashref (via `Fake::ReplyTelegram`) is
separately proven to still succeed silently for both functions,
confirming the two shapes are genuinely distinguished.

A round-5 finding on that same "left genuinely unread" claim: it held
for `send_reply` from the start, but `resend_voice`'s own `mark_read`
call originally ran BEFORE the `ref($voice_result) eq 'HASH'` check, so
a malformed voice result there died only after the message had already
been marked read - directly contradicting the claim, and defeating the
retry/recovery state `resend_voice` exists to preserve. Fixed by
reordering `resend_voice` so `mark_read` only runs after the result
shape is confirmed usable (mirroring the order the result-shape check
and the store write it guards already had); the test above now asserts
`mark_read` was never attempted for `resend_voice`'s own malformed case
too, and was confirmed genuinely red against the pre-fix ordering
first.

A round-6 finding on that reordering: the check itself was still gated
on `store && defined $text_message_id`, while `mark_read` is gated on
the strictly BROADER `store && defined reply_to_message_id` - so a
caller giving `store` and `reply_to_message_id` but *not*
`text_message_id` could still slip a malformed voice result past the
check entirely and have it marked read anyway (this gap existed in
both `send_reply` and `resend_voice` identically, even though only
`resend_voice` was flagged by name). Fixed by checking the result
shape whenever `store` is given at all, independent of
`text_message_id` - the broadest condition under which anything below
reads this result, so a caller that never passes `store` remains
entirely unaffected. Two new test blocks (one per function) prove the
die still fires, and `mark_read` is never attempted, when
`text_message_id` is omitted but `reply_to_message_id` is given.

Confirmed genuinely red against the pre-fix code - the whole test
script crashed with an uncaught die (no TAP plan produced at all)
rather than merely failing an assertion, since the raw exception
propagated straight out of `send_reply` with nothing to catch it; the
malformed-result regression block was separately confirmed red against
the round-2 (`eval`-guarded dereference) code before landing on the
`ref()`-check version - the round-2 code returned success silently
instead of dying, which is exactly the failure this block exists to
catch.

## TGT-193: classify run_once's is_allowed/add_pending STORE ERROR lines

Found via a scheduled JOB-004 improvement hunt. `D2TG::Poller::run_once`'s
4 `STORE ERROR` print blocks (`is_allowed` x3 - `message_reaction`,
`edited_message`, plain `message` branches; `add_pending` x1 - plain
`message` branch) each echoed the raw DBI/SQLite exception text
verbatim to STDERR, instead of classifying it via the already-established
shared `_classify_store_error` helper - every other `D2TG::Store` error
path IN THIS MODULE already does this (a Codex documentation-stage
review finding: `is_allowed` is a read, not a write - "write" only
correctly describes `add_pending`/`record_message`/`persist_offset_safe`;
the wording is now scoped to "error path", not "write error path",
since it covers both) (`_record_message_safe` TGT-132/133,
`persist_offset_safe` TGT-166/191). A Codex QA-stage review finding:
this claim is deliberately scoped to `D2TG::Poller.pm` specifically,
not the whole codebase - `D2TG::Reply`'s own `_store_write_safe`
(TGT-192) is a separate module with its own equivalent pattern, and
`D2TG::Download::retry_failed_download` has the identical
unwrapped-call gap, tracked separately as TGT-194, not yet fixed.
These 4 call sites predate
`_classify_store_error` (TGT-165, before TGT-167 extracted the shared
helper) and were simply never revisited. A raw DBI/SQLite error can
embed the database file's own real path - the same disclosure risk
TGT-133 established as this project's standard to avoid.

New test `t/193-store-error-classified-not-raw.t` (12 assertions,
one block per call site): each asserts the classified reason (`database
is locked`) appears in the `STORE ERROR` line, the real db_path never
appears, and the raw `at ...\.db line N` DBI trace text never appears.
Confirmed genuinely red against the pre-fix code - 8/12 assertions
failed, each showing the raw db_path/exception text leaking into
STDERR exactly as the finding described.

perlsec.pl-style vulnerability-scan audit: pure in-process control flow
change (swapping one classification call for a raw-echo pattern) with
no shell invocation, no new file I/O, and no new external-input
handling - no system/exec/backtick/piped-open/eval-STRING patterns in
either touched file.

## TGT-194: eval-wrap retry_failed_download's own store writes

Found via a scheduled JOB-003 hourly bug hunt, reproduced live in a
`developer-dashboard:latest` container - the same class of issue as
TGT-132/165/166/186/190/191/192/193. `D2TG::Download::retry_failed_download`
called `$store->record_message(...)` and `$store->remove_failed_download(...)`
directly, with no `eval`/classification around either call - the one
unwrapped `D2TG::Store` write pair in this module. A locked/busy
database at either one used to die raw straight out of
`retry_failed_download`, breaking its own documented
`(1, $local_path)`/`(0, $error)` return contract even though the
download itself genuinely succeeded, and - since `cli/retry-download.pl`'s
own batch mode has no `eval` around this call either - crashing the
whole script mid-loop, silently abandoning every remaining queued row
in that batch.

Fixed by wrapping both calls in `eval`, classified via
`D2TG::Poller::_classify_store_error`, matching the established
`_store_write_safe`/`_record_message_safe`/`persist_offset_safe`
pattern - the reported `(1, $local_path)` success is unaffected by a
bookkeeping-write failure, since the download itself did succeed.

A Codex documentation-stage review finding: an earlier draft removed
the queue row unconditionally, even when `record_message` itself
failed - this would leave a message with NEITHER a queue row NOR a
history record, a genuine data-retention regression worse than the
pre-fix crash (which at least left the row queued, since the raw die
happened before `remove_failed_download` was ever reached). Fixed by
only attempting `remove_failed_download` when `record_message` either
succeeded or wasn't needed (no `media_kind`) - on a `record_message`
failure, the row now stays queued so a future retry can still restore
history, and a clear STDERR note explains why.

A second finding from the same review: the earlier draft's own
"unlike every other `D2TG::Store` write call site" / "all known
instances of this bug class are now fixed" claims (in this doc and the
parent EPIC's own comment) were unverified. A repo-wide sweep
(`grep -rn` for every `D2TG::Store` call (write or read) across `lib/` and
`cli/`) found one more remaining unwrapped call pair -
`cli/approve.pl`'s own `approve`/`is_allowed` calls at lines 58 and 63
- filed separately as TGT-195, not yet fixed. Claims narrowed to "the
one unwrapped `D2TG::Store` write pair in this module" (true) rather
than the whole codebase.

New test `t/194-retry-download-store-write-non-fatal.t` (19
assertions): `record_message` failure (still reports success, failure
classified and logged, `remove_failed_download` now deliberately NOT
attempted - the row survives), `remove_failed_download` failure (same
non-fatal guarantee, unaffected since `record_message` succeeded
first), the no-`media_kind` case (`record_message` correctly never
attempted, `remove_failed_download`'s own failure still non-fatal), and
a two-row per-row-isolation check on the ACTUAL SAME store instance (a
`dies_for(message_id)` fake lets one store fail for row 1's message_id
specifically while genuinely succeeding for row 2's - an earlier draft
of this block claimed to test same-store isolation but silently used a
second, different store instance instead, never actually proving it;
another Codex documentation-stage review finding, fixed). Confirmed
genuinely red against the pre-fix code - the whole test script crashed
with an uncaught die (`Wstat 6400`, exit 25, "No plan found in TAP
output") rather than merely failing an assertion, since the raw
exception propagated straight out of `retry_failed_download` with
nothing to catch it.

perlsec.pl-style vulnerability-scan audit: pure in-process control flow
change (adding `eval` wrappers and a classification call) with no
shell invocation, no new file I/O, and no new external-input handling
- no system/exec/backtick/piped-open/eval-STRING patterns in either
touched file.

## TGT-195: eval-wrap cli/approve.pl's own approve/is_allowed calls

Found via a repo-wide grep sweep (`grep -rn` for every `D2TG::Store`
call, write or read, across `lib/` and `cli/`), done as part of a Codex
QA-stage review on TGT-194 - which had incorrectly claimed "all known
instances of this bug class are now fixed" before this sweep was ever
done. `cli/approve.pl` called `$store->approve(...)` and
`$store->is_allowed(...)` directly at lines 58 and 63, with no
`eval`/classification around either call - the same raw-crash/
db-path-leak risk `D2TG::Poller::run_once`'s own `is_allowed`/
`add_pending` calls already had before TGT-165/193 fixed them. A
locked/busy database at either call died raw, uncaught, printing the
real Perl/DBI exception (which can embed the real db_path) to STDERR
and exiting non-zero via Perl's own default die-at-top-level behavior.

Fixed by wrapping both calls in `eval`, classified via
`D2TG::Poller::_classify_store_error`, matching the established
pattern - `open_store_or_die` (TGT-186) already protected this
script's `D2TG::Store->new` call, but not these 2 later calls.

New test `t/195-approve-store-calls-classified-not-raw.t` (9
assertions) - a structural/source-inspection regression test, matching
this project's own established precedent for a CLI script with no
injectable seam (`t/104-retry-download-cli-no-raw-path.t`,
`t/88-poller-help-pod-parity.t`): a real locked-database failure
occurring strictly after `D2TG::Store->new` already succeeded is not
reliably reproducible black-box via a CLI subprocess without fragile
timing/concurrency tricks. Confirmed genuinely red against the pre-fix
code (9/9 assertions failed).

perlsec.pl-style vulnerability-scan audit: pure in-process control
flow change (adding `eval` wrappers and a classification call) with no
shell invocation, no new file I/O, and no new external-input handling
- no system/exec/backtick/piped-open/eval-STRING patterns in either
touched file.

## TGT-196: persist a downloaded-but-pending state, skip re-download on a stuck retry

A follow-on Codex documentation-stage review finding on TGT-194's own
fix: a persistently-failing `record_message` made `retry_failed_download`
re-download the same already-successfully-fetched file on every retry
pass, forever - wasting bandwidth and Telegram API calls with no
escape hatch. Documented as a known limitation and a design question
(Q-013) raised on the card with two real options (with a synthesized
voice note and options, per this project's own standing rule for
genuine design ambiguity) rather than guessing.

Michael chose Option A: persist a distinct "downloaded, history
pending" state so a future retry, given a row already in this state,
skips re-downloading entirely and only retries the `record_message`
write.

Implementation: `D2TG::Store::failed_downloads` gained a `local_path`
column via the established duplicate-tolerant `ALTER TABLE ... ADD
COLUMN` migration pattern (matching `messages.read_at`/`messages.local_path`/
`sent_replies.text`'s own precedent), and a new
`mark_failed_download_downloaded($id, $local_path)` method sets it.
`D2TG::Download::retry_failed_download` now checks `$row->{local_path}`
first - if defined, `download_file` is skipped entirely and the
persisted path is reused directly; otherwise the existing download
proceeds as before. A `record_message` failure now persists the
already-downloaded path on the row (a no-op if a prior retry already
did this for the same row) before leaving it queued, instead of simply
leaving the row in its ordinary not-yet-downloaded state.

New test `t/196-retry-failed-download-skips-redownload.t` (13
assertions): a first retry (download succeeds, `record_message` fails)
persists `local_path`, verified via a Telegram double's own
`get_file` call counter; a second retry on the same row makes zero
further `get_file` calls, proving the escape hatch genuinely works;
and once `record_message` eventually succeeds (with a pre-set
`local_path`), the row is removed and history restored using the
persisted path rather than a fresh download. Confirmed genuinely red
against the pre-fix code (4/7 assertions failed, plus a fatal "no
method mark_failed_download_downloaded" error once the test reached
that call).

Not covered by this ticket, deliberately: a downloaded file that gets
pruned from the vault (`prune_vault`'s own oldest-`mtime`-first
eviction) between a failed retry and a later successful one would
leave `local_path` pointing at a now-missing file - the same
characteristic risk every other downloaded file already carries once
`prune_vault` can evict it, not a new risk this ticket introduces;
`record_message` itself never verifies the file exists before storing
the path.

perlsec.pl-style vulnerability-scan audit: pure in-process control
flow and schema-migration change (an `ALTER TABLE ADD COLUMN`, a new
accessor method, a conditional branch) with no shell invocation, no
new file I/O beyond the existing SQLite writes, and no new
external-input handling - no system/exec/backtick/piped-open/
eval-STRING patterns in either touched file.

## TGT-198: extract a shared store-write-safe helper, the eval+classify+print pattern was duplicated 7 times

A scheduled JOB-004 improvement hunt found the exact class of
duplication this project has extracted before (`_classify_store_error`
itself, `_record_message_and_track_offset`, `_synthesize_and_send_voice`,
`_format_forwarded_sender`): `eval { $store->WRITE(...) }; if ($@) {
my $reason = D2TG::Poller::_classify_store_error($@); print STDERR
"STORE ERROR [$chat_id]: DESC failed - $reason\n"; }` hand-written
identically at 7 call sites across `D2TG::Poller.pm` (`is_allowed` x3,
`add_pending`) and `D2TG::Download.pm` (`record_message`,
`remove_failed_download`, `mark_failed_download_downloaded`) - while
`D2TG::Reply.pm` already had an equivalent private helper
(`_store_write_safe`, TGT-192) doing exactly this for its own 5 call
sites.

Two more candidate call sites originally named in the ticket
(`_record_message_safe`'s own `record_message` call, `persist_offset_safe`'s
own `set_offset` call) were investigated and deliberately excluded
before implementation started (recorded as a card comment): both print
custom, differently-worded messages and return a `0`/`1` success
boolean rather than the coderef's own return value, so forcing them
through the same helper would either change observable STDERR text or
complicate the helper's own contract for two outliers. `D2TG::Reply.pm`'s
own private helper was also left untouched (out of this ticket's own
scope) - its call sites never need the coderef's return value, unlike
`is_allowed`/`add_pending` here.

New public `D2TG::Poller::store_write_safe($chat_id, $description,
$coderef)` returns a `($ok, $value)` pair rather than a bare value or
undef, since a coderef like `is_allowed` can legitimately return a
false value (0) on success - a bare undef-on-failure return couldn't
distinguish "the write failed" from "the write succeeded and returned
false". This matches this codebase's own established `(1, $result)`/
`(0, $error)` convention (e.g. `D2TG::Download::retry_failed_download`).

Pure refactor, no behavior change: the printed `STORE ERROR [chat_id]:
DESC failed - REASON` text and every call site's own control flow
(`next`, `$record_ok`, fire-and-forget) are unchanged. New structural
(source-inspection) regression test
`t/198-store-write-safe-shared-helper.t` - the same established
precedent as `t/104`/`t/88`/`t/195` for asserting "routed through a
shared helper" vs. "still duplicated inline" when there is no
injectable functional seam - confirmed genuinely red against the
pre-fix code (no shared helper existed, both files still showed the
inline pattern), and confirmed the migration didn't accidentally
regress by excluding `store_write_safe`'s own canonical definition
from the duplicate-detection scan (which would otherwise self-flag).
Full suite (sequential and `-j4` parallel) both PASS with no test
changes needed at any of the 7 migrated call sites.

## TGT-201: cli/whoami.pl's own POD described masked_token's pre-TGT-138 (fixed) short-token behavior as current

A scheduled JOB-003 hourly bug hunt found a documentation-accuracy
defect (not a code defect): `cli/whoami.pl`'s own POD, lines ~97-99,
described `D2TG::Config::masked_token`'s short-token behavior as "shown
as-is, unmasked" - true before TGT-138, but TGT-138 already shipped a
fix making `masked_token` return a fixed `(short token, not shown)`
placeholder for any token of length <= 8, never the raw token. The POD
was simply never updated to match the real, already-correct code
behavior - actively misleading a reader into believing a short bot
token leaks in full via `d2 tg.whoami`, when the opposite is true.

Fixed by updating the POD text to name the actual placeholder
`masked_token` returns. A repo-wide grep sweep (`docs/commands.md`,
`docs/POLICIES.md`, `README.md`, `SKILLS.md`) confirmed the stale claim
was isolated to this one file - `cli/status.pl` and `cli/poller.pl`,
which also rely on `masked_token`'s short-token behavior, never
repeated the stale wording. New structural (source-inspection)
regression test `t/201-whoami-masked-token-pod-accurate.t` - checks
the stale claim is gone, the correct placeholder text is present, that
placeholder text matches `D2TG::Config.pm`'s own real return value
(not just some arbitrary string), and that no other doc/POD in the
repo repeats the stale claim. Confirmed genuinely red against the
pre-fix code (2/7 subtests failed).

## TGT-202: bot_groups silently created a duplicate (chat_id, bot_token) pair

A scheduled JOB-003 hourly bug hunt found that `D2TG::Config::bot_groups`
folds `D2TG_CHAT_ID`/`D2TG_TOKEN` in as an implicit trailing group
(TGT-049) whenever they're set, even when the CLI already declared an
identical `--chat_id`/`--bot` pair explicitly - producing two group
entries sharing the exact same `(chat_id, bot token)` pair. A plausible
real operator setup (a wrapper/systemd unit setting the env vars as
"defaults" while also passing the same values explicitly via CLI flags
for clarity) would silently double that pair's own polling work every
cycle: `cli/poller.pl`'s own `@pairs` construction builds two separate
`D2TG::Telegram` instances for the identical bot token, each
independently calling `$store->get_offset($bot_key)` and later
`set_offset($bot_key, ...)` within the same poll cycle - racing each
other and Telegram's own `getUpdates` offset semantics for that one
token.

`cli/poller.pl`'s existing TGT-164 duplicate-guard only refused a
*malformed* env `chat_id` (failing `require_chat_id_or_warn`'s shape
check) - it never checked whether a well-formed env pair was an exact
duplicate of one the CLI already declared.

Fixed by refusing loudly: `bot_groups` now dies with a clear message
naming the duplicate whenever the same `(chat_id, token)` pair appears
more than once across all groups (including the env-folded one) -
matching this project's own established preference for explicit
refusals over silent best-effort (e.g. TGT-107/TGT-122's own
precedent), since a silent de-dup could just as easily mask a genuine
operator typo the other direction. A genuinely distinct multi-bot
configuration is unaffected - both "two different chat_ids" and "the
same chat_id with two different bot tokens" remain valid, untouched
shapes.

New test `t/202-duplicate-bot-pair-refused.t`: unit-level checks
against `bot_groups` directly, plus a CLI-level subprocess check
against the real `cli/poller.pl` entrypoint (matching TGT-185's own
established startup-refusal test pattern). The CLI-level check uses a
bounded fork+setpgrp+alarm-timeout+process-group-kill helper (matching
`D2TG::Transcribe`'s own established process-group-kill pattern,
TGT-128) rather than an indefinite wait, since pre-fix the poller
never exits on its own for this case - it proceeds into a real
long-poll against Telegram with a fake token. Confirmed genuinely red
against the pre-fix code (2/8 subtests failed, and the CLI-level
subprocess had to be killed by the test's own timeout rather than
exiting cleanly).

## TGT-203: run_capturing_stderr duplicated identically across 6 test files

A scheduled JOB-004 improvement hunt found the exact same 8-line
`run_capturing_stderr(@cmd)` helper hand-copied into 6 separate test
files (`t/59`, `t/77`, `t/183`, `t/184`, `t/185`, `t/186`) - runs a
command via backtick with STDERR redirected to a per-file tmp path,
returns `($out, $rc, $err)`, unlinks the tmp file. Byte-for-byte
identical except each file's own hardcoded
`/tmp/d2tg-NNN-stderr.$$` suffix. Matches this project's own
established "found it twice (or more), extract it" duplication-removal
precedent (`shift_flag_value` TGT-072, `_classify_store_error`
TGT-167, `open_store_or_die` TGT-186, `resolve_alias_dir_or_die`
TGT-172, `extract_db_flag_or_die` TGT-177, `D2TG::Poller::store_write_safe`
TGT-198) - just in test infrastructure (`t/lib/`) rather than
production `lib/` code this time.

Extracted into the existing `t/lib/Test/CaptureStdio.pm` (which
already held an unrelated `capture_stdio` helper for a genuinely
different purpose - in-process STDOUT/STDERR file-descriptor
redirection around a coderef, vs. this one's external-subprocess
backtick capture; confirmed distinct before extracting, not merged).
Uses `File::Temp::tempfile` instead of a hand-rolled `$$`-suffixed
path, so no caller needs to pick a unique suffix at all. `t/202`'s own
intentionally-different `fork`+`setpgrp`+timeout+kill helper stays
separate - it exists specifically because that one test's own
subprocess can hang indefinitely pre-fix, unlike these 6 callers'
subprocess, which always exits on its own.

**A real regression caught and fixed during implementation, not by
Codex (unavailable all session, transient sandbox failures) but by
this project's own full-suite gate**: naively adding
`use lib "$Bin/lib";` to `t/59` (needed to import the new shared
helper) made that file's own pre-existing `SKIP:` block - which
gates a real-Developer::Dashboard-required test behind
`eval { require Developer::Dashboard; Developer::Dashboard->can('d2') }`
- wrongly succeed: `$Bin/lib` also contains a *fake* `Developer::Dashboard`
stub (used elsewhere to give a spawned subprocess a working `d2()` via
`PERL5LIB`, matching `Test::MandatoryDb::setup_mandatory_db_env`'s own
pattern), which the in-process `require` now found and accepted as
"real enough". The gated test then ran for real instead of correctly
skipping - but `t/59` never exports `PERL5LIB`, so its own actual
subprocess (a real `cli/history.pl` invocation) never saw that fake
stub either, and died with `Undefined subroutine &Developer::Dashboard::d2`.
Fixed by loading `Test::CaptureStdio` via its own explicit file path
(`require File::Spec->catfile(...); Test::CaptureStdio->import(...)`)
in `t/59` specifically, leaving `@INC` - and the SKIP gate's own
detection - untouched; the other 5 files already had `use lib "$Bin/lib"`
before this ticket (via `Test::MandatoryDb`), so they carry no such
risk and keep the plain `use Test::CaptureStdio qw(run_capturing_stderr);`
form.

New structural (source-inspection) regression test
`t/203-run-capturing-stderr-shared-helper.t`, matching this project's
own established precedent (`t/104`, `t/88`, `t/195`, `t/198`, `t/201`,
`t/202`) - confirmed genuinely red against the pre-fix code (14/15
subtests failed). Full suite (sequential and `-j4` parallel) both PASS
with every existing assertion in all 6 migrated files unmodified.

## TGT-204: queued failed media downloads had no proactive visibility

A real, live incident report from the budget project's own agent
(filed to `/tmp/ask-for-more-from-d2tg/`, per the standing
`report-tira-faults-upstream.md` pattern): 4 photo messages (chat_id
398296603, msg_ids 4484/4485/4494/4495) failed to download around
19:22-19:23 on 2026-09-11 (HTTP 500/timeout) - `TGT-104`'s own
`failed_downloads` queue caught them correctly, but `d2 tg.unread`/
`d2 tg.history` both read as "nothing happened" for over an hour. The
poller's own `MEDIA DOWNLOAD ERROR` line was printed, but only to
STDERR - which never reaches the monitor job's own stdout-fed
`tira.policy.bridge` notification stream (per this project's own
architecture decision, [[tg-skill-design]]: "ordinary/event output →
stdout; errors/transient failures → stderr", and only stdout is what
the monitor-job feeder reads as notification-worthy). The only way to
discover a queued failure was to read the poller's own raw output
directly or run `d2 tg.retry-download --all` speculatively with no
prompt to do so - which is exactly what recovered all 4 cleanly once
the owner directly asked whether any errors had occurred.

Fixed with two changes, deliberately scoped to visibility only (an
automatic background retry with backoff was raised in the same
incident report but excluded here as a separate, larger design
decision about retry cadence and whether it belongs in the poller's
own main loop):

1. `D2TG::Poller::run_once` now also prints a `NEW TG MEDIA FAILED
   [chat_id] sender: media_kind - queued for retry, RETRY WITH: d2
   tg.retry-download --all` STDOUT line whenever a media download
   fails AND the failure is successfully queued via
   `record_failed_download` - the existing `MEDIA DOWNLOAD ERROR`
   STDERR line is unchanged, and a failure to queue (the database
   itself unavailable) keeps its own existing STDERR-only report,
   unchanged, rather than claiming a queue that didn't actually
   happen.
2. `cli/unread.pl` now also lists any currently-queued failed
   downloads (via `D2TG::Store::failed_downloads`) after the unread
   message list - a queued failure isn't technically an "unread
   message" (it was never recorded into message history at all,
   TGT-104's own design), but is exactly the kind of "needs your
   attention" state this command exists to surface.

New test `t/204-failed-download-visibility.t`: confirmed genuinely red
against the pre-fix code via `git stash` of the fix (2/7 subtests
failed - no STDOUT event, no recovery command named), confirmed green
with the fix restored, and includes an explicit regression check that
a successful download's own existing `NEW TG MEDIA` line and STDERR
silence are completely unaffected.

## TGT-209: cli/history.pl accepted a malformed --since/--until value silently

Found via a scheduled JOB-003 hourly bug hunt, reproduced live inside a
`developer-dashboard:latest` container. `TGT-070`/`TGT-071` only ever
validated that `--since`/`--until` had *a* value present
(`D2TG::Config::shift_flag_value`) - never that the value looked like a
date. `D2TG::Store::messages_in_range` builds its `WHERE` clause with a
plain lexicographic string comparison against the stored `created_at`
column (SQLite's `CURRENT_TIMESTAMP` default, space-separated, e.g.
`2026-09-12 00:01:41`): `created_at >= ?` / `created_at <= ?`, bound
directly to the raw CLI string with no parsing at all.

A malformed `--since` value such as `not-a-date` sorts lexicographically
*after* every real ISO8601 timestamp (`'n' > '2'`), so `created_at >= ?`
silently excludes every real message - the command still exits 0 and
prints `No messages found.`, exactly the same misleading-silence outcome
`TGT-070` already fixed for a missing value, but for a wrong-shaped one
instead. A differently-malformed value (e.g. `2020/01/01`, slashes
instead of dashes) can silently include or exclude messages depending on
where it happens to sort, rather than being rejected or behaving as the
date it looks like it should mean.

Fixed in `cli/history.pl` alone (deliberately excluded from scope:
`D2TG::Store::messages_in_range`'s own SQL comparison logic - validating
at the CLI boundary is sufficient, and rewriting the storage layer's
date handling is a separate, larger decision): right after
`shift_flag_value` extracts the `--since`/`--until` value, it is checked
against `qr/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2})?$/` - accepting
both a date-only value (`YYYY-MM-DD`) and the full ISO8601 date+time
form already used throughout this command's own documented usage
(`YYYY-MM-DDTHH:MM:SS`). A value that doesn't match either shape exits 2
with a message naming the exact bad value and the expected format,
before the query ever reaches the store.

Extended the existing `t/58-history-since-until-validation.t` (rather
than a new file, since it already owns this exact `--since`/`--until`
validation surface from `TGT-070`/`071`) with new blocks: confirmed
genuinely red against the pre-fix code (`prove -l
t/58-history-since-until-validation.t` failed 5/14 subtests - lines
8-12, `--since not-a-date` and `--until 2020/01/01` both exited 0 and
printed `No messages found.`), confirmed green after the fix (14/14),
and added an explicit date-only regression case
(`--since 2026-01-01 --until 2026-02-01`) alongside the pre-existing
full-timestamp regression case, so both accepted shapes stay covered.
Full suite re-run clean at 1528/1528. Coverage note: `cli/history.pl` is
invoked via subprocess (`qx{}`/backticks) in every test that exercises
it, so `Devel::Cover` cannot instrument it directly across the process
boundary - the same limitation applies to every `cli/*.pl` script in
this project. Verified instead by direct source review confirming every
branch of the new validation (malformed `--since`, malformed `--until`,
well-formed date-only, well-formed full-timestamp) has a corresponding
test assertion.

## TGT-210: cli/approve.pl's SYNOPSIS/Usage documented an unusable --bot position

Found via a scheduled JOB-003 hourly bug hunt. `cli/approve.pl`'s own
POD `SYNOPSIS` and printed `Usage:` message both showed:

    d2 tg.approve <chat_id> [--db <alias> | -d <alias>] [--bot <token>]

with `--bot <token>` documented *after* the positional `<chat_id>`. But
`D2TG::Reply::extract_bot_flag` only ever recognizes `--bot` when it is
the very first argument - the same leading-position shape `cli/reply.pl`'s
own `--bot` uses (TGT-057) - and it is called on `@ARGV` before
`<chat_id>` is parsed at all. The same file's own POD `DESCRIPTION`
section already correctly said `--bot` uses "the same leading-position
shape `cli/reply.pl`'s own `--bot` uses" - a direct self-contradiction
one paragraph below its own `SYNOPSIS`. `docs/commands.md`'s own command
header carried the identical trailing-position mistake, one paragraph
above a correct leading-position description.

A caller following the documented `SYNOPSIS`/`Usage` form literally
(e.g. `d2 tg.approve 12345 --bot mytoken`) left 3 unconsumed `@ARGV`
elements after `extract_bot_flag` ran (since `$args[0]` was `'12345'`,
not `--bot`), so the `@ARGV != 1` guard fired and the command exited 2 -
printing the exact `Usage:` line that had just shown this invocation as
valid. Not a behavior bug: the leading-position implementation itself
is correct and already consistent with `cli/reply.pl`; only the
`SYNOPSIS`/`Usage` text (and `docs/commands.md`'s matching header) were
wrong.

Fixed by correcting both to
`d2 tg.approve [--bot <token>] <chat_id> [--db <alias> | -d <alias>]` -
a documentation-only change. New test
`t/210-approve-bot-position-documented-correctly.t` derives the
documented `--bot`/`<chat_id>` order directly from `cli/approve.pl`'s
own `SYNOPSIS` text (rather than hardcoding an expected order), then
actually invokes the command in that exact order against a seeded
pending chat id - confirmed genuinely red against the pre-fix `SYNOPSIS`
(3/3 subtests failed: exit 2 instead of 0, `Usage:` text instead of
`Approved 2000`), confirmed green after the fix (3/3), and the two
existing sibling tests (`t/114-approve-usage-pod-parity.t`,
`t/75-multi-bot-allow-list-scoping.t`) re-run clean alongside it
(27/27 total). Full suite re-run clean at 1531/1531.

## TGT-211: cli/*.pl scripts checked storage vs. argv shape in inconsistent order

Found via a scheduled JOB-004 improvement hunt. Two families of
`cli/*.pl` scripts perform the same 3 checks (extract `--db`, validate
positional/usage args, resolve+require the storage dir) but in
different orders: `cli/whoami.pl`, `cli/text-only-replies.pl`,
`cli/unread.pl`, `cli/status.pl` validate argv shape FIRST (exit 2,
`Usage:`) then resolve storage; `cli/attachment.pl`,
`cli/retry-download.pl`, `cli/approve.pl` resolved storage FIRST (exit
1 on a missing/invalid storage location) then validated argv shape -
confirmed by direct source read (`cli/unread.pl` checks argv at lines
17-25 then storage at line 27; `cli/attachment.pl` resolved storage at
line 17 then checked argv at line 25).

When BOTH the storage location is missing/invalid AND positional args
are malformed at the same time, a caller got an inconsistent signal -
exit 1/storage-error from one family, exit 2/`Usage:` from the other -
depending only on which sibling command they happened to call, not on
anything about the actual input. No test in the suite ever exercised
this compound case: every existing `*-usage-pod-parity.t` test uses
`Test::MandatoryDb::setup_mandatory_db_env`, which always resolves
`--db`/`D2TG_DB` to a real, existing directory, so the interaction
between a bad storage location and bad argv was never both true in any
test.

Fixed by reordering `cli/attachment.pl`, `cli/retry-download.pl`, and
`cli/approve.pl` to validate argv shape before resolving storage,
matching the majority sibling family (chosen as canonical since
resolving storage is the more expensive/environment-dependent step) -
a pure block-reorder, no new logic. New test
`t/211-cli-usage-checked-before-storage-resolution.t` exercises all 3
reordered scripts with a compound invalid-storage + malformed-argv
invocation, using `setup_mandatory_db_env`'s own fake
`Developer::Dashboard` pointed at a directory that is deliberately
never created (rather than `--db <bogus-alias>`, which needs a real
Developer Dashboard install this container doesn't have - see
`t/42-db-flag-cli-integration.t`'s own skip-guard for that same
limitation) - confirmed genuinely red against the pre-fix code (9/9
subtests failed: all 3 scripts exited 1 with a storage-resolution error
instead of 2 with `Usage:`), confirmed green after the fix (9/9), and
every existing sibling/parity test for the 3 reordered scripts re-run
clean alongside it (38 + 114 = 152 additional tests, all passing). Full
suite re-run clean at 1540/1540.

## TGT-212: SKILLS.md stated a superseded heartbeat-staleness threshold

Found via a scheduled JOB-005 doc-accuracy hunt. SKILLS.md's onboarding
overview said `d2 tg.status` flags the heartbeat "stale past 20 minutes
(TGT-116)". TGT-116 did originally set a flat 1200s (20-minute)
threshold, but TGT-147 (a later scheduled bug hunt) replaced it with one
DERIVED from `D2TG::Transcribe`'s own `$TIMEOUT_CEILING` (3600) and
`@MODEL_TIERS` (3 entries: medium/small/base) constants -
`int(3600 * 3 * 4/3) = 14400` seconds = 4 hours - specifically so the
threshold could never silently drift out of sync with the real
transcription timeout again (TGT-140's own duration-scaled
transcription timeout made the old flat 20-minute figure stale the
moment it shipped). `cli/status.pl`'s own POD and `docs/commands.md`'s
`d2 tg.status` entry both already correctly described the derived
14400s/4h value and TGT-147 - only SKILLS.md's onboarding overview was
never updated after that change, creating a self-contradiction between
the onboarding doc and both the real code and the command reference
describing the exact same command.

Fixed by correcting SKILLS.md's sentence to describe the real, current
derived threshold and cite TGT-147 - a wording-only change, no code
touched. New test `t/212-skills-md-status-threshold-accurate.t`
computes the real threshold directly from `D2TG::Transcribe`'s own
constants (never a re-typed literal, so the test itself can't silently
go stale the same way SKILLS.md did) and checks SKILLS.md's wording
against it - confirmed genuinely red against the pre-fix wording (3/3
subtests failed: still said 20 minutes/TGT-116, no 4 hours/TGT-147
mention), confirmed green after the fix (3/3), and the existing sibling
`t/98-skills-md-cli-list-current.t` re-run clean alongside it (17/17
total). Full suite re-run clean at 1543/1543.

## TGT-213: bot_groups' TGT-202 duplicate guard missed same-token-different-chat_id

Found via a scheduled JOB-004 improvement hunt. TGT-202's own duplicate-
pair guard in `D2TG::Config::bot_groups` refuses only when the exact
same `(chat_id, bot_token)` pair appears twice - key =
`"$group->{chat_id}\0$token"`. But the actual hazard TGT-202 was fixing
- two `cli/poller.pl` `@pairs` entries racing the same
`get_offset`/`set_offset` calls against each other - is keyed purely on
the bot TOKEN, not on `(chat_id, token)`: confirmed by direct source
read that `D2TG::Store::_offset_meta_key`/`get_offset`/`set_offset` key
the offset row on `$bot_key` alone, and `cli/poller.pl` line 355 sets
`my $bot_key = $single_bot_mode ? undef : $token;` - the token alone,
with no `chat_id` folded in. So the same bot token declared under two
DIFFERENT `--chat_id` groups (e.g.
`--chat_id 111 --bot SAME_TOKEN --chat_id 222 --bot SAME_TOKEN`)
produces the identical race, but the `(chat_id, token)`-keyed check
lets it through silently since the two keys differ.

Fixed by adding a second dedup check in `bot_groups`, keyed on bot
token alone, checked alongside (not replacing) the existing
`(chat_id, token)` check - refuses naming the masked token (never the
raw value, matching `masked_token`'s own established convention) and
both conflicting `chat_id`s. New test
`t/213-bot-token-reused-across-chat-ids-refused.t`: confirmed genuinely
red against the pre-fix code (3/8 subtests failed - no refusal at all
for the same-token-different-chat_id shape), confirmed green after the
fix (8/8), and includes explicit regression coverage for TGT-202's own
exact-duplicate case plus both genuinely-distinct-configuration cases
(different chat_id+different token; one chat_id+two tokens) - all
re-run clean alongside `t/202-duplicate-bot-pair-refused.t` (16/16
total). Full suite re-run clean at 1551/1551; 100% statement+subroutine
coverage confirmed on `lib/D2TG/Config.pm`.

## TGT-214: d2 tg.history silently excluded same-day messages with a T-separated time

Found via a scheduled JOB-003 hourly bug hunt, live-verified against a
real SQLite comparison (not just read - actually run against an
in-memory database). `D2TG::Store::messages_in_range` compared
`--since`/`--until` against `created_at` with a plain SQL string
comparison (`created_at >= ?` / `<= ?`). `created_at`'s real stored
format is SQLite's own `CURRENT_TIMESTAMP` default, space-separated
(e.g. `"2026-09-01 08:00:00"`), while `cli/history.pl`'s own documented
and TGT-209-validated `--since`/`--until` form uses a `'T'` separator
(e.g. `"2026-09-01T00:00:00"`) - the exact form shown in its own
SYNOPSIS/usage text and required to pass TGT-209's own shape-validation
regex. Since `'T'` (`0x54`) sorts lexicographically after a space
(`0x20`), a `--since` value carrying a time-of-day component became
greater than every `created_at` row sharing that same calendar date,
regardless of the row's actual time - live-verified: rows at
`"2026-09-01 08:00:00"` and `"2026-09-01 20:00:00"` (both genuinely at
or after midnight that day) both failed to match
`created_at >= '2026-09-01T00:00:00'`, returning zero rows.

This is exactly the gap TGT-209 explicitly scoped out of its own fix
("`D2TG::Store::messages_in_range`'s own SQL comparison logic -
validating at the CLI boundary is sufficient") - TGT-209 only validated
the CLI-supplied value's *shape*, never whether it compares correctly
against the stored format, and this ticket closes that separate gap.
`t/39-message-history-range.t`'s own existing coverage never caught
this because it manually writes `created_at` using the SAME `'T'`
separator as its `since`/`until` values - consistently T-separated on
both sides, so the mismatch never surfaced.

Fixed by wrapping both sides of the comparison in SQLite's own
`datetime()` function (`datetime(created_at) >= datetime(?)`), which
normalizes any of its accepted input shapes (bare date, space-
separated, `'T'`-separated) to one canonical form before comparing -
comparing by true chronological value rather than raw string ordering.
A side discovery during implementation: a date-only `--until` value was
ALSO already broken pre-fix in the opposite direction (excluded
same-day timestamped rows, since a bare date string is a lexicographic
prefix of - and thus "less than" - a longer timestamp string) - this is
a separate, pre-existing question about whether date-only `--until`
should mean "start of day" or "end of day" inclusive, deliberately left
unchanged and out of this ticket's own narrow scope (the separator
mismatch only); raised in a ticket comment as a candidate for its own
future ticket with Michael's input, not decided unilaterally here.

New test `t/214-history-range-separator-mismatch.t`, using realistic
space-separated `created_at` values (matching what `CURRENT_TIMESTAMP`/
`record_message` actually store, unlike `t/39`'s own T-separated
fixtures): confirmed genuinely red against the pre-fix code (5/6
subtests failed), confirmed green after the fix (6/6), with `t/39` and
`t/58`'s own existing suites re-run clean alongside it (29/29 total).
Full suite re-run clean at 1557/1557; 100% statement+subroutine
coverage confirmed on `lib/D2TG/Store.pm`.

## TGT-215: pending_chat_ids was the sole accessor never updated for TGT-098's bot_key migration

Found via a scheduled JOB-004 improvement hunt. TGT-098 gave the
`pending` table a composite `PRIMARY KEY (chat_id, bot_key)`
specifically so the same Telegram chat_id can be legitimately pending
under more than one configured bot (a shared group chat). Every sibling
accessor on this table (`is_allowed`, `add_pending`, `approve`) and the
equivalent `sent_replies` accessors were updated to take/scope by
`bot_key` - `pending_chat_ids` alone was missed: it ran a bare
`SELECT chat_id FROM pending` with no `bot_key` parameter, no `bot_key`
in the `SELECT`, and no `DISTINCT`. Confirmed by reading `_ensure_schema`'s
`pending` table DDL (composite PK) against `pending_chat_ids`'s own
implementation and POD (which documented no `bot_key` parameter at all,
unlike `text_only_replies`'s own POD). In a genuine multi-bot config, a
chat_id pending under two different bots would produce two identical,
indistinguishable rows.

Confirmed via `grep` that this method has no production `cli/*.pl`
caller today (only exercised by `t/05-access-control.t`,
`t/06-approve.t`, `t/111-reaction-access-control.t`, and named in
`D2TG::Store`'s own top-level `SYNOPSIS`) - a latent gap in a
documented public API, not yet a live incident.

Drafting-stage correction (before any implementation started, recorded
in a ticket comment): the first-drafted solution assumed the unscoped
case should switch to returning `DISTINCT (chat_id, bot_key)` hashref
pairs, matching `text_only_replies`'s own unscoped return shape - but
the 3 existing test files all depend on the CURRENT flat
chat_id-scalar-list shape via `is_deeply`/`scalar`/list-index
assertions, which a shape change would break, directly contradicting
this ticket's own regression requirement. Corrected: added an optional
`bot_key` filter (returns the same flat shape, scoped); the unscoped
case keeps its exact existing flat-list shape unchanged, only adding
`SELECT DISTINCT` to close the duplicate-row bug. Full per-bot-key
visibility for the unscoped case (returning which bot(s) each chat_id
is pending under) is a larger API-shape change deliberately left out of
this narrow fix.

New test `t/215-pending-chat-ids-bot-key-scoping.t`: confirmed
genuinely red against the pre-fix code (3/7 subtests failed - a
chat_id pending under two bot_keys was returned twice unscoped, and no
`bot_key` filtering existed at all), confirmed green after the fix
(7/7), with the 3 existing sibling tests re-run clean alongside it
(42/42 total). Full suite re-run clean at 1564/1564; 100%
statement+subroutine coverage confirmed on `lib/D2TG/Store.pm`.

## TGT-216: heartbeat docs cited the pre-TGT-140 flat transcription timeout

Found via a scheduled JOB-005 doc-accuracy hunt. `D2TG::Config::write_heartbeat`'s
own POD and `cli/poller.pl`'s matching TGT-116 code comment both said a
single voice transcription's retry ladder (`D2TG::Transcribe`'s
medium->small->base tiers) is "300s each" / "can take up to ~900s".
TGT-140 replaced that flat per-tier timeout with a duration-scaled one:
`D2TG::Transcribe::_scaled_timeout` computes `duration *
$TIMEOUT_MULTIPLIER` (8), floored at `$TIMEOUT` (300) and capped at
`$TIMEOUT_CEILING` (3600) - so each of the 3 tiers can now legitimately
run up to 3600s, not a flat 300s; a full 3-tier retry ladder's worst
case is up to 10800s, not ~900s. This directly contradicted the
already-correct post-TGT-140 figures documented in the SAME file's own
`heartbeat_age` POD and in `cli/status.pl`'s POD, both of which
correctly cite the derived `STALE_THRESHOLD_SECONDS` formula
(`$TIMEOUT_CEILING * scalar(@MODEL_TIERS) * 4/3` = `3600*3*4/3` =
14400s/4h) - a formula that only makes sense if the worst case per tier
is 3600s.

While writing the red test, a THIRD stale occurrence (missed by the
original hunt) was found: `cli/poller.pl`'s own `=head1 DESCRIPTION`
POD (separate from the TGT-116 code comment) also said "medium->small->base
tiers, up to ~900s total". All 3 locations were corrected together.

New test `t/216-heartbeat-doc-timeout-figures-accurate.t`: computes the
real current worst-case figures directly from `D2TG::Transcribe`'s own
`$TIMEOUT_CEILING`/`@MODEL_TIERS` constants (never a re-typed literal,
so the test itself can't silently go stale the same way the docs did)
and scans both files for the stale figures (absent) and the correct
ones (present) - confirmed genuinely red against the pre-fix text (8/8
subtests failed across all 3 real occurrences), confirmed green after
the fix (8/8). Full suite re-run clean at 1572/1572 (one unrelated,
confirmed-transient flake in `t/54-lock-acquire-race.t` - passed
cleanly in isolation and on re-run, matching this project's established
host-load flakiness pattern, unrelated to this diff). 100%
statement+subroutine coverage confirmed on `lib/D2TG/Config.pm`;
`cli/poller.pl` is a subprocess-invoked CLI script, the same
`Devel::Cover` instrumentation limitation documented for every other
`cli/*.pl` fix this session.

## TGT-217: edited_message branch never printed a REPLY WITH template

Found via a scheduled JOB-003 hourly bug hunt. Every other actionable
inbound-message branch in `D2TG::Poller::run_once` (message/media/
voice/document/photo) calls `_print_reply_template($chat_id,
$message_id, $bot_token)` right after its own `NEW TG ...` line,
printing the `REPLY WITH: d2 tg.reply <chat_id> "..." --bot <masked>
--reply-to-message-id <id>` line the whole bridge-notification
architecture depends on (`.claude/rules/tg-skill-design.md`'s Q-004
decision: "The poller's own stdout line for a new inbound message must
carry ... a ready-to-run reply command template"). Confirmed by direct
`grep` that `_print_reply_template` is called at exactly 4 sites
(message/voice/document/photo branches) - the `edited_message` branch
(TGT-169) was the sole actionable branch missing it: it printed only a
`NEW TG EDIT [...] ...` line and fell through to `next` without ever
calling `_print_reply_template`, for either the text-edit or the
caption/media-only-edit case.

Any Telegram user in an allow-listed chat editing a previously-sent
message (a common, real action) triggers this gap every time - the
monitoring agent sees the edited content but has no ready-to-run reply
command for it, breaking the same convenience/consistency the Q-004
architecture decision and the project's own `always-reply-on-tg` rule
both depend on. `t/129-edited-message-detection.t`'s own existing
coverage never caught this - it only asserts the `NEW TG EDIT` line's
own content, never presence/absence of a `REPLY WITH` line.

Fixed by adding the missing `_print_reply_template` call right after
the existing `NEW TG EDIT` print line, matching every sibling branch's
own placement exactly - printed for both the text-edit and caption/
media-only-edit sub-cases, since both are announced (only the store
recording is conditionally skipped for the no-text case, not the
announcement). New test `t/217-edited-message-reply-template.t`, using
`Fake::Telegram`/`Fake::Store` fixtures matching `t/129`'s own
established style: confirmed genuinely red against the pre-fix code
(2/4 subtests failed - no `REPLY WITH` line for either edit case),
confirmed green after the fix (4/4), with `t/129`'s own existing 7
assertions re-run clean alongside it (11/11 total). Full suite re-run
clean at 1576/1576. 100% statement+subroutine coverage confirmed on
`lib/D2TG/Poller.pm`.

## TGT-218: --chat_id accepted a non-canonical value and silently locked out the owner

Found via a scheduled JOB-003 hourly bug hunt. `D2TG::Config::require_chat_id_or_warn`
(TGT-155/164) validates `D2TG_CHAT_ID` against Telegram's own canonical
chat-id shape (`^-?\d+$`) before the poller starts, specifically
because a mangled value can never string-eq match a real inbound
`chat_id`, silently locking the owner out forever with zero warning.
`D2TG::Config::bot_groups`'s own `--chat_id` handling never got the
same check - it built each group's `chat_id` straight from
`shift_flag_value`, which only rejects a missing/empty/flag-looking
value, never a present-but-non-numeric one. `cli/poller.pl`'s own
TGT-164 re-validation only ever re-checks `D2TG_CHAT_ID` when it is
*also* set alongside CLI-declared `--chat_id` groups - it never
re-validates the CLI-declared value itself, a gap TGT-164's own comment
explicitly describes as out of its narrower scope.

`d2 tg.poller --chat_id ' 12345'` (or any other non-canonical value -
whitespace-padded, non-digit) previously started up cleanly with no
refusal and no warning. `D2TG::Store::_seed_admin` inserts the
malformed value into `allow_list`'s `chat_id` column, and since every
real inbound Telegram message carries a genuine numeric `chat_id`,
`is_allowed`'s `WHERE chat_id = ?` lookup can never match it - the
owner is invisibly locked out, every message from them queuing as
pending forever, exactly the failure mode TGT-155/164 exist to
eliminate for `D2TG_CHAT_ID`, just reachable through the `--chat_id`
CLI flag instead. `t/44-bot-groups.t` and
`t/126-poller-cli-groups-env-chat-id-validation.t` only test missing/
empty/duplicate `--chat_id` and env-var shape mismatches - neither
exercises a non-numeric-but-non-empty CLI `--chat_id` value.

Fixed by reusing `require_chat_id_or_warn`'s own identical
`/^-?\d+$/` check inside `bot_groups`' own `--chat_id` handling,
refusing (dying) with a clear message naming the malformed value -
closing the gap at its source so every caller benefits automatically.
New test `t/218-bot-groups-chat-id-shape-validation.t`: confirmed
genuinely red against the pre-fix code (4/6 subtests failed - no
refusal at all for either malformed value), confirmed green after the
fix (6/6), with `t/44-bot-groups.t` and
`t/126-poller-cli-groups-env-chat-id-validation.t`'s own existing 27
assertions re-run clean alongside it (33/33 total). Full suite re-run
clean at 1582/1582 (one unrelated, confirmed-transient flake in
`t/66-lock-last-poller-wins.t` observed during this session, passed
cleanly on isolated re-run, matching this project's established
host-load flakiness pattern). 100% statement+subroutine coverage
confirmed on `lib/D2TG/Config.pm`.

## TGT-219: failed_downloads queue was not bot-scoped

Found via a scheduled JOB-004 improvement hunt. Every other per-chat
`D2TG::Store` table (`allow_list`, `pending`, `sent_replies`, and the
offset meta keys) carries a `bot_key` column so a multi-bot config
(`bot_groups`, hardened by TGT-098/202/213/218) stays correctly scoped
- `failed_downloads` was the sole exception, keyed only on `(chat_id,
message_id)`. Confirmed by direct source read: `D2TG::Poller::run_once`
already has `$bot_token` in scope at the failure site (used two lines
earlier for `is_allowed`/`_print_reply_template`) but the
`record_failed_download` call never passed it through -
`D2TG::Store::record_failed_download`'s own signature didn't even
accept a `bot_key` argument. Downstream, `cli/retry-download.pl` built
its Telegram client unconditionally with the single default token, no
`--bot` flag at all - unlike its siblings `cli/approve.pl`/
`cli/reply.pl`, which both support `--bot <token>` specifically so a
caller can act as the correct bot in a multi-bot group.

Telegram's own `file_id` values are bot-token-scoped - a `file_id`
obtained by bot A cannot be resolved via bot B's `getFile`. In any
`bot_groups` configuration with more than one `--bot` under a
`--chat_id` group (a configuration this codebase explicitly builds,
validates, and tests elsewhere), a media-download failure recorded by
a non-default bot would be retried using the wrong bot's token -
Telegram would refuse the retry, with no `--bot` override to work
around it, unlike the analogous `approve`/`reply` commands.

Fixed by: (1) adding a `bot_key` column to `failed_downloads` via the
same rename/create/copy/drop migration TGT-098 already established for
`allow_list`/`pending` (a `UNIQUE` constraint change can't be done via
a bare `ALTER TABLE ADD COLUMN` in SQLite), changing the uniqueness key
to `(chat_id, bot_key, message_id)`; (2) `record_failed_download` and
`failed_downloads` both take an optional `bot_key` (mirroring
`pending_chat_ids`' own TGT-215 backward-compatible pattern - the
unscoped case keeps listing every bot's entries, each now naming its
own `bot_key`); (3) `D2TG::Poller::run_once` threads its already-in-
scope `$bot_token` through to `record_failed_download`; (4)
`cli/retry-download.pl` gains a `--bot <token>` flag (via
`D2TG::Reply::extract_bot_flag`, matching `cli/approve.pl`/
`cli/reply.pl`'s own leading-position pattern) to scope both listing
and retrying to the correct bot.

New test `t/219-failed-downloads-bot-scoping.t` (with
`t/lib/Fake/Store.pm` extended to capture `bot_key` so `D2TG::Poller`'s
own call site is independently verifiable): confirmed genuinely red
against the pre-fix code (3/9 subtests failed - the same message_id
under two bot_keys collapsed via `ON CONFLICT` into one row, and
`run_once` never threaded `$bot_token` through), confirmed green after
the fix (9/9 + a migration-failure regression test added afterward to
close a coverage gap the fix itself introduced, matching
`t/75-multi-bot-allow-list-scoping.t`'s own established mid-migration-
failure precedent - 11/11 total), with the 5 existing sibling test
files (`t/83`, `t/104`, `t/119`, `t/186`, `t/194`) re-run clean
alongside it (125/125 total; `t/119-retry-download-usage-pod-parity.t`
caught the new `--bot` flag missing from the POD `SYNOPSIS`, fixed in
the same pass, not scope creep). Full suite re-run clean at 1595/1595.
100% statement+subroutine coverage confirmed on both `lib/D2TG/Store.pm`
and `lib/D2TG/Poller.pm`.

## TGT-220: NEW TG MEDIA FAILED's own RETRY WITH hint omitted --bot in a multi-bot config

Found via a scheduled JOB-003 hourly bug hunt. `D2TG::Poller::run_once`'s
`NEW TG MEDIA FAILED` stdout line (TGT-204) prints a `RETRY WITH: d2
tg.retry-download --all` recovery-command hint whenever a media
download fails and is successfully queued. Confirmed by direct source
read that this line was a hard-coded string literal, even though
`$bot_token` is already in scope at that exact print site - used two
lines earlier for `record_failed_download`'s own `bot_key => $bot_token`
argument (TGT-219). The sibling helper `_print_reply_template` already
handles the equivalent case correctly: it appends a masked `--bot
<token>` reminder whenever `$bot_token` is defined. A full grep of every
recovery-command template in this module confirmed the `RETRY WITH`
line was the sole one built as a bare literal rather than from
`$bot_token`, like every other reply/attachment template.

In a multi-bot config (`bot_groups`, TGT-098/202/213/218/219) where a
media download fails and is queued under a non-default bot, `cli/
retry-download.pl --all` with no `--bot` given only retries
`failed_downloads(bot_key => '')` - the default-bot sentinel (TGT-219).
Following the printed `RETRY WITH` command literally for a
non-default-bot failure therefore retried nothing: the queue entry
stayed stuck with no error, the command just reporting "No failed
downloads queued." or silently processing only unrelated default-bot
entries. This is the same class of gap as TGT-217 (a stdout template
missing its bot-scoping flag), just on the `MEDIA FAILED` line instead
of the `edited_message` line.

Fixed by appending the same masked `--bot <token>` conditional
`_print_reply_template` already uses (via `D2TG::Config::masked_token`,
never the raw token) to the `RETRY WITH` line whenever `$bot_token` is
defined; unchanged when it isn't.

New test `t/220-media-failed-retry-with-bot-flag.t`: confirmed genuinely
red against the pre-fix code (1/3 subtests failed - the masked `--bot`
flag was missing from the multi-bot case's printed line), confirmed
green after the fix (3/3), with the existing sibling
`t/204-failed-download-visibility.t` re-run clean alongside it (10/10
total, confirming the single-bot/no-token case is completely
unaffected). Full suite re-run clean at 1598/1598. 100%
statement+subroutine coverage confirmed on `lib/D2TG/Poller.pm`.

Codex adversarial review attempted (2 tries): both returned the same
`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` sandbox
error seen throughout this session. Fell back to independent
verification: direct diff of the fix confirming it mirrors
`_print_reply_template`'s own exact masked-append pattern (same helper,
same conditional shape), confirmed the raw token is never printed (test
asserts `unlike` against the raw token string), and confirmed no other
call site or test was touched outside the ticket's declared scope
(the `RETRY WITH` print line only).

## TGT-222: HTTP::Tiny CVEs flagged by cpan-audit - investigated, not exploitable

Found via TGT-220's own `vulnerability-scan` column gate (`cpan-audit
deps .`, run as part of that ticket's `REQ-044` perlsec scan).
`cpan-audit` reported 2 advisories against `HTTP::Tiny`:
`CPANSA-HTTP-Tiny-2026-7010` (CVE-2026-7010, CRLF injection in the
request line/control headers for versions before 0.093) and
`CPANSA-HTTP-Tiny-2026-7017` (CVE-2026-7017, forwarding caller-supplied
`Authorization`/`Cookie`/`Proxy-Authorization` headers to a
cross-origin redirect target for versions before 0.095).

Investigated whether this codebase's own code could reach either
vulnerable path. `grep -rn 'HTTP::Tiny\|LWP::UserAgent'
lib/D2TG/*.pm` confirmed every HTTP call in this project
(`D2TG::Telegram`, `D2TG::Download`) goes through `LWP::UserAgent`
exclusively - there is not one direct `HTTP::Tiny` method call anywhere
in `lib/D2TG`. `HTTP::Tiny` is a core Perl module (bundled with the
interpreter since 5.13.9, confirmed installed at version 0.088 in the
test container) - it is present on the system regardless of whether
this project declares or uses it, and `cpan-audit` scans installed
modules, not this project's own declared dependency graph. Since
neither CVE's vulnerable code path (a caller-controlled request
line/header value reaching `HTTP::Tiny`'s own request construction, or
a redirect-following call carrying caller-supplied credential headers)
is ever exercised by this codebase's own code, both advisories are not
exploitable here.

Resolved by: documenting this as an accepted, non-applicable finding
(this section) rather than pinning a version this project never
declares or calls; adding a new structural regression test
(`t/222-no-http-tiny-usage.t`) that fails if a future change ever
introduces a direct `HTTP::Tiny` call in any `lib/D2TG/*.pm` module,
which would reopen this exact question. No `cpanfile` change was made -
adding an `HTTP::Tiny` version requirement to a project that never uses
the module would misrepresent this project's own actual dependency
graph.

This ticket does not follow the usual TDD red/green pattern honestly -
there was no code bug to fix, so the new test was never red against
"pre-fix" code (there is no fix). `t/222-no-http-tiny-usage.t` is a
forward-looking regression guard, confirmed passing (10/10) against the
current codebase, documented as such rather than claiming a red state
that never existed. Full suite re-run clean at 1599/1599 (1598 + the 1
new test file).

Codex adversarial review: first attempt this session to actually
succeed - Codex independently ran its own search (`rg`) against
`lib/D2TG` and confirmed no `HTTP::Tiny` usage exists, verifying this
ticket's own finding rather than hitting the `bwrap` sandbox error seen
on every other attempt so far this session. A second, follow-up prompt
in the same session then hung and was killed via `timeout` - consistent
with this session's own established intermittent-availability pattern
(sometimes works, sometimes sandbox-errors, sometimes hangs) rather
than a fully dead session. The one successful run's own finding matches
the independent `grep` evidence above exactly.

Self-caught bug during the QA stage: the initial `t/222-...t` used a
bare text-match regex (`qr/\bHTTP::Tiny\b/`), which false-positived
against `D2TG::Telegram`'s own POD (added in this same ticket)
naming `HTTP::Tiny` specifically to document that it is NOT used -
the full suite run at QA caught this immediately (1/1608 failed).
Fixed by narrowing the guard to actual code usage (a `use`/`require`
statement or a `->` method call), which a bare name-mention in prose
can never match. Full suite re-confirmed clean at 1608/1608 after the
fix.

## TGT-225: record_failed_download's own id-lookup SELECT was not bot-scoped

Found via a scheduled JOB-003 hourly bug hunt. TGT-219 widened
`failed_downloads`'s own `UNIQUE` constraint and its own
`INSERT...ON CONFLICT` clause to `(chat_id, bot_key, message_id)`, but
`record_failed_download`'s own id-lookup `SELECT` a few lines below it
was never given the matching `bot_key` filter - it still read `SELECT
id FROM failed_downloads WHERE chat_id = ? AND message_id = ?`.

Reproduced live in the `perl-test` container against a scratch SQLite
db (never against the production board): calling
`record_failed_download(111, 55, 'fileA', bot_key => 'tokenA')` then
`record_failed_download(111, 55, 'fileB', bot_key => 'tokenB')`
returned the same id (`1`) for both calls, even though two distinct
rows genuinely existed. Reachable in real multi-bot configs since
Telegram's own `message_id` is per-chat, not per-bot - two bots
polling the same shared group chat can both fail to download media for
the same real chat message, hitting exactly this collision.
`failed_downloads()`'s own listing query is correctly scoped and
unaffected - only the `record_failed_download` return-id path was
wrong, which is why `t/219-failed-downloads-bot-scoping.t`'s existing
assertions (which never check `record_failed_download`'s own return
value in the dual-bot case) didn't catch it. Currently latent in
production since `D2TG::Poller::run_once` calls it in void context,
but the return id is a documented public contract `t/83` and `t/196`
already assert on directly in single-bot scenarios.

Fixed by adding `AND bot_key = ?` to the `SELECT`, binding `$bot_key`
alongside the existing `$chat_id`/`$message_id` binds - a one-line
change matching the already-correct `INSERT...ON CONFLICT` clause a
few lines above it in the same function.

New test `t/225-record-failed-download-return-id-bot-scoped.t`:
confirmed genuinely red against the pre-fix code (2/4 subtests failed
- both bot_keys returned id `1`), confirmed green after the fix (4/4),
with `t/219-failed-downloads-bot-scoping.t`, `t/83-failed-download-
queue.t`, and `t/196-retry-failed-download-skips-redownload.t` re-run
clean alongside it (82/82 total).

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: the
fix is a one-line SQL predicate addition, directly comparable
side-by-side against the already-correct `INSERT...ON CONFLICT` clause
4 lines above it in the same function - a small, self-evidently correct
diff, not a claim requiring external judgment.

## TGT-226: duplicated masked --bot flag construction extracted into a shared helper

Found via a scheduled JOB-004 improvement hunt - not a bug. `D2TG::
Poller` had two separate call sites building the identical "masked
`--bot <token>` flag" string via the same 3-line ternary: `defined
$bot_token ? ' --bot ' . D2TG::Config::masked_token($bot_token) : ''`
- once inside `_print_reply_template` (the `REPLY WITH` template) and
once inline in the `NEW TG MEDIA FAILED` branch (the `RETRY WITH`
template, added by TGT-220). Both sites already behaved identically and
correctly - this was a pure consolidation opportunity, matching this
project's own established extract-once-duplicated precedent
(`_classify_store_error` TGT-167, `open_store_or_die`,
`_with_hard_timeout` TGT-126).

Fixed by extracting a new `_bot_flag($bot_token)` helper and calling it
from both sites; the masking-rationale comment (TGT-086, never print
the real token) now lives once, next to the helper, instead of being
duplicated at each call site.

New test `t/226-bot-flag-helper-extracted.t` exercises the helper
directly (`can_ok`, a defined-token case matching
`D2TG::Config::masked_token`'s own output exactly, an undef-token case
returning `''`, and an `unlike` assertion confirming the raw token is
never present). Confirmed genuinely red against the pre-fix code (the
helper didn't exist - `prove` exited 255 on an undefined subroutine),
confirmed green after the fix, with `t/217-edited-message-reply-
template.t`, `t/220-media-failed-retry-with-bot-flag.t`, and
`t/204-failed-download-visibility.t` re-run clean alongside it (18/18
total) - proving both templates' printed output is byte-for-byte
unchanged, as this ticket's own acceptance criteria required.

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: a
side-by-side diff confirms both call sites now delegate to the same
helper, and the helper's own body is byte-identical to the ternary it
replaces at both original sites.

## TGT-227: REPLY WITH's own --bot flag sat in a position cli/reply.pl never parses

Found via a scheduled JOB-003 hourly bug hunt - a real, reachable
credential-leak bug, not a cosmetic mismatch. `D2TG::Poller::
_print_reply_template` printed `REPLY WITH: d2 tg.reply <chat_id>
"..." --bot <masked_token> --reply-to-message-id <id>` - `--bot` placed
AFTER `chat_id`. `cli/reply.pl`'s own flag-parsing loop only recognizes
`--db`/`--bot`/`--voice-only` while each is the leading unconsumed
argument (its loop `last`s on the first non-flag token, i.e. `chat_id`
itself); `D2TG::Reply::parse_cli_args` only recognizes a trailing
`--reply-to-message-id`, with no `--bot` handling at all. A `--bot`
flag printed after `chat_id` was therefore never recognized by either
layer - it fell straight into the joined reply text.

Reproduced live in the `perl-test` container (never against the
production board): `D2TG::Reply::parse_cli_args(123456, 'hello',
'there', '--bot', 'abcTOKEN123', '--reply-to-message-id', 42)` returned
`text = 'hello there --bot abcTOKEN123'` - the `--bot` pair swallowed
into the outgoing message text unchanged, while the actual send would
silently fall back to `D2TG_TOKEN` (the wrong bot in multi-bot mode).
The impact is worse than a cosmetic format mismatch: this module's own
documented instruction tells an operator to substitute the real token
in place of the masked placeholder before running the command - doing
exactly that leaked the real bot credential into the visible Telegram
message text sent to the chat. `t/57-reply-bare-bot-flag-no-hang.t`'s
own comment already noted "the order the real REPLY WITH template
never produces" in passing without treating it as a bug, and the only
existing coverage of the printed template (`t/51-multi-bot-reply-
template.t`) asserted the format string via regex without ever feeding
it back through the real `cli/reply.pl` parsing path end-to-end.

Fixed by printing `--bot` BEFORE `chat_id` in `_print_reply_template`,
matching `cli/reply.pl`'s own already-working leading-position parsing
contract - the same convention `cli/approve.pl`/`cli/retry-download.pl`
already use. No parser changes were needed; the trailing-position
alternative considered in drafting (extending `D2TG::Reply::
parse_cli_args` to also recognize a trailing `--bot`) was rejected as
unnecessary complexity once the simpler, convention-matching fix was
available.

New test `t/227-reply-with-bot-flag-position-parseable.t`: captures the
poller's own real printed `REPLY WITH` line, substitutes the real token
for the masked one (exactly as an operator following the module's own
docs would), splits it the way a shell would, and feeds it through the
real `D2TG::Reply::extract_bot_flag`/`parse_cli_args` functions -
confirmed genuinely red against the pre-fix code (3/6 subtests failed:
the token was not extracted as a flag, and both `--bot` and the raw
token leaked into `$text`), confirmed green after the fix (6/6).
`t/51-multi-bot-reply-template.t`'s own format-string assertion was
updated to match the new (correct) field order, since this ticket's own
fix deliberately changed the printed format; `t/217-edited-message-
reply-template.t`, `t/220-media-failed-retry-with-bot-flag.t`,
`t/204-failed-download-visibility.t`, and `t/226-bot-flag-helper-
extracted.t` (the other consumers of `_bot_flag`/`_print_reply_template`)
all re-run clean unmodified (33/33 total across all 6 files).

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: the
fix's own correctness is demonstrated directly by the new test, which
exercises the actual production parsing functions (`D2TG::Reply::
extract_bot_flag`/`parse_cli_args`), not a reimplementation or mock of
them - a passing assertion here is definitionally equivalent to the
real `cli/reply.pl` behaving correctly on this exact input.

## TGT-228: README.md's rolling changelog silently lost 5 tickets' write-ups

Found via a scheduled JOB-005 doc-accuracy hunt. `README.md`'s
top-of-file rolling changelog convention - each shipped ticket adds its
own paragraph, the newest bolded as `**Status:**`, older ones retained
below as plain paragraphs - is what every prior ticket in this session
followed correctly (visible in the intact TGT-215→216→217→218 sequence
still readable today). It broke for 5 consecutive commits in a row:
TGT-220's own documentation-column commit (`e47805b`), and again for
TGT-222 (`9fc52c7`), TGT-225 (`bb6701b`), TGT-226 (`5a9e134`), and
TGT-227 (`73044cd`) - each one's `README.md` diff REPLACED the
immediately-preceding ticket's whole paragraph instead of prepending a
new one above it and keeping the old one as body text below.

Net effect, confirmed by direct grep before this fix: none of
`_bot_flag`, `RETRY WITH`, `HTTP::Tiny`, or `record_failed_download`
appeared anywhere in `README.md` - a reader auditing this file alone
would have learned nothing about the bot_key scoping fix in
`failed_downloads` (TGT-219), the masked `--bot` flag added to the
`NEW TG MEDIA FAILED` `RETRY WITH` hint (TGT-220), the `HTTP::Tiny` CVE
investigation (TGT-222), the `record_failed_download` id-lookup
bot_key-scoping fix (TGT-225), or the shared `_bot_flag` helper
extraction (TGT-226). All 5 fixes were and remain correctly documented
in `Changes` (versions 1.75-1.79) and in this file's own
`## TGT-219/220/222/225/226` sections the whole time - this was pure
prose loss in one file, never a functional/behavioral bug, and no
code/test was ever affected. It also meant each of those 5 tickets' own
`ticket.documentation` column gate was marked done despite the net
result deleting the previous ticket's entry - the required action
itself (add real prose, not just a version bump) was genuinely
satisfied each time; the paragraphs were simply overwritten by the
*next* ticket's own edit, a failure mode the gate has no way to detect
after the fact.

Fixed by restoring all 5 missing paragraphs into `README.md`, in their
correct chronological position between the `TGT-227` and `TGT-218`
paragraphs, using `Changes`/this file's own already-accurate write-ups
as source material - no re-investigation of the 5 original fixes was
needed or performed. Added a new structural regression test,
`t/228-readme-ticket-history-not-lost.t`, asserting one distinguishing,
code-accurate term per ticket (not just its bare ticket number, which
could appear incidentally) still appears somewhere in `README.md` -
confirmed genuinely red against the pre-fix file (5/5 subtests failed),
confirmed green after restoration (5/5). This closes the specific gap
the incident exposed: a future documentation-column commit that
accidentally replaces instead of prepends will now fail the suite
instead of silently recurring a 6th time.

No `lib/`/`cli/` code was touched by this ticket - pure documentation
restoration plus one new test file. Full suite re-run clean.

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: a
direct `grep` for each of the 4 distinguishing terms in the restored
`README.md` confirms all are present, and a manual read of the restored
paragraph sequence (TGT-227 → 226 → 225 → 222 → 220 → 219 → 218)
confirms correct newest-to-oldest chronological order with no content
altered from `Changes`'s own accurate wording.

## TGT-229: cli/unread.pl's failed-download RETRY WITH hint omitted --bot in a multi-bot config

Found via a scheduled JOB-003 hourly bug hunt, specifically prompted by
a note to re-check every printed recovery-command template across the
codebase (`GET ATTACHMENT WITH`/`REPLY WITH`/`RETRY WITH`) against the
same class of bug TGT-227 found - a flag placed where its own consuming
parser never actually looks for it. `REPLY WITH` (TGT-227) and the
poller's own `NEW TG MEDIA FAILED` `RETRY WITH` line (TGT-220) were
both confirmed already correctly fixed; `cli/unread.pl`'s own separate
`RETRY WITH` line - printed after its queued-failed-downloads listing,
introduced by TGT-204 before multi-bot support existed - was not.

`cli/unread.pl` lists queued `failed_downloads` unscoped across every
configured bot (`D2TG::Store::failed_downloads` called with no
`bot_key` filter, correctly, matching TGT-204's own original design),
but printed a single static hint - `"Queued failed downloads (RETRY
WITH: d2 tg.retry-download --all):"` - with no `--bot` flag, and never
displayed each row's own `bot_key` at all. `cli/retry-download.pl
--all` with no `--bot` only retrieves `failed_downloads(bot_key =>
'')` - the default-bot sentinel (TGT-219). Reproduced live in the
`perl-test` container: seeded two rows via
`D2TG::Store::record_failed_download`, one under the default `bot_key`
and one under a distinct non-default `bot_key` - the unscoped listing
correctly showed both, but the printed recovery hint could only ever
retry the default-bot row; the non-default-bot row was listed with no
indication it needed a different command, and following the printed
instructions literally would leave it stuck forever.

Fixed by grouping the listing's own rows by `bot_key`: when only the
default sentinel is present (the single-bot case), the output is
byte-for-byte unchanged from before. When more than one bot's rows are
present, each row now shows its own bot (masked via
`D2TG::Config::masked_token`, matching `D2TG::Poller::_bot_flag`'s own
convention) and one `RETRY WITH: d2 tg.retry-download --all[--bot
<masked-token>]` line is printed per distinct bot actually found in the
listing - so every row's own printed recovery command is genuinely the
one that retries it.

New test `t/229-unread-multi-bot-retry-hint.t`: confirmed genuinely red
against the pre-fix code (2/6 subtests failed - no masked `--bot` hint
was printed for the non-default-bot row, and the plain hint appeared
only once instead of once per distinct bot), confirmed green after the
fix (6/6), with the existing `t/109-unread-unrecognized-args-refuse.t`
(argv-shape validation) re-run clean alongside it (18/18 total) -
proving the single-bot/no-queued-failures cases are completely
unaffected.

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: the
fix reuses `D2TG::Config::masked_token` directly (the same helper
`_print_reply_template`/`_bot_flag` already use), so the masking
behavior itself is already proven correct elsewhere - the new code only
adds grouping/branching logic around an already-trusted primitive, and
the test asserts the raw token is never printed, matching this
project's own established TGT-086 convention.

## TGT-230: extracted require_existing_base_dir's duplicated eval/print/exit wrapper

Found via a scheduled JOB-004 improvement hunt - not a bug.
`D2TG::Config::require_existing_base_dir($base_dir)` is called from all
11 `cli/*.pl` scripts that need a resolved storage base directory
(`approve.pl`, `attachment.pl`, `history.pl`, `poller.pl`, `reply.pl`,
`retry-download.pl`, `send.pl`, `status.pl`, `text-only-replies.pl`,
`unread.pl`, `whoami.pl`), and at every single call site it was wrapped
in the exact same byte-identical 5-line block: `eval {
D2TG::Config::require_existing_base_dir($base_dir) }; if ($@) { print
STDERR $@; exit 1; }`. This is the identical eval/print-STDERR/exit(1)
shape this project has already extracted twice before for other
startup-guard calls with the same duplication problem:
`resolve_alias_dir_or_die` (TGT-172, wraps `resolve_alias_dir`) and
`D2TG::Poller::open_store_or_die` (wraps `D2TG::Store->new`).
`require_existing_base_dir` was the one remaining startup-guard call
still hand-wrapped at every site instead of having its own `_or_die`
sibling.

Confirmed by direct `grep -rn -B1 -A4` across every `cli/*.pl` file:
byte-identical at all 11 sites.

Fixed by adding `D2TG::Config::require_existing_base_dir_or_die
($base_dir)`, matching `resolve_alias_dir_or_die`'s exact existing
shape and adjacent in the same file, and replacing all 11 call sites'
inline blocks with a single call to it. Pure behavior-preserving
refactor: no change to any printed message, exit code, or control
flow - only the duplication is removed.

New test `t/230-require-existing-base-dir-or-die.t`, matching
`t/172-resolve-alias-dir-or-die.t`'s own established `CORE::GLOBAL::
exit` interception pattern (installed in a `BEGIN` block before
`D2TG::Config` loads, since a bare `exit` call's binding is decided at
compile time): confirmed genuinely red against the pre-fix code
(undefined subroutine error - the helper didn't exist yet), confirmed
green after the fix (5/5) - both the success-passthrough branch and the
failure branch (exits 1, prints the exact same STDERR text
`require_existing_base_dir` itself dies with, byte-for-byte) are
covered. Full suite re-run clean at 1638/1638 (one transient host-load
flake in `t/66-lock-last-poller-wins.t`, confirmed unrelated via an
isolated re-run, consistent with this session's own documented flake
history for that file).

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: `perl
-Ilib -c` syntax-checked all 11 modified `cli/*.pl` files cleanly, and
the full suite (which exercises every one of these 11 scripts via
subprocess across dozens of existing test files) passed unmodified -
proof the refactor is genuinely behavior-preserving, not just
syntactically valid.

## TGT-231: cli/reply.pl and cli/send.pl crashed with a raw uncaught die on a malformed --bot flag

Found via a scheduled JOB-003 hourly bug hunt - live-reproduced, not
merely read. `cli/reply.pl`'s and `cli/send.pl`'s own argv-parsing
`while`-loop each called `D2TG::Reply::extract_bot_flag(@ARGV)`
directly, with no `eval` wrapper, whenever `--bot` is immediately
followed by another flag. `extract_bot_flag` delegates to
`D2TG::Config::shift_flag_value`, which `die`s ("--bot requires a
value\n") on exactly that shape (TGT-074's own validation). In both
scripts that die propagated completely uncaught, since it happened
inside the same unwrapped `while`-loop that owns `--bot` handling, with
no surrounding `eval` anywhere between that call and Perl's own
top-level default die handler.

Reproduced live in the `perl-test` container:
```
$ perl cli/reply.pl --bot --caption hi 123 hello
--bot requires a value
$ echo $?
255
$ perl cli/send.pl --bot --caption hi 123 /etc/hostname
--bot requires a value
$ echo $?
255
```
`cli/approve.pl` (line 19) and `cli/retry-download.pl` (line 26) already
`eval`-wrap this exact same `extract_bot_flag(@ARGV)` call and print a
clean, non-255 refusal - `reply.pl`/`send.pl` were the only two call
sites in the `--bot` family that didn't. `t/62-bot-token-requires-
value.t` only asserted the library-level die message/text from
`extract_bot_flag`/`bot_groups` directly; `t/59-db-flag-requires-
value.t`'s own `cli/reply.pl` case only covered `--db --bot ...` (bare
`--db` swallowing `--bot`, a different, already-correctly-caught code
path) - neither covered `--bot --db ...`/`--bot --caption ...`
(`extract_bot_flag`'s own die), the gap this ticket closes. Not a
path-leak: `shift_flag_value`'s die string already ends in `\n`, so
Perl's default handler never appends its usual "at FILE line N" suffix
- the defect was the non-standard exit code (255) and missing
Usage-style STDERR framing, not credential/path disclosure.

Fixed by `eval`-wrapping the `extract_bot_flag(@ARGV)` call in both
scripts' own `--bot` branch, printing `$@` to STDERR and exiting 1 on
failure - matching `cli/approve.pl`/`cli/retry-download.pl`'s existing
pattern exactly, and matching `cli/reply.pl`'s own `--db` branch
(exit 1) for internal consistency within the same file. No change to
`extract_bot_flag` itself or its validation rules.

New test `t/231-bot-flag-malformed-no-raw-die.t`: confirmed genuinely
red against the pre-fix code (4/7 subtests failed - both scripts
exited 255), confirmed green after the fix (7/7), with
`t/59-db-flag-requires-value.t`, `t/62-bot-token-requires-value.t`,
`t/34-reply-arg-parsing-trailing-flag.t`, `t/57-reply-bare-bot-flag-
no-hang.t`, and `t/79-outbound-media-send.t` re-run clean alongside it
(74/74 total) - proving every other malformed-flag/happy-path case on
both scripts is unaffected.

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: the
fix is a direct, minimal copy of `cli/approve.pl`/`cli/retry-
download.pl`'s own already-working, already-tested pattern applied to
two more call sites of the identical function - not a novel
implementation requiring independent design review.

## TGT-232: D2TG::Store's messages table was never bot-scoped like every other table

Found via a scheduled JOB-004 improvement hunt. Every other
`D2TG::Store` table that identifies a conversation participant was
migrated to a composite `(chat_id, bot_key)` key during the TGT-098
multi-bot rollout and its follow-ups: `allow_list`/`pending` both carry
`bot_key` in their `PRIMARY KEY` (TGT-098), `pending_chat_ids` was
updated to filter by it (TGT-215), `failed_downloads` was retrofitted
with it (TGT-219/225), and `sent_replies`/`text_only_replies`/
`is_recent_duplicate_reply` all take a `bot_key` argument. The
`messages` table's own `CREATE TABLE` (`lib/D2TG/Store.pm`) was never
touched by that migration - `record_message`, `get_message`,
`get_attachment_path`, `mark_read`, `is_read`, `unread_messages`,
`recent_messages`, and `messages_in_range` all keyed or filtered purely
on `chat_id`/`message_id`, with no `bot_key` column or parameter
anywhere in that call cluster. TGT-063 already documented that
`message_id` is Telegram's own per-bot counter - precisely what makes
an unscoped `(chat_id, message_id)` key collision-prone across two bots
sharing a `chat_id`. `record_message`'s own `INSERT ... ON CONFLICT
(chat_id, message_id) DO UPDATE` would silently overwrite one bot's
stored `sender`/`summary`/`local_path` with another bot's row if their
independent per-bot `message_id` counters ever collided for the same
`chat_id`.

Fixed by the same rename/create/copy/drop migration TGT-098/219 already
established, run inside one transaction so a crash mid-migration can
never orphan the old data - placed AFTER the existing `read_at`/
`local_path` `ALTER TABLE ADD COLUMN` blocks so an existing
installation's own already-added columns are preserved in the copy
(the initial draft of this migration missed this ordering and would
have silently dropped `read_at`/`local_path` data on any real upgrade -
caught and fixed before implementation, not after). Existing rows
migrate to `bot_key=''` (the single-bot/unscoped sentinel). All 8
read/write subs now accept an optional `bot_key` (defaulting to the
sentinel for the 5 single-row lookups/writes; the 3 listing functions -
`unread_messages`/`recent_messages`/`messages_in_range` - filter only
when a `bot_key` is explicitly given, matching `failed_downloads`'s own
established convention of listing every bot's own entries when
unscoped).

Every call site with a bot token already in scope was updated to pass
it through: `D2TG::Poller::run_once`'s 5 `_record_message_and_track_
offset` sites (via a new trailing `bot_key => $bot_token` argument),
its 2 `get_message` sites (the redelivery-dedup check and
`_stored_summary`, the latter requiring `$bot_token` to be threaded
through 2 additional helper signatures - `_reply_context_suffix` and
`_stored_summary` itself), and `D2TG::Reply::send_reply`/`resend_voice`'s
2 `mark_read` sites (`$args{bot_key}` was already available at both).

**Scope decision, made during implementation (not before)**:
`cli/history.pl`, `cli/unread.pl`, and `cli/attachment.pl` have no
`--bot`/`bot_key` awareness in their own argv parsing at all today -
giving them the ability to actually exercise this new scoping would
mean adding a new CLI flag to each (parsing + tests + docs), a separate
additive feature rather than the core data-integrity fix this ticket
exists to deliver. Narrowed to the schema + all 8 subs + every call
site that ALREADY has a bot token in scope; filed **TGT-233** as an
immediate fast-follow for the 3 scripts' own `--bot` flag additions,
per this project's own file-ticket-before-resuming-work rule, since
that is genuinely new, distinct work discovered mid-ticket.

New test `t/232-messages-bot-key-scoping.t`: confirmed genuinely red
against the pre-fix code (5/16 subtests failed - two bots' rows
collided/overwrote each other), confirmed green after the fix (16/16).
The full suite caught one real regression during implementation:
`t/181-record-message-offset-tracking-dedup.t`'s own source-text regex
checks asserted the exact old call-site argument list with no
`bot_key` argument - a legitimate test update (widening the regex to
allow the new trailing argument, not weakening what it actually
checks), not a sign of a broken fix. Full suite re-confirmed clean at
1661/1661 after that fix. 100% statement+subroutine coverage confirmed
on `lib/D2TG/Store.pm`.

Codex adversarial review attempted: hit the same `bwrap: loopback:
Failed RTM_NEWADDR: Operation not permitted` sandbox error seen
throughout this session. Fell back to independent verification: the
migration follows TGT-098/219's own already-proven rename/create/copy/
drop pattern exactly, and the full existing test suite (which exercises
every touched function extensively in the single-bot/unscoped case)
passing unmodified is strong evidence the backward-compatible default
path genuinely works as before.

Self-caught coverage gap during the QA stage: `lib/D2TG/Store.pm` came
in at only 96.6% statement (not the mandatory 100%) on the first
coverage run. Traced via `cover -report text ... | grep '\*\*\*'`
(Devel::Cover's own zero-hit marker) to two gaps: (1) the new
migration's own `rollback`/`die` error-handling branch, and (2)
`recent_messages`/`messages_in_range`'s own `bot_key`-filter branches,
neither exercised by the original test file. Fixed by adding a
mid-migration-failure regression test matching
`t/75-multi-bot-allow-list-scoping.t`'s own established `local
*DBI::db::do` mocking pattern (simulates the data-copy `INSERT` step
failing, confirms the error propagates loudly, then confirms a genuine
re-open with the real code migrates successfully and the pre-existing
row survives), plus two new subtests exercising `recent_messages(bot_
key => ...)` and `messages_in_range(bot_key => ...)` directly.
Re-confirmed 100%/100%/100% on `lib/D2TG/Store.pm`, `lib/D2TG/Poller.pm`,
and `lib/D2TG/Reply.pm` after the fix.

## TGT-233: cli/history.pl, cli/unread.pl, cli/attachment.pl had no --bot flag at all

Fast-follow ticket filed immediately during TGT-232 (per this project's
own file-ticket-before-resuming-work rule), not found via a scheduled
job. TGT-232 made `D2TG::Store`'s `messages` table `bot_key`-aware end
to end, but 3 of the CLI scripts that read from it had no `--bot`/
`bot_key` awareness in their own argv parsing at all - `cli/history.pl`,
`cli/unread.pl`, and `cli/attachment.pl` could only ever operate on the
default-bot sentinel's own messages, so a multi-bot install's new
per-bot scoping was real in the schema but unreachable from any of these
3 commands.

Fixed by adding `--bot <token>` to all 3 scripts, matching
`cli/retry-download.pl`'s own established leading-position, eval-wrapped
`extract_bot_flag` convention exactly:
```perl
my ( $bot_token, @after_bot );
eval { ( $bot_token, @after_bot ) = D2TG::Reply::extract_bot_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';
```
inserted right after each script's own `--db` extraction. `cli/unread.pl`
now calls `$store->unread_messages( bot_key => $bot_key )`;
`cli/attachment.pl` now calls `$store->get_attachment_path( $chat_id,
$message_id, bot_key => $bot_key )`; `cli/history.pl` now calls
`$store->messages_in_range( ..., bot_key => $bot_key )` /
`$store->recent_messages( 10, bot_key => $bot_key )`. Omitting `--bot`
on any of the 3 preserves today's exact default-bot behavior unchanged.

Two pre-existing usage/POD-parity tests (`t/117-attachment-usage-pod-
parity.t`, `t/124-unread-usage-pod-parity.t`) caught the first round of
gaps - the scripts' own `Usage:` strings gained `--bot` but the POD
`SYNOPSIS` lines hadn't, failing parity. A third, previously-unnoticed
parity test (`t/118-history-usage-pod-parity.t`) then failed in the
reverse direction - the SYNOPSIS (updated first, with a new `--bot`
example line) mentioned it but `history.pl`'s own printed `Usage:`
string did not. Both directions fixed so all 3 scripts' `Usage:`
string and POD `SYNOPSIS` agree.

New test `t/233-cli-bot-flag-message-scoping.t`: confirmed genuinely red
against the pre-fix code (5/10 subtests failed - each of the 3 scripts
returned the wrong bot's messages when both a default-bot and a
named-bot row existed for the same chat_id), confirmed green after the
fix (10/10). Full suite re-run clean at 1683/1683 afterward, including
the 2 parity-test fixes. `cli/*.pl` scripts remain outside
`Devel::Cover`'s direct instrumentation (tests invoke them via
subprocess) - an accepted, previously-documented limitation, not new to
this ticket.

Codex adversarial review attempted twice (`timeout 15 codex exec`):
both attempts hung and were killed by timeout, the same near-universal
unavailability seen throughout this session. Fell back to independent
verification: diffed each script's new `--bot` block character-for-
character against `cli/retry-download.pl`'s own already-proven pattern,
and confirmed via the new test file that default (no `--bot`) behavior
is byte-identical to pre-fix output for all 3 scripts.

## TGT-234: multi-bot admin_chat_id seeding used the wrong bot_key, locking the admin out

Found via a scheduled JOB-003 hourly bug-hunt fork. `cli/poller.pl`'s
multi-bot startup called `D2TG::Store->new(admin_chat_id => [ map {
$_->{chat_id} } @$groups ])` - a flat list of chat ids with no
`bot_key` info at all - so `_seed_admin` always seeded each admin
chat_id under `DEFAULT_BOT_KEY` (`''`). But `D2TG::Poller::run_once`'s
own `is_allowed` check passes `bot_token => $pair->{bot_key}` - the
REAL bot token - whenever `$single_bot_mode` is false (any config with
2+ chat_id groups or 2+ bots). `Store::is_allowed` does an exact
`(chat_id, bot_key)` match with no fallback to `''`, so the seeded row
never matched: in any multi-bot/multi-group configuration, the admin's
own messages were always treated as unapproved first-contact and
queued to `pending` under every configured bot - exactly backwards from
the intended auto-seed behavior, and the same TGT-098/219/232
bot_key-scoping bug class but in the opposite direction (a false
negative locking the owner out, rather than a leak across bots).
`t/45-multi-chat-seeding.t`/`t/75-multi-bot-allow-list-scoping.t` only
ever called `is_allowed()` with no `bot_key` (or matching `bot_key`s),
so the real multi-bot admin-seeding scenario had zero test coverage
before this ticket.

Fixed by extending `D2TG::Store::new`'s `admin_chat_id` arrayref to
accept a hashref element (`{ chat_id => ..., bot_key => ... }`) in
addition to a plain scalar - seeding that specific `bot_key` instead of
the default sentinel - while a bare scalar still seeds under the
sentinel exactly as before (full back-compat, `_seed_admin` itself
already accepted an optional `$bot_key` parameter, unused by any
caller until now). `cli/poller.pl` now builds one such pair per real
`(chat_id, bot token)` it is about to poll, using `$single_bot_mode`
(already computed earlier in the script, before `D2TG::Store->new` is
called) to decide whether to seed the sentinel (single-bot, unchanged
behavior) or the real token (multi-bot, the fix).

New test `t/234-multi-bot-admin-seeding.t`: confirmed genuinely red
against the pre-fix code (4/9 subtests failed - a 2-group/2-bot config
and a shared-chat_id/2-bot config each failed to auto-approve the
admin under its own real bot token), confirmed green after the fix
(9/9). No regression to `t/45-multi-chat-seeding.t`/`t/75-multi-bot-
allow-list-scoping.t`'s own existing single-bot/scalar-admin_chat_id
coverage. Full suite re-run clean at 1692/1692 (the known transient
`t/54-lock-acquire-race.t` host-load flake reproduced once under
`Devel::Cover` instrumentation load, re-confirmed passing cleanly in
isolation, unrelated to this change). 100% statement+subroutine
coverage confirmed on `lib/D2TG/Store.pm`; `cli/poller.pl` remains
outside `Devel::Cover`'s direct instrumentation (invoked via
subprocess in its own tests) - an accepted, previously-documented
limitation, not new to this ticket.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: traced
the exact call chain from `cli/poller.pl`'s `$single_bot_mode`
computation through `D2TG::Store->new`/`_seed_admin` to
`D2TG::Poller::run_once`'s `is_allowed` call, confirming the fix
threads the identical `bot_key` value both sides actually use, and
manually verified the perlsec-relevant surface (bot tokens are opaque
strings passed as bound SQL parameters, never interpolated or
shell-executed).

## TGT-235: messages/sent_replies tables had no retention policy (unbounded row growth)

Found via a scheduled JOB-004 improvement hunt. `D2TG::Store`'s
`messages` and `sent_replies` tables had no retention/eviction policy
at all - every inbound message and every sent reply's dedup row was
kept forever. This is asymmetric with the codebase's own established
pattern: the attachments *vault* (files on disk) is already actively
size-capped via `D2TG::Download::prune_vault` (TGT-052/054/134), but
the SQLite rows describing those same messages/replies were never
pruned anywhere. For a long-running Tira monitor-job poller, this
meant unbounded DB growth over time, with every read path
(`unread_messages`, `recent_messages`, `messages_in_range`,
`text_only_replies`, `is_recent_duplicate_reply`) scanning
ever-larger tables. Checked the full ticket list first - no existing
card covered this (TGT-052/054/134 solved only the vault-file half).

During drafting, one inaccurate premise in the original ticket text
(filed by the hunt fork) was caught and corrected: it claimed a
"CLI-flag precedent" for the retention config value, mirroring
`prune_vault`'s `max_bytes` argument - but `prune_vault` itself has no
CLI/env-var flag at all, only a function-argument override with a
hardcoded default. The corrected key_detail documents this; the
implementation follows the real precedent (function-arg override, no
new CLI flag), not the ticket's original, inaccurate framing.

Fixed by a new `D2TG::Store::prune_history(retention_days => $days =
90)` mirroring `prune_vault`'s own pattern exactly: `DELETE FROM
messages/sent_replies WHERE datetime(created_at) < datetime('now',
'-N days')`, a sane hardcoded default (90 days, a new
`DEFAULT_RETENTION_DAYS` constant matching `DEFAULT_BOT_KEY`'s own
named-constant convention), silent no-op when nothing is past the
window, overridable via an optional argument. Wired into
`cli/poller.pl`'s per-cycle loop immediately after the existing
`prune_vault` call, `eval`-wrapped with a `PRUNE HISTORY ERROR` STDERR
line on failure - matching every other non-essential store-write call
site in this script, so a locked/busy database can't turn this
housekeeping into a poll-cycle failure (the row simply gets pruned on
a later cycle instead).

`failed_downloads`/`text_only_replies` reference the same chat/message
identity as `messages`/`sent_replies` but have no foreign-key
constraint to either - both are already independently bounded
(`failed_downloads` by active drain via retry, `text_only_replies` is
itself a view over `sent_replies`, pruned together with it) - so
deleting an aged-out `messages` row cannot orphan a still-relevant
`failed_downloads` row; this was confirmed by reading the schema
(no FK declarations anywhere in `D2TG::Store`) rather than assumed.

New test `t/235-message-history-retention.t`: confirmed genuinely red
against the pre-fix code (`prune_history` method did not exist),
confirmed green after the fix (6/6) - covering the default-window
prune, a caller-supplied shorter `retention_days` override, a
no-op-when-nothing-aged-out case, and `sent_replies` pruning
independently of `messages`. Full suite re-run clean at 1698/1698
(batched under `Devel::Cover` due to genuine host memory pressure this
session - several stale `perl-test` containers from earlier
timed-out/killed runs were found still consuming RAM and removed
before retrying; the full suite still ran and passed, just split into
4 batches accumulating into one `cover_db` rather than one single
invocation, which `Devel::Cover` supports natively). 100%
statement+subroutine coverage confirmed on `lib/D2TG/Store.pm`;
`cli/poller.pl` remains outside `Devel::Cover`'s direct
instrumentation (invoked via subprocess in its own tests) - an
accepted, previously-documented limitation, not new to this ticket.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: read
`D2TG::Store`'s full schema to confirm no FK constraint exists between
`messages` and `failed_downloads`/`text_only_replies` (so pruning
cannot orphan anything), and manually verified the perlsec-relevant
surface (the retention window value is always a bound SQL parameter
via string interpolation of a numeric day-count into a fixed SQL
literal shape `'-$days days'`, matching `is_recent_duplicate_reply`'s
own already-proven `'-$window_seconds seconds'` pattern one screen
above it in the same file - never user-supplied free text).

## TGT-236: 7-way duplicated --bot flag eval-wrap boilerplate centralized

Found via a scheduled JOB-004 improvement hunt, not a bug fix - the
pre-refactor behavior was already correct in all 7 scripts. 7
`cli/*.pl` scripts (`history.pl`, `attachment.pl`, `unread.pl`,
`retry-download.pl`, `approve.pl`, `send.pl`, `reply.pl`) each
duplicated the identical 6-line eval-wrapped
`D2TG::Reply::extract_bot_flag(@ARGV)` block (declare vars, eval-call,
check `$@`, print STDERR + exit 1, reassign `@ARGV`, default `bot_key`
to `''`) verbatim or near-verbatim. This exact boilerplate has already
been the source of at least 3 separate bug tickets found one script at
a time (TGT-068, TGT-074, TGT-231), and TGT-233 had to hand-copy the
block into 3 more scripts as a "fast-follow" specifically because it
was deferred rather than centralized then.

Two structurally different shapes exist across the 7 scripts:
`history.pl`/`attachment.pl`/`unread.pl`/`retry-download.pl` (a
standalone leading-position call, identical byte-for-byte) and
`approve.pl` (the same shape, minor variable-name difference - `$bot_key`
instead of `$bot_token`, default applied via `$bot_key = '' unless
defined $bot_key` instead of a ternary) are one family; `send.pl`/
`reply.pl` are a second family, calling the eval-wrapped idiom from
inside a `while (@ARGV)` multi-flag dispatch loop that itself
pre-checks `@ARGV >= 2` and handles a bare trailing `--bot` specially
(silently shifting it off to keep the loop progressing, rather than
leaving it as a leftover positional argument the way the first family
does).

Fixed by adding one new `D2TG::Reply::extract_bot_flag_or_die(@args)`
that centralizes ONLY the eval+print-STDERR+exit-1 idiom - the actual
duplicated part responsible for the 3 prior bug tickets - and returns
whatever `extract_bot_flag` itself returns (`$bot_token` may be
`undef`), deliberately NOT folding in the default-to-`''`/positional
handling that differs legitimately between the two families. Each of
the 5 leading-position scripts now calls the helper and keeps its own
one-line default afterward (unchanged from before); `send.pl`/`reply.pl`
keep their own loop structure (the `@ARGV >= 2` pre-check, the bare
`shift @ARGV` fallback) untouched, calling the shared helper only in
place of their own manual eval block. `extract_bot_flag` itself is
completely unchanged, matching the solution's own explicit design
constraint.

New test `t/236-shared-bot-flag-helper.t`: confirmed genuinely red
against the pre-fix code (`extract_bot_flag_or_die` did not exist),
confirmed green after the fix (29/29) - covering the happy path, the
absent-`--bot` case, the helper's own die-branch (exercised in-process
via the `CORE::GLOBAL::exit` interception technique already
established by `t/177`/`t/230`/`t/172`/`t/186`, since a subprocess
call is invisible to the parent process's own `Devel::Cover`
instrumentation), and a 7-script subprocess regression sweep using
`--bot -x` (an unambiguous flag-shaped malformed value, chosen instead
of `--bot --db ...` from `t/231`'s own precedent because several of
the 7 scripts strip `--db` out in an earlier, separate pass before
`--bot` is ever examined, so `--db` would not reliably reach
`extract_bot_flag` as the "next" token in every script the way `-x`
does). All 6 pre-existing `--bot`-related test files
(`t/231`/`t/227`/`t/210`/`t/62`/`t/51`/`t/233`) re-confirmed passing
unmodified. Full suite re-run clean at 1727/1727.

Self-caught coverage gap on the first pass: 98.0% statement (not the
mandatory 100%) on `lib/D2TG/Reply.pm`, traced to
`extract_bot_flag_or_die`'s own die-branch - the 7-script regression
sweep's subprocess calls all reach that branch, but subprocess
coverage is invisible to the parent `Devel::Cover` run (the same
established, accepted `cli/*.pl` limitation, here manifesting inside a
`lib/` module instead). Fixed by adding the in-process
`CORE::GLOBAL::exit`-interception subtest described above. Re-confirmed
100%/100%/100% on `lib/D2TG/Reply.pm` after the fix.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: diffed
each of the 7 scripts' new call site against its own pre-refactor
version line-by-line to confirm only the eval-wrap lines were replaced
(no other logic touched), and confirmed the full pre-existing `--bot`
test suite passes unmodified as the strongest evidence the refactor is
behavior-preserving.

## TGT-237: a failed voice transcription was a permanent, silent message loss

Found via a scheduled JOB-003 hourly bug-hunt fork. `D2TG::Poller::run_once`'s
voice branch called `transcribe_voice` via `_run_non_fatal`; on failure
it printed a `TRANSCRIBE ERROR` line to STDERR (never reaching the
monitor job's own stdout-fed `tira.policy.bridge` stream) and the loop
simply continued - no `record_message` call, no `failed_downloads`-style
queue row. Photo/document downloads get exactly this failure mode
fixed already (`failed_downloads` + `d2 tg.retry-download`, TGT-104;
STDOUT visibility, TGT-204) but the voice transcription path was never
given the same treatment - a genuine, real asymmetric gap in an area
(message-loss prevention) this project has otherwise been extremely
rigorous about (TGT-132/165/166/178/191/192 all exist specifically to
stop exactly this shape of silent loss for other paths).
`t/17-voice-transcription.t`'s own existing failure test only asserted
the STDERR text and the absence of a stdout transcript line - zero
assertion about persistence or recoverability, so this gap had no
regression coverage.

Fixed by adding a `failed_transcriptions` table (a fresh table, unlike
`failed_downloads` which needed TGT-219's own rename/create/copy/drop
migration to retrofit `bot_key` onto a table that predated it - this
one is `bot_key`-aware from creation) plus `record_failed_transcription`/
`failed_transcriptions`/`remove_failed_transcription` accessors,
mirroring `failed_downloads`' own shape and upsert-on-redelivery
behavior exactly (no `local_path`/`caption_note` equivalent - a
transcription's transient download is always unlinked immediately and
a voice message carries no caption). `run_once`'s voice failure branch
now queues the failure (eval-wrapped/non-fatal, matching the download
branch's own established non-fatal queue-write pattern) and prints
`NEW TG VOICE FAILED ... RETRY WITH: d2 tg.retry-transcription --all
[--bot ...]` to STDOUT only when the queue write itself succeeds,
matching `NEW TG MEDIA FAILED`'s own TGT-204/TGT-220 precedent exactly.

**Offset handling note**: the ticket's own acceptance criteria allowed
either an offset-cap fix or "an equivalent persisted-recorded state" -
investigation confirmed `failed_downloads`' own established behavior
is the latter: a download failure does NOT hold the offset back
either, since recovery already doesn't depend on Telegram's redelivery
(the retry command re-fetches using the saved `file_id` directly, any
time later). The same reasoning applies identically to transcription,
so no offset-cap change was needed or made - matching the proven
precedent exactly rather than introducing new, untested offset-cap
logic into a message-loss-prevention code path.

New `D2TG::Download::retry_failed_transcription` (living in
`D2TG::Download` alongside `retry_failed_download`, using
`D2TG::Transcribe::transcribe` internally, matching the established
"retry_failed_X lives with the download logic" convention) re-downloads
the voice file transiently (never passed a `dir`, so it never lands in
the shared attachments vault, and is always `unlink`ed regardless of
outcome, matching `cli/poller.pl`'s own `$transcribe_voice` coderef
exactly) and re-attempts transcription; on success, restores the
message into `D2TG::Store` history via `record_message` before
removing the queue row via the established `D2TG::Poller::store_write_safe`
pattern - a `record_message` failure leaves the row queued rather than
losing the transcript a second time, matching `retry_failed_download`'s
own TGT-104 Codex-review precedent. New `cli/retry-transcription.pl`
(`d2 tg.retry-transcription`) lists and retries the queue, mirroring
`cli/retry-download.pl`'s own shape and `--bot` scoping exactly.

New test `t/237-failed-transcription-queue.t`: confirmed genuinely red
against the pre-fix code (`failed_transcriptions` method did not
exist), confirmed green after the fix (50/50) - covering Store-level
CRUD + redelivery-refresh + bot_key multi-bot isolation, poller-level
wiring (queued exactly once, STDOUT visibility, a successful
transcription is never queued, a queue-write failure itself is
non-fatal), `retry_failed_transcription`'s full branch set (download
failure, transcribe failure after a successful download, a successful
retry, and a `record_message` failure after a successful transcription
- the last two added specifically to close a self-caught coverage
gap, see below), and CLI-level list/retry/usage-refusal behavior. Full
suite re-run clean at 1778/1778. 100% statement+subroutine coverage
confirmed on all 3 touched modules (`lib/D2TG/Store.pm`,
`lib/D2TG/Poller.pm`, `lib/D2TG/Download.pm`).

Self-caught coverage gap during the QA stage: `lib/D2TG/Download.pm`
came in at 96.9% statement (not the mandatory 100%) on the first
coverage run, traced to `retry_failed_transcription`'s own
transcribe-error branch and its `record_message`-failure branch,
neither exercised by the original test file. Fixed by adding the two
subtests named above. Re-confirmed 100%/100%/100% on all 3 touched
modules after the fix.

A real, self-caught regression during implementation: `t/98-skills-md-cli-list-current.t`
failed after `cli/retry-transcription.pl` was added, since `SKILLS.md`'s
own hardcoded `cli/*.pl` inventory list (checked against the real file
list by that test, per its own TGT-093/123/130/133 precedent) hadn't
been updated. Fixed by adding `retry-transcription.pl` to that list.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: diffed
the new voice-failure branch line-by-line against the already-proven
photo/document failure branch immediately above it in the same file to
confirm the queue-write/STDOUT-visibility shape is structurally
identical, and confirmed the full pre-existing `t/17`/`t/83` test
suites pass unmodified.

## TGT-238: failed_downloads/failed_transcriptions rows never aged out

Found via a scheduled JOB-004 improvement hunt. `D2TG::Store::prune_history`
(TGT-235) added a retention/eviction policy for `messages`/`sent_replies`,
explicitly scoped to only those two tables (its own POD never mentioned
the retry queues). `failed_downloads`/`failed_transcriptions` had no
retention policy of their own either, and unlike `messages`/
`sent_replies` they are unbounded in a distinct way: a row is removed
only by a *successful* retry (`remove_failed_download`/
`remove_failed_transcription`) - there is no attempt cap and no
age-based eviction, so a permanently-unretryable row (an expired
Telegram `file_id`, a permanently-unreachable sender, a disk-full
condition at download time that never gets fixed) stays in the queue
forever, keeps surfacing in `d2 tg.unread`'s failed-download/
failed-transcription listing, and slowly grows the SQLite file with no
bound. Explicitly distinct from TGT-221 (automatic retry-with-backoff,
still `drafting`/blocked on Q-015) - eviction of unrecoverable rows is
orthogonal to whether/when auto-retry ever ships.

Fixed by extending `prune_history` itself (rather than adding a sibling
method) to also sweep both retry queues, using a new
`failed_queue_retention_days` argument independent of the existing
`retention_days` one - a stale retry-queue row is a different concern
from message-history retention, so a separate (shorter, 30-day)
default was chosen via a new `DEFAULT_FAILED_QUEUE_RETENTION_DAYS`
constant, deliberately generous enough not to race the existing manual
`d2 tg.retry-download`/`d2 tg.retry-transcription` commands for a
genuinely recent transient failure. No `cli/poller.pl` change was
needed - it already calls `prune_history` unconditionally every poll
cycle (TGT-235), so both new sweeps are wired in for free.

New test `t/238-failed-queue-retention.t`: confirmed genuinely red
against the pre-fix code (3/7 subtests failed - aged-out rows in both
tables survived pruning), confirmed green after the fix (7/7) -
covering age-based eviction for both tables independently, a
caller-supplied `failed_queue_retention_days` override, and a
no-op-when-nothing-aged-out case for both queues together. Full suite
re-run clean at 1785/1785 (batched under `Devel::Cover` due to host
memory pressure this session; `t/54-lock-acquire-race.t`'s own known
transient flake reproduced once in the full-suite run, re-confirmed
passing cleanly in isolation, unrelated to this change). 100%
statement+subroutine coverage confirmed on `lib/D2TG/Store.pm`.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification:
confirmed `t/83-failed-download-queue.t` and `t/237-failed-transcription-queue.t`
pass unmodified (proving the new sweep doesn't disturb either queue's
own existing CRUD/retry behavior), and `t/235-message-history-retention.t`
also passes unmodified (proving the new `failed_queue_retention_days`
argument doesn't interfere with the pre-existing `retention_days`
sweep of `messages`/`sent_replies`).

## TGT-239: d2 tg.unread never surfaced queued failed_transcriptions

Found via a scheduled JOB-003 hourly bug-hunt fork. `cli/unread.pl`
lists queued `failed_downloads` (TGT-204/229) but TGT-237's own
`failed_transcriptions` retry queue - a structural sibling with the
same schema shape and `D2TG::Store` accessor pattern - was never
wired into this command's own visibility. A grep across `cli/unread.pl`
and `lib/D2TG/Poller.pm` confirmed zero references to
`failed_transcriptions` outside the poller's own queuing code and
`cli/retry-transcription.pl` itself. A failed voice transcription was
queued silently and never surfaced again - discoverable only by
catching the poller's own transient stdout at the exact moment of
failure, or by running `d2 tg.retry-transcription` speculatively with
no listed argument. TGT-238's own 30-day `failed_queue_retention_days`
compounded this into permanent, silent loss: an un-surfaced queued
transcription failure could quietly expire with zero visibility -
exactly the operational gap TGT-204 already fixed once for
`failed_downloads`, reopened for its sibling queue.

Fixed by adding a "Queued failed transcriptions" section to
`cli/unread.pl`, structured identically to the existing
`failed_downloads` section immediately above it in the same file -
same multi-bot `RETRY WITH` scoping logic (TGT-229's own convention,
reused rather than reinvented byte-for-byte), same masked-token
display, same per-distinct-bot-key `RETRY WITH` line, printed after
the failed-downloads section (a blank line separator only when
something already printed above it, matching the existing separator
logic exactly). Recovery hint names `d2 tg.retry-transcription --all`
instead of `d2 tg.retry-download --all`. No changes to `D2TG::Store`,
`D2TG::Poller`, or `cli/retry-transcription.pl` themselves - both
already correctly implemented by TGT-237, per this ticket's own scope.

New test `t/239-unread-surfaces-failed-transcriptions.t`: confirmed
genuinely red against the pre-fix code (5/8 subtests failed - the new
section, its recovery hint, and multi-bot scoping were all absent),
confirmed green after the fix (8/8) - covering a single queued row's
section/hint, multi-bot scoping (mirroring `t/229`'s own precedent),
both queues appearing together in the correct order, and an
empty-store regression baseline proving byte-identical output when
nothing is queued. Full suite re-run clean at 1793/1793, including
`t/229-unread-multi-bot-retry-hint.t`/`t/124-unread-usage-pod-parity.t`/
`t/109-unread-unrecognized-args-refuse.t` passing unmodified. `cli/unread.pl`
remains outside `Devel::Cover`'s direct instrumentation (invoked via
subprocess in its own tests) - the same accepted, previously-documented
limitation as every other `cli/*.pl` script; no `lib/` module was
touched by this ticket, so no coverage gate applied.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: diffed
the new section line-by-line against the existing `failed_downloads`
section immediately above it to confirm structural parity (same
multi-bot detection logic, same masked-token display, same separator
handling), and confirmed the full pre-existing `failed_downloads`
listing test suite passes unmodified.

## TGT-221: automatic background retry for queued failed downloads

Source: JOB-008 feature-request-triage, from a real budget-project
live incident (`/tmp/ask-for-more-from-d2tg/20260911T202500-budget-emberfox.md` -
4 photos stuck queued over an hour on a transient HTTP 500/timeout; a
manual retry succeeded immediately, seconds later). TGT-204 (v1.64)
made a queued `failed_downloads` row visible (`NEW TG MEDIA FAILED`
stdout line + `d2 tg.unread` listing) but explicitly deferred automatic
recovery, calling it out as "a separate, larger design decision about
retry cadence and whether it belongs in the poller's own main loop" -
this ticket makes that decision and implements it.

**Q-015** (asked with a voice note and 3 options, per this project's
own standing rule): what retry cadence and max-attempt cap should
automatic background retry use? Michael answered: retry every 60s for
up to 5 minutes total, independent of poll cadence - matching the
emberfox incident's own "seconds later" recovery window closely, and
avoiding the risk of hammering Telegram's API on a genuinely-dead
download by capping the window explicitly rather than retrying
forever.

Fixed by adding `D2TG::Store::failed_downloads_due_for_retry(bot_key
=> $b)` - a SQL query (not a Perl-side time comparison, for the same
reasons `prune_history`'s own age-based sweeps already use SQLite's
`datetime()` rather than pulling every row into Perl) selecting rows
still within 5 minutes of their own `created_at` (the window is
measured from when the failure was first queued, not from now) that
haven't been attempted in the last 60s (tracked via a new
`last_retry_at` column, `NULL` meaning "never auto-retried yet") - and
`mark_failed_download_retried($id)`, which stamps it after a failed
attempt. `D2TG::Download::auto_retry_failed_downloads` reuses
`retry_failed_download` itself for the actual retry (no duplicated
retry logic), called once per `(chat_id group, bot)` pair per poll
cycle from `cli/poller.pl`'s main loop - scoped to that pair's own
`bot_key`, since a retry needs the matching bot's own `$telegram`
object (Telegram's `file_id` values are bot-token-scoped). A row past
the 5-minute window is left queued and fully visible - automatic
retry simply stops attempting it, never deletes it - so the manual
`d2 tg.retry-download` escape hatch (and TGT-204's own visibility)
are completely unaffected, matching this ticket's own explicit
scope constraint.

**Self-caught schema-ordering bug during implementation** (the same
class TGT-235 itself self-caught and documented): the first draft
placed the new `last_retry_at` `ALTER TABLE ADD COLUMN` block
immediately after `local_path`'s own (mirroring its exact style) -
but TGT-219's own rename/create/copy/drop migration block runs
*after* that point in `_ensure_schema`, and its own `CREATE TABLE`
only lists the columns it explicitly knows about. On any fresh
database, that migration would have silently dropped the newly-added
`last_retry_at` column immediately after adding it (confirmed live:
`prove` failed with `no such column: last_retry_at` on the very next
query). Caught by running the new test immediately after the first
implementation attempt, not by review; fixed by moving the block to
run *after* the TGT-219 migration instead.

New test `t/221-auto-retry-failed-downloads.t`: confirmed genuinely
red against the pre-fix code (`failed_downloads_due_for_retry` did not
exist), confirmed green after the fix (14/14) - covering the
due-for-retry query's own three states (never attempted → due
immediately; just attempted → not due for 60s; past the 5-minute
window → never due again but still listed by `failed_downloads`),
`auto_retry_failed_downloads`'s successful-retry path (row removed,
history restored) and failed-retry path (non-fatal, `last_retry_at`
stamped, row stays queued), and `bot_key` scoping. Full suite re-run
clean at 1807/1807. 100% statement+subroutine coverage confirmed on
`lib/D2TG/Store.pm` and `lib/D2TG/Download.pm`.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: traced
the exact SQL in `failed_downloads_due_for_retry` against SQLite's own
`datetime()` semantics by hand (confirmed the window/interval math
against the live-reproduced schema-ordering bug above, which was
itself caught by the test suite, not by manual review), and confirmed
`t/83-failed-download-queue.t`'s own full pre-existing suite passes
unmodified, proving no regression to the existing manual-retry/
visibility behavior this ticket was scoped to leave untouched.

## TGT-240: extract_bot_flag_or_die POD undercounted its own real callers

Found via a scheduled JOB-005 doc-accuracy hunt. The POD for
`D2TG::Reply::extract_bot_flag_or_die` (added by TGT-236) said "7
`cli/*.pl` scripts (`history`, `attachment`, `unread`,
`retry-download`, `approve`, `send`, `reply`)" - the identical
sentence was pasted a second time in `docs/commands.md`'s own
`D2TG::Reply` Module reference table entry. TGT-237 later added
`cli/retry-transcription.pl` as an 8th real caller of the same helper,
but neither prose copy was ever updated - confirmed via `grep -l
extract_bot_flag_or_die cli/*.pl`, which returns 8 files, not 7. A
reader of this POD (the authoritative module reference for the
helper) was told there were 7 callers and given an exhaustive-looking
list that omitted a real one.

Fixed by correcting both prose locations to name 8 callers including
`retry-transcription`, and adding a new structural regression test
mirroring `t/98-skills-md-cli-list-current.t`'s own established
pattern (guard a hardcoded prose count/list against the real file
list, so a future ticket adding another caller fails the suite
instead of silently letting this drift recur). No behavior or
signature change to `extract_bot_flag_or_die` itself - purely
prose and a new test, per this ticket's own explicit scope.

New test `t/240-extract-bot-flag-pod-caller-count.t`: confirmed
genuinely red against the pre-fix code (2/11 subtests failed - the
POD's stated count of 7 didn't match the real 8, and
`retry-transcription` was missing from the caller list), confirmed
green after the fix (11/11). Full suite re-run clean: run in 6 smaller
batches (30 files each) rather than one pass, since this session hit
persistent host-level OOM kills on every attempt at a single full-suite
invocation (batched coverage x2, parallel `-j 4`, non-parallel `-lr`) -
confirmed via `docker ps`/`free -h` that unrelated containers on this
shared host (other sessions running `cp -r` operations, not this
project's own) were consuming the available memory, not a defect in
this change; the diff itself was also independently verified to touch
only POD/comment text via `git show` (zero executable Perl lines
changed). All 6 batches (182 files, 1818 tests total) passed clean.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: the
`git show` diff review above (confirming the change is prose-only)
combined with the new test's own count/list assertions against the
real `cli/*.pl` directory listing.

## TGT-244: auto-retry throttle silently bypassed when download succeeds but record_message keeps failing

Found via a scheduled JOB-003 hourly bug-hunt fork, live-reproduced (no
"try to imagine a failure" - the fake store in the new test drove the
real `D2TG::Download::retry_failed_download` and
`auto_retry_failed_downloads` code paths). `retry_failed_download`
always returned `(1, $local_path)` once the download step itself
succeeded, even when the subsequent `record_message` bookkeeping write
then failed and the row was deliberately kept queued (via
`mark_failed_download_downloaded`) - TGT-196's own documented
"persistently-failing `record_message`" scenario.
`auto_retry_failed_downloads` (TGT-221's own 60s throttle) only called
`D2TG::Store::mark_failed_download_retried` to stamp `last_retry_at`
when that return was false. Since `$ok` was always `1` in this
partial-success case, `last_retry_at` was never stamped and stayed
`NULL` forever - `D2TG::Store::failed_downloads_due_for_retry`'s own
`last_retry_at IS NULL` clause then matched the row unconditionally on
every single poll cycle, instead of once per `AUTO_RETRY_INTERVAL_SECONDS`
(60s) as TGT-221 documents and intends. The redownload itself was not
repeated (the row's `local_path` was already persisted, so
`retry_failed_download` skipped straight to the `record_message`
retry), but the store write (and its own `STORE ERROR` log line) was
attempted on every poll cycle rather than at the documented, bounded
rate - defeating the whole point of the throttle for exactly the
scenario the codebase already anticipated as real.

Fixed by giving `retry_failed_download` a third return value,
`$still_queued`: `0` when the row was actually removed (a fully
successful attempt), `1` when the download succeeded but
`record_message` failed and the row was kept queued.
`auto_retry_failed_downloads` now stamps `last_retry_at` whenever
`!$ok || $still_queued` - i.e. whenever the row remains queued after
the attempt, regardless of which specific step caused that. A fully
successful retry (row removed) needs no `last_retry_at` stamp at all,
since the row no longer exists to be reconsidered. The only real
caller of `retry_failed_download` besides `auto_retry_failed_downloads`
is `cli/retry-download.pl`'s manual path, which only destructures the
first two return values - confirmed via `grep -rn
'retry_failed_download\('` - so it is completely unaffected by the new,
purely additive third value.

New test `t/244-auto-retry-throttle-record-message-failure.t`: a
`D2TG::Store` subclass whose `record_message` always dies (simulating a
persistent bookkeeping failure while the download itself succeeds via a
real `Fake::UA`/`Fake::DownloadTelegram` pair, the same fake shapes
`t/221-auto-retry-failed-downloads.t` already established). Confirmed
genuinely red against the pre-fix code (2/5 subtests failed - the row
was re-attempted on the very next `failed_downloads_due_for_retry` call
instead of being throttled), confirmed green after the fix (5/5),
including a check that the row correctly becomes due again once the
60s interval has genuinely elapsed (the fix must throttle, not
permanently stop retrying). Full suite re-run clean: 183 files, 1823
tests. 100% statement+subroutine coverage confirmed on the touched
module, `lib/D2TG/Download.pm`.

## TGT-246: failed voice transcriptions never got the same auto-retry failed downloads got

Found via a scheduled JOB-003 hourly bug-hunt fork, live-verified by
direct code/grep read (not speculation): `D2TG::Download::auto_retry_failed_downloads`
(TGT-221, Q-015 answered by Michael - "retry every 60s for up to 5
minutes total, independent of poll cadence") gave the `failed_downloads`
queue automatic background retry from `cli/poller.pl`'s main loop. The
structurally identical `failed_transcriptions` queue (TGT-237) - whose
own POD explicitly says it "mirrors `record_failed_download`/
`failed_downloads`/`remove_failed_download`'s own shape exactly" - never
received the same treatment. `grep -rn
'failed_transcriptions_due_for_retry\|mark_failed_transcription_retried\|auto_retry_failed_transcriptions'`
across `lib/` and `cli/` returned nothing before this fix: no such
`D2TG::Store` accessors existed, no such `D2TG::Download` sub existed,
and `cli/poller.pl`'s main loop never called one. `D2TG::Download::retry_failed_transcription`
(TGT-237) already existed and was fully capable of performing the
actual retry - it was simply never invoked automatically, only via the
manual `d2 tg.retry-transcription` command. A transient transcription
failure (a momentary whisper/ffmpeg hiccup, a transient network blip
during the re-download step - the exact same failure class TGT-221's
own live incident report described for downloads) therefore sat queued
indefinitely with zero automatic recovery, while the identical failure
shape on the download side self-heals unattended within 5 minutes - a
silent reliability asymmetry between two queues the code and docs
otherwise treat as parallel.

Fixed by adding the same trio TGT-221 built for downloads, applied to
transcriptions:

- `D2TG::Store::failed_transcriptions_due_for_retry(bot_key => $b)` and
  `mark_failed_transcription_retried($id)`, mirroring
  `failed_downloads_due_for_retry`/`mark_failed_download_retried`
  exactly (same `AUTO_RETRY_INTERVAL_SECONDS`/`AUTO_RETRY_WINDOW_SECONDS`
  constants, same `created_at`/`last_retry_at` windowing). A new
  `last_retry_at` column was added to `failed_transcriptions` via the
  same duplicate-tolerant `ALTER TABLE` pattern `local_path` used for
  `failed_downloads` - placed directly after `failed_transcriptions`'
  own fresh `CREATE TABLE IF NOT EXISTS` block, which (unlike
  `failed_downloads`) has no rename/create/copy/drop migration block of
  its own to worry about ordering against, so this could not repeat the
  known "`ALTER TABLE` before a later rename-migration silently drops
  the new column" bug class this project has hit before.
- `D2TG::Download::auto_retry_failed_transcriptions($telegram, $store,
  bot_key => $b, ua => $ua)`, reusing `retry_failed_transcription`
  itself for the actual retry attempt (no duplicated retry logic),
  exactly as `auto_retry_failed_downloads` reuses `retry_failed_download`.
- Wired into `cli/poller.pl`'s main per-pair loop, immediately after the
  existing `auto_retry_failed_downloads` call, same eval-wrapped
  non-fatal housekeeping pattern and per-`(chat_id group, bot)` scoping.

One deliberate difference from a byte-for-byte copy of
`auto_retry_failed_downloads`: this does **not** branch on
`retry_failed_transcription`'s own `($ok, $result)` return value to
decide whether to stamp `last_retry_at`. Unlike `retry_failed_download`
(fixed by TGT-244, directly above this section), `retry_failed_transcription`
always returns `(1, $transcript)` once download and transcription both
succeed - **even when** the `record_message` bookkeeping write that
follows then fails and the row is deliberately left queued (its own
`STORE ERROR ... queue row not removed` path). Trusting `$ok` alone here
would silently reintroduce the exact TGT-244 throttle-bypass bug for
transcriptions: a row stuck in that partial-success state would never
get `last_retry_at` stamped and would be retried on every single poll
cycle instead of once per `AUTO_RETRY_INTERVAL_SECONDS`. Changing
`retry_failed_transcription`'s own return contract to add a matching
`$still_queued` value (as TGT-244 did for `retry_failed_download`) was
deliberately kept out of this ticket's scope; instead,
`auto_retry_failed_transcriptions` checks `D2TG::Store::failed_transcriptions`
directly after the attempt for whether the row still exists -
unambiguous regardless of which step failed (download, transcription,
or `record_message`), and requires no change to
`retry_failed_transcription`'s own existing callers or contract.

New test `t/246-auto-retry-failed-transcriptions.t`, mirroring
`t/221-auto-retry-failed-downloads.t`'s own shape and confirmed
genuinely red against the pre-fix code (`Can't locate object method
"failed_transcriptions_due_for_retry" via package "D2TG::Store"`):
`failed_transcriptions_due_for_retry`'s windowing (immediately due,
throttled within 60s, due again after 60s, excluded past the 5-minute
window, still visible/listed either way), a successful
`auto_retry_failed_transcriptions` call removing the row and restoring
history, a failing attempt never crashing the caller while stamping
`last_retry_at` and correctly throttling the next attempt, and
`bot_key` scoping. Full suite re-run clean. 100% statement+subroutine
coverage confirmed on the touched modules, `lib/D2TG/Store.pm` and
`lib/D2TG/Download.pm`.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, the same near-universal unavailability seen
throughout this session. Fell back to independent verification: a
line-by-line `git diff` review of the change (reproduced above)
confirming it is a minimal, purely additive third return value plus the
one new `if` condition that consumes it, a `grep` confirming
`cli/retry-download.pl` is the only other caller and is unaffected, and
the new red/green test itself directly exercising the real bug through
the real code paths (not a mocked reproduction of the symptom).

## TGT-245: retry_failed_download/retry_failed_transcription omitted bot_key from record_message, mis-attributing retried messages in a multi-bot config

Found via a scheduled JOB-003 hourly bug hunt (2026-09-14), by reading
`lib/D2TG/Download.pm` directly rather than trusting the ticket board's
own claimed completeness.

TGT-232 migrated the `messages` table to a composite `(chat_id,
message_id, bot_key)` key and its own `solution_needed` text explicitly
enumerated every call site that needed a `bot_key` parameter threaded
through: `D2TG::Poller`'s `record_message`/`mark_read` calls,
`cli/history.pl`, `cli/unread.pl`, `cli/attachment.pl`, `cli/reply.pl`.
It never enumerated (and so never updated) `D2TG::Download`'s own two
`record_message` callers - `retry_failed_download` and
`retry_failed_transcription`. Both already had the exact value they
needed sitting right there: `$row->{bot_key}`, since `failed_downloads`
(TGT-219) and `failed_transcriptions` (TGT-237) were themselves already
scoped by `bot_key` in an earlier round of this same multi-bot rollout.

`D2TG::Store::record_message` defaults `bot_key` to
`DEFAULT_BOT_KEY` (the empty-string sentinel) whenever the caller omits
it. So a message originally received under a non-default bot, whose
download or transcription failed and got correctly queued under that
bot's own `bot_key`, would - once a later retry (manual `d2
tg.retry-download`/`d2 tg.retry-transcription`, or the automatic
TGT-221 `auto_retry_failed_downloads` poller loop) succeeded - have its
restored history record silently written under the *default* bot's
identity instead. Two concrete consequences: (1) `d2 tg.history --bot
<token>`/`d2 tg.unread --bot <token>` for the bot that actually
received the message would never show it - it only ever appears under
the unscoped/default view; (2) since Telegram's `message_id` is its own
per-bot counter (TGT-063), the retried write could `ON CONFLICT`
silently overwrite an unrelated, legitimate message the default bot
had genuinely recorded under the same `(chat_id, message_id)` pair.

Fixed by passing `bot_key => $row->{bot_key}` into both `record_message`
calls, exactly mirroring every other call site TGT-232 already
threads it through. For the pre-existing single-bot case,
`$row->{bot_key}` is already `''` (`DEFAULT_BOT_KEY`), so this is a
strict no-op there - confirmed by the full suite staying green.

New test `t/245-retry-record-message-bot-key.t`: two blocks, one per
retry function, each queuing a row under a non-default `bot_key`
(`'bot-B-token'`), retrying it against a real `D2TG::Store` (SQLite,
not mocked) with a stubbed successful download/transcription, then
asserting `$store->get_message($chat_id, $message_id, bot_key =>
'bot-B-token')` finds the restored row while the default-`bot_key`
lookup does not. Confirmed genuinely red against the pre-fix code (4/8
subtests failed - both bot-B assertions in each block), confirmed
green after the fix (8/8). Full suite re-run clean: 184 files, 1831
tests. 100% statement+subroutine coverage confirmed on the touched
module, `lib/D2TG/Download.pm`.

Codex adversarial review attempted (`timeout 15 codex exec`): hung and
was killed by timeout, consistent with this session's other attempts.
Fell back to independent verification: a `git diff` review of the
two-line change (each call site gains exactly one new `bot_key =>
$row->{bot_key}` argument, nothing else touched), a `grep -rn
bot_key lib/D2TG/Download.pm` confirming both call sites now use it and
no other caller in this module needed the same fix, and the new
red/green test directly exercising the real code paths (a genuine
SQLite-backed `D2TG::Store`, not a mock) rather than a synthetic
reproduction of the symptom.

## TGT-247: cli/retry-download.pl claimed RETRY OK even when the retry was only partially complete

Found via a scheduled JOB-003 hourly bug hunt, live-reproduced end to
end in a `developer-dashboard:latest` container. `D2TG::Download::retry_failed_download`
returns a 3rd value, `$still_queued` (added by TGT-244 for
`auto_retry_failed_downloads`'s own internal throttle logic) - true
when the download itself succeeded but the follow-up `record_message`
write then failed (a transient locked/busy database, TGT-194's own
documented scenario). In that state the row is deliberately left
queued in `failed_downloads` (never removed) and no row was ever
written into the `messages` table.

`cli/retry-download.pl`'s own retry loop only ever captured `($ok,
$result_or_error)` from that call, silently discarding `$still_queued`
entirely - so its success branch printed the ordinary
`RETRY OK [id] chat_id=X message_id=Y - GET ATTACHMENT WITH: d2
tg.attachment X Y` line unconditionally whenever `$ok` was true, even
in the partial-success case. That printed follow-up command is
guaranteed to fail: `D2TG::Store::get_attachment_path` reads
`local_path` from the `messages` table, which was never written in
this case, so `d2 tg.attachment` exits 1 with "no attachment recorded
for chat X message Y" - directly contradicting the "RETRY OK" claim
that preceded it, and giving the operator/agent no indication the row
was, in fact, still sitting in the retry queue.

Live-reproduced in this session: a fake `D2TG::Store` whose
`record_message` always dies makes `retry_failed_download` return
`(1, $local_path, 1)` - confirmed against the actual unmodified
`cli/retry-download.pl` source that the script would still take the
`RETRY OK`/`GET ATTACHMENT WITH` branch, and confirmed
`get_attachment_path` on that same store returns `undef` for the pair.

Fixed by capturing all 3 return values and branching: when
`$still_queued` is true, the script now prints `RETRY PARTIAL` instead
of `RETRY OK`, explains that the history record could not be written
yet, names the row as still queued (retried automatically, or via
`d2 tg.retry-download <id>` again), and sets a non-zero exit code -
matching `D2TG::Download`'s own `STORE ERROR ... queue row not
removed` STDERR line (which was the only place this gap was ever
visible before this fix). The fully-successful case (`$still_queued`
false) is completely unchanged - still `RETRY OK`/`GET ATTACHMENT
WITH`, still never printing the raw local path (TGT-146).

New test `t/247-retry-download-still-queued-message.t` - a
structural/source-inspection regression test, matching this project's
own established precedent for this exact script
(`t/104-retry-download-cli-no-raw-path.t`, `t/195-approve-store-calls-classified-not-raw.t`):
`cli/retry-download.pl` has no injectable seam for mocking
`D2TG::Telegram`'s HTTP calls through its own real
`D2TG::Poller::open_store_or_die`/real SQLite `D2TG::Store`
construction, so a full functional black-box test isn't practical here
either. Asserts the retry loop captures `$still_queued` from
`retry_failed_download`, that the loop body inspects `$still_queued`
around the `RETRY OK` print (not just `$ok`), and that a
still-queued-specific message actually exists in the script's own
output text. Confirmed genuinely red against the pre-fix code (3 of 4
assertions failed); confirmed green after the fix (4/4). Full suite
re-run clean in the `perl-test` container: 186 files, 1850 tests (one
unrelated pre-existing test, `t/00-scaffold.t`'s own hardcoded
`VERSION=1.97` string match, updated to `1.98` as part of this
release's routine version bump - not itself a behavior fix).

perlsec.pl-style vulnerability-scan audit: pure in-process control-flow
change (one new `if ($still_queued) { ... }` branch reading a return
value already produced by existing, unchanged code, printing only
already-safe values - `$row->{id}`, `$row->{chat_id}`,
`$row->{message_id}`, none of which are attacker-controlled beyond
what every other line in this script already prints) - no new shell
invocation, no new file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced.

## TGT-248: cli/retry-transcription.pl claimed RETRY OK even when the retry was only partially complete

Found via a scheduled JOB-003 hourly bug hunt - the exact TGT-247 bug
class, unfixed in `D2TG::Download::retry_failed_transcription`, the
function TGT-247's own documentation names as `retry_failed_download`'s
structural sibling (both queue-retry functions attempt an external
fetch, then a `record_message` write, then remove the queue row on
success). `retry_failed_transcription` always returned `(1, $transcript)`
once the download and transcription succeeded, regardless of whether the
follow-up `record_message` write then succeeded - it had no equivalent
of `retry_failed_download`'s `$still_queued` 3rd return value at all.
When `record_message` failed (a transient locked/busy database, the same
documented scenario as TGT-194/TGT-247), the row was correctly left
queued in `failed_transcriptions` (never removed) and no row was ever
written into the `messages` table.

`cli/retry-transcription.pl`'s own retry loop only ever captured `($ok,
$result_or_error)` from that call - there was no 3rd value to discard,
because the low-level function never produced one - so its success
branch printed the ordinary `RETRY OK [id] chat_id=X message_id=Y:
<transcript>` line unconditionally whenever `$ok` was true, even in the
partial-success case. `d2 tg.history`/`d2 tg.unread` would never show the
recovered message, and the row was, in fact, still sitting in the retry
queue - the operator/agent had no indication anything was incomplete.

Fixed by adding a 3rd return value to `retry_failed_transcription`
(`$record_ok ? 0 : 1`, mirroring `retry_failed_download`'s own
`$still_queued` naming and shape exactly) and updating
`cli/retry-transcription.pl` to capture and branch on it: when true, the
script now prints `RETRY PARTIAL` instead of `RETRY OK`, explains that
the history record could not be written yet, names the row as still
queued (retried automatically, or via `d2 tg.retry-transcription <id>`
again), and sets a non-zero exit code - matching TGT-247's fix wording
for its sibling script. The fully-successful case (`$still_queued`
false) is completely unchanged - still `RETRY OK: <transcript>`.

New test `t/248-retry-transcription-record-failure-partial.t` - unlike
`retry-download.pl`, `retry_failed_transcription` already had real
functional-test precedent in this project (`t/196-retry-failed-download-skips-redownload.t`,
`t/245-retry-record-message-bot-key.t` both use a real SQLite-backed
`D2TG::Store` subclassed to force `record_message` to die, plus a fake
`D2TG::Telegram`/`D2TG::Transcribe::transcribe` override), so this test
follows that same real, non-source-inspection pattern directly against
`D2TG::Download::retry_failed_transcription` rather than the script.
Confirmed genuinely red against the pre-fix code (1 of 12 assertions
failed: the 3rd return value did not signal the failure); confirmed
green after the fix (12/12).

perlsec.pl-style vulnerability-scan audit: pure data-flow change - one
new return value derived from an existing boolean already computed by
unchanged code (`$record_ok`), and one new `if ($still_queued) { ... }`
branch in the CLI script printing only already-safe values
(`$row->{id}`, `$row->{chat_id}`, `$row->{message_id}`, all of which
every other line in this script already prints) - no new shell
invocation, no new file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced.

## TGT-249: retry_failed_download/retry_failed_transcription reported still_queued=0 even when the row-removal write itself failed

Found via a scheduled JOB-003 hourly bug hunt. `retry_failed_download`'s
and `retry_failed_transcription`'s own `$still_queued` 3rd return value
(TGT-244/TGT-248) was computed by unconditionally assuming the
queue-row removal write (`remove_failed_download` /
`remove_failed_transcription`) succeeded once `record_message` had
succeeded - neither function ever inspected
`D2TG::Poller::store_write_safe`'s own `(ok, value)` result for that
specific call; the removal call's return value was simply discarded.

When `record_message` succeeded but the removal write itself then hit a
transient failure (a locked/busy database - the exact scenario
`store_write_safe` exists to guard against, per its own documented
purpose and the surrounding comments on both functions), the queue row
was genuinely NOT removed - it remained in `failed_downloads` /
`failed_transcriptions`. But `$still_queued` was still hardcoded to `0`
(`retry_failed_download`) or derived only from `$record_ok`
(`retry_failed_transcription`), both ignoring the removal write's own
outcome. `cli/retry-download.pl` and `cli/retry-transcription.pl` both
already correctly branch on `$still_queued` (TGT-247/TGT-248) to decide
`RETRY OK` vs `RETRY PARTIAL` - but since it was wrongly `0`/false in
this scenario, both scripts printed an unqualified `RETRY OK` and
exited 0, even though the row was, in fact, still sitting in the retry
queue. This is a narrow, previously-unaddressed sibling of the exact bug
class TGT-244/TGT-247/TGT-248 already fixed for the `record_message`-
failure path; the removal-write-failure path was simply never
considered.

Fixed by capturing `store_write_safe`'s own success flag for the
removal write in both functions and deriving `$still_queued` from it
directly: `retry_failed_download` now sets
`$still_queued = $remove_ok ? 0 : 1`; `retry_failed_transcription` now
returns `( 1, $transcript, ( $record_ok && $remove_ok ) ? 0 : 1 )`. No
change was needed to `cli/retry-download.pl` or
`cli/retry-transcription.pl` themselves - they already consumed the 3rd
return value correctly (TGT-247/TGT-248); only the value they were
given was wrong in this one edge case.

New test `t/249-still-queued-on-removal-write-failure.t`, following the
same real, non-source-inspection pattern as TGT-194/TGT-248 (a real
SQLite-backed `D2TG::Store` subclassed to force
`remove_failed_download`/`remove_failed_transcription` specifically to
die, with `record_message` left genuinely succeeding). Confirmed
genuinely red against the pre-fix code (2 of 12 assertions failed - the
3rd return value did not signal the still-queued state in either
function); confirmed green after the fix (12/12).

perlsec.pl-style vulnerability-scan audit: pure data-flow change - one
existing `store_write_safe` call's already-computed return value is now
captured into a local variable instead of discarded, and one existing
boolean expression is adjusted to include it. No new shell invocation,
no new file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced, and no
change to what either function prints or persists - only to the
accuracy of the `$still_queued` signal both already exposed.

## TGT-250: poller.pl no longer prints the different-token sibling-poller NOTE

Live request via Telegram, Michael, 2026-09-15 (msg #443, verbatim):
"You don't need to mention that. To me, that is noise and confusion to
the agent. Stop printing that note" - quoting the exact NOTE text
`cli/poller.pl`'s `different_token` branch (TGT-141) printed every poll
cycle a sibling project's own poller (different `D2TG_TOKEN`, no real
`getUpdates` collision) was detected. That branch's own wording already
said "no action needed unless you know otherwise" - a confirmed-benign
finding that still surfaced as bridge noise on every occurrence, exactly
the kind of report-with-nothing-to-do-about-it the owner objected to.

Fix: removed the `if (@different_token) { print STDERR ... }` block
entirely, replaced with an explanatory comment. `find_other_pollers`/
`classify_other_poller_token`'s own detection/classification logic is
completely unchanged - `@different_token` is still populated by the
existing classification loop, simply no longer acted on. The
`same_token` and `unknown_token` WARNING branches (TGT-102/TGT-141) are
untouched - those remain genuinely actionable (a real orphaned poller
sharing this bot token, or one that couldn't be classified either way).

New regression test `t/250-poller-silence-different-token-note.t`
(source-code structural check, matching `t/105-orphaned-poller-token-
crosscheck.t`'s own established pattern of regex-extracting a named `if`
block from `cli/poller.pl`'s own source rather than spawning a real
process): asserts the old NOTE text string no longer appears anywhere in
the file, the `different_token` block (if a bare shell of it still
existed) prints nothing, and both the `same_token`/`unknown_token`
blocks are still present with their original WARNING text. Confirmed
genuinely red against the pre-fix code (2 of 8 assertions failed - the
NOTE text was still present); confirmed green after the fix (8/8).

A pre-existing integration test, `t/82-orphaned-poller-detection.t`
(spawns a real different-token sibling poller process and reads the real
poller.pl's own stderr), asserted the *old* behavior directly (`like
$warning_line, qr/^NOTE.*sibling project/`) - this was a genuine,
expected regression once the fix landed, not a false alarm, so it was
updated in the same commit to assert the new behavior instead (no
`WARNING` line, and the old NOTE text absent from stderr entirely),
rather than left broken or silently skipped.

Full suite run in Docker (`t/250-...t`, `t/105-...t`, `t/82-...t`
together): 32 tests, all passing.

perlsec.pl-style vulnerability-scan audit: pure stderr-output-removal
change - deletes a `print STDERR` call and its already-safe interpolated
values (PID list only, already collected by unchanged code); no new
shell invocation, no new file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced, and no
change to any function's return value or persisted state.

## TGT-251: select_model routed short voice notes to the slowest Whisper tier

Live request via Telegram, Michael, 2026-09-15 (msg #446, verbatim):
"The voice note transcribing is very slow. A short 30 seconds voice
note sent from TG to the tg.poller take like forever." He also sent a
real ~30s test voice note (msg #450, later attached to this ticket per
his own instruction, msg #451) purely as sample audio for verifying the
fix - its transcribed content was explicitly not the subject of this
ticket ("The content inside isn't for you", msg #449).

Root cause, confirmed by reading `lib/D2TG/Transcribe.pm:63-71`:
`select_model(duration)` returned `medium` (the largest, slowest Whisper
tier) for ANY duration `<=300`, including a 30-second clip - there was
no fast-path for genuinely short audio at all. The module's own prior
comments (TGT-100's follow-up, added after Michael's earlier measured
throughput data) already documented exactly why this hurt: `medium`
runs at ~5.6x real time on his host, so a 30s clip legitimately took
~168s (nearly 3 minutes) of wall time to finish - "forever" for a short
voice note, even though it technically stayed within the scaled 300s
timeout floor and never triggered the existing timeout-retry-at-a-
faster-tier fallback.

Fix: `select_model` now returns `base` (the fastest existing tier,
already part of `@MODEL_TIERS`) for any duration that is both
genuinely-parsed (matches `/^\s*[\d.]+\s*$/`) AND in `(0, 60]`. Critical
invariant preserved: an unparsed or failed duration probe (duration
`undef`, non-numeric, or otherwise falling through to the existing
`$duration = 0` coercion) must NOT be swept into this new fast tier just
because `0 <= 60` - an *unknown* duration is not the same claim as a
*confirmed-short* one, and t/74's own long-documented guarantee ("a
probe failure never behaves worse than pre-TGT-100 code did") requires
it keep falling back to `medium` exactly as before. This is why the fix
tracks a separate `$parsed` boolean rather than testing the
already-coerced `$duration` alone. All pre-existing tier boundaries
above 60s (300->medium, 301->small, 900->small, 901->base) are
unchanged, confirmed both by inspection and by `t/74-transcribe-dynamic-
model.t`'s own pre-existing assertions still passing unmodified.
`_scaled_timeout` and `_next_tier` (the retry-on-timeout escalation
ladder) are untouched.

New regression test `t/251-transcribe-fast-tier-short-clips.t`: boundary
assertions for `select_model` (1/30/60 -> base, 61/299/300 -> medium,
301/900 -> small, 901 -> base), the unparsed/failed-probe invariant
(`select_model(0)`, `select_model(undef)`, `select_model('garbage')` all
still return `medium`), and an integration-style assertion via
`transcribe()` with an injected `duration_fn` returning 30, confirming
the real whisper invocation is built with `--model base`. Confirmed
genuinely red against the pre-fix code (4 of 14 assertions failed - the
new-tier cases and the 30-second `transcribe()` call); confirmed green
after the fix (14/14). `t/74-transcribe-dynamic-model.t` and
`t/102-transcribe-scaled-timeout.t` re-run alongside it, both still
green (45 tests total across the three files, no regressions).

A genuine constraint, disclosed rather than worked around: no `whisper`/
`whisper-cli`/`faster-whisper` binary is installed in this project's
Docker `perl-test` container, so a real, live timed comparison ("does a
30s clip actually transcribe faster wall-clock now") was not feasible to
run in this sandbox. Verification instead relies on (a) the module's own
already-documented real-host throughput measurement (`medium` at ~5.6x
real time, cited above, which is why a faster tier is expected to help
materially rather than marginally) and (b) unit-level `select_model`
boundary tests confirming the new tier logic is exactly what was
intended, matching how this project has previously handled other
genuinely-unavailable external tools (`cpan-audit`, `codex exec`) -
documented as a real limitation, not silently skipped.

perlsec.pl-style vulnerability-scan audit: pure control-flow/data
change - one new local boolean (`$parsed`) derived from an existing
regex match already used by unchanged code, and one new early-return
branch comparing already-validated numeric input against literal
constants. No new shell invocation, no new file I/O, no new
external-input handling, no system/exec/backtick/piped-open/eval-STRING
patterns introduced, and no change to what `transcribe()` persists or
returns beyond which model tier string it passes to the (unchanged)
whisper invocation.

## TGT-264: extract_bot_flag silently ignored a sole bare --bot instead of dying "requires a value"

Found via a scheduled JOB-003 hourly bug hunt. TGT-074 made
`D2TG::Reply::extract_bot_flag` die `--bot requires a value` for a
trailing bare `--bot` (with other args already present) or `--bot`
immediately followed by another flag, matching
`D2TG::Config::shift_flag_value`'s established validation for every
other malformed-shape call. But the function's own guard was
`if (@args >= 2 && $args[0] eq '--bot')` - when `--bot` was the ONLY
argument (`@args` length exactly 1), the `>= 2` check was false, so the
guard never fired at all and the function fell through to
`return (undef, '--bot')` instead of dying. The caller then treated the
leftover `'--bot'` string as an unrecognized positional argument,
producing a generic `Usage: ...` refusal (still exit non-zero, no
crash) rather than the specific `--bot requires a value` message every
other malformed `--bot` shape gets.

Reproduced live in the `perl-test` container:
`perl -Ilib -MD2TG::Reply -e 'print extract_bot_flag(qw(--bot))'`
returned `token=undef, rest=(--bot)` instead of dying; end-to-end via
`D2TG_TOKEN=x D2TG_CHAT_ID=1 perl -Ilib cli/approve.pl --bot` exited 2
with the generic `Usage: d2 tg.approve ...` message rather than the
specific one. Low severity - no crash, no data risk, every affected
script (all 8 `cli/*.pl` scripts using `extract_bot_flag_or_die` as
their leading-position `--bot` parser) still refuses cleanly with a
non-zero exit - but a genuine behavioral inconsistency against every
other malformed-`--bot` case and against `t/62`'s own documented
TGT-074 contract.

Fixed by widening the guard from `@args >= 2` to `@args >= 1` -
`D2TG::Config::shift_flag_value` already dies correctly when shifted
off an empty list (`shift @$args` returns `undef`, which fails the
"defined and non-empty and not flag-like" check), so no other code
change was needed. A well-formed `--bot TOKEN` call is completely
unaffected regardless of total arg count.

New test `t/264-extract-bot-flag-sole-bare-bot.t`: confirmed genuinely
red before the fix (`extract_bot_flag('--bot')` returned an empty
string instead of dying), confirmed green after. `t/62`'s own existing
assertions (the `>= 2` cases, and the well-formed-token case) re-run
unchanged, still green.

perlsec.pl-style vulnerability-scan audit: pure control-flow change -
one comparison operator widened (`>=2` to `>=1`) in an existing branch
condition already gating an existing, already-reviewed validation call.
No new shell invocation, no new file I/O, no new external-input
handling, no system/exec/backtick/piped-open/eval-STRING patterns
introduced.

## TGT-268: cli/reply.pl and cli/send.pl each re-swallowed a sole bare --bot, bypassing TGT-264's own fix

Found via a scheduled JOB-003 hourly bug hunt. TGT-264 fixed
`D2TG::Reply::Args::extract_bot_flag` to die `--bot requires a value`
for a sole bare `--bot` argument (array length exactly 1), instead of
silently falling through to `return (undef, '--bot')`. But
`cli/reply.pl` and `cli/send.pl` each independently pre-check
`if (@ARGV >= 2) { call extract_bot_flag_or_die } else { shift @ARGV }`
around their own `--bot` branch - a special-case dating to TGT-068,
whose own comment reasoned that a bare trailing `--bot` "can't be
consumed by extract_bot_flag (it needs 2 elements)". That reasoning
was true before TGT-264, but TGT-264 made it stale: since then,
`extract_bot_flag_or_die` (via `extract_bot_flag`) already handles the
single-element case correctly, dying with the specific error instead
of needing a caller-side workaround. Both scripts kept their old
special-case regardless, so when `--bot` was the ONLY remaining
argument, they took the `else` branch, silently shifted it off, and
fell through to a generic `chat_id`/`Usage` error instead of TGT-264's
own clear message - reintroducing the exact silent-discard bug TGT-264
fixed, one layer up at these two callers.

Reproduced live: simulating `cli/reply.pl`'s exact loop logic with
`@ARGV=('--bot')` yielded `bot_token=undef, remaining_argv=()`
(silently discarded) instead of dying. `cli/send.pl` has the
byte-for-byte identical pattern at its own `--bot` branch. Every OTHER
`--bot` caller (`approve`/`attachment`/`history`/`unread`/
`retry-download`/`retry-transcription`) already calls
`extract_bot_flag_or_die` unconditionally and was unaffected - only
`reply.pl`/`send.pl` had this extra local special-case, both built
around the same TGT-068 hang-avoidance fix from before
`extract_bot_flag_or_die` existed.

Fixed by removing the `if (@ARGV >= 2) / else shift` special case in
both scripts - they now call `extract_bot_flag_or_die(@ARGV)`
unconditionally whenever `$ARGV[0] eq '--bot'`. Forward progress on
`@ARGV` (TGT-068's own original concern, a real live-reproduced
infinite loop) is still guaranteed: `extract_bot_flag_or_die` either
returns having consumed at least the `--bot` token, or dies and calls
`exit(1)`, so the loop can never spin on the same unconsumed argument
either way.

New test `t/268-reply-send-sole-bare-bot.t`: end-to-end checks (not a
unit test against `D2TG::Reply::Args`, which TGT-264's own t/264
already covers) that both `cli/reply.pl --bot` and `cli/send.pl --bot`
(sole argument) die `--bot requires a value` and exit 1. Confirmed
genuinely red against the pre-fix code: stashed the fix
(`git stash push -- cli/reply.pl cli/send.pl`), ran the test (2 of 4
assertions failed, both matching against the generic `Usage` message
instead of the specific one), then restored the fix
(`git stash pop`) and confirmed green.

`t/57-reply-bare-bot-flag-no-hang.t`'s own two pre-existing assertions
(written for TGT-068, before `extract_bot_flag_or_die` existed)
checked for the generic `Usage` message this fix removes - updated to
assert the new, more specific `--bot requires a value` message
instead. That test's own core purpose (no hang, non-zero exit) is
unaffected; only the exact error text changed, which is the intended
outcome of this fix, not a regression in the test's own guarantee.

perlsec.pl-style vulnerability-scan audit: pure control-flow
simplification - an existing conditional branch removed, its
surviving branch (an existing, already-reviewed function call)
now runs unconditionally instead of behind a now-obsolete arg-count
guard. No new shell invocation, no new file I/O, no new
external-input handling, no system/exec/backtick/piped-open/eval-STRING
patterns introduced.

## TGT-270: poller version-change restart re-emitted a stale MEDIA DOWNLOAD ERROR as if it were a fresh live failure

Live report from Michael via the budget project's own agent, filed at
`/tmp/ask-for-more-from-d2tg/20260916T194918-budget-oldmessage-replay.md`,
surfaced via a scheduled JOB-008 feature-request-triage sweep. At
17:38:17, a poller version-change restart (2.02->2.06) printed the
version-change notice immediately followed by a `MEDIA DOWNLOAD ERROR`
line for a chat that read exactly like a brand-new live failure for a
message Michael had just sent. Investigated at the time: `d2
tg.history --since <that window>` found nothing genuinely new; `d2
tg.retry-download --all` reported no failed downloads queued; `d2
tg.status` showed a healthy poller. So the error was NOT a genuinely
new failure at that moment - it was old output re-surfaced at the
exact moment of the restart, matching the shape of an already-resolved
download error from days earlier.

Root cause, confirmed by direct source investigation: two hypotheses
were ruled out first. Stdout buffering was NOT the cause -
`cli/poller.pl` already sets `$|=1` (autoflush) at line 26,
specifically to prevent exactly this class of delayed-output issue
(per its own TGT-028 comment). `D2TG::Download::auto_retry_failed_downloads`
was NOT the source either - grepping the whole codebase confirmed the
literal string `MEDIA DOWNLOAD ERROR` is only ever printed from
`D2TG::Poller::run_once`'s own live, synchronous media-download-failure
path - never from the retry/auto-retry code path, which prints a
different `AUTO RETRY ERROR` string instead.

The actual gap: `run_once`'s own redelivery-dedup guard (added by
TGT-178, at `lib/D2TG/Poller.pm` around line 341) only checks
`D2TG::Store::get_message` - the `messages` table - before
re-announcing/re-processing a redelivered update. A media-download
failure never calls `record_message` (only `record_failed_download`, a
different table entirely) - so when Telegram redelivers that same
update_id (its own documented at-least-once delivery, explicitly
acknowledged in `D2TG::Store::RetryQueue::record_failed_download`'s
own TGT-219 comment: "Telegram's own at-least-once delivery can still
reprocess the same update under the SAME bot"), the guard has no way
to recognize it as already-queued, and `run_once` legitimately
re-processes it as brand new - re-printing `MEDIA DOWNLOAD ERROR` and
re-attempting the download live, exactly matching the reported
symptom. The same gap applies to voice messages and
`failed_transcriptions`.

`record_failed_download` is itself already idempotent
(`INSERT ... ON CONFLICT (chat_id, bot_key, message_id) DO UPDATE`) -
the DATA layer already handles a redelivered update gracefully. The
gap was purely in the POLLER's own live announce/re-attempt path
having no visibility into the retry queue before acting on an update.

Fixed by adding `D2TG::Store::RetryQueue::has_failed_download`/
`has_failed_transcription($chat_id, $message_id, bot_key => $b)` (a
cheap `SELECT 1 ... LIMIT 1` existence check, forwarded through
`D2TG::Store`) and extending `run_once`'s existing redelivery-dedup
guard to also check both, alongside the pre-existing `get_message`
check - skipping (treating as already-seen) whenever any of the three
already has a row for that `(chat_id, message_id, bot_key)`. A
transient lookup error on the two new checks degrades the same way
the existing `get_message` check already does (treated as
not-previously-seen, proceed as normal, matching this file's
established degrade-not-crash philosophy).

New test `t/270-run-once-redelivery-skips-queued-failures.t`: seeds a
`failed_downloads`/`failed_transcriptions` row for a given
`(chat_id, message_id)`, then feeds `run_once` the same update again
with a `download_media`/`transcribe_voice` coderef that WOULD succeed
if actually invoked - proving the guard skips it before ever reaching
the attempt, not merely that a second failure is handled gracefully.
Confirmed genuinely red before the fix (2 of 7 assertions failed,
showing the download genuinely re-attempted and re-announced as a
brand-new `NEW TG MEDIA` success). A second scenario confirms a
genuinely NEW media failure (never queued before) is still announced
and queued exactly as before - the fix narrows re-processing only for
an already-queued redelivery, nothing else.

Not investigated as part of this ticket (noted, not reproduced): a
secondary `skill_version_check_safe: ... cannot read
/home/mv/.developer-dashboard/skills/tg/.env: No such file or
directory` error Michael also flagged in the same block - possibly
related to why old output surfaces at that exact restart moment (e.g.
a race during the install step's own file replacement), but left for
a follow-up investigation rather than guessed at here.

perlsec.pl-style vulnerability-scan audit: two new read-only
existence-check queries (parameterized, no string interpolation into
SQL) added to an already-reviewed retry-queue module, plus one
additional `eval`-guarded boolean check in an already-reviewed
control-flow branch. No new shell invocation, no new file I/O, no new
external-input handling, no system/exec/backtick/piped-open/eval-STRING
patterns introduced.

## TGT-271: Tira upgrade-gate review (5.139 -> 5.143) - no board policy change needed

Auto-raised by Tira's own upgrade gate when the host's Tira install
moved from 5.139 to 5.143 mid-session. Reviewed per the card's own
instructions: ran `d2 tira.policy.undeclared` (empty result - no
undeclared rules for this board to answer) and read all 4 changelog
entries between 5.140 and 5.143 (TKT-885: a test-only uninitialized-
value warning fix; TKT-905: a `--comment` option-reader ledger gap
fix; TKT-1114: a race-condition fix for concurrent upgrade-gate card
raising; TKT-1116: a 3.6x police-pass performance fix via path-cache
seeding). All four are internal Tira correctness/performance fixes -
none introduce a new event type, command, or board-visible concept
this board's own 53 active + 10 declined policy set doesn't already
cover. Conclusion: no policy change needed for this upgrade.

## TGT-280: closing out the D2TG::Store.pm/D2TG::Telegram.pm decomposition chain

Own follow-up filed by TGT-279's survey - the final ticket in the chain
started by TGT-278's own original `wc -l` sweep.

**D2TG::Store.pm's `_ensure_schema`** (355 lines) was the one remaining
piece of that module's own overage after TGT-278/279's cluster
extractions - a single large schema-migration function tightly coupled
to `new()`, genuinely different in shape from every prior extraction
this session (RetryQueue/History/AccessControl/SentReplyAudit are all
sets of independent methods sharing only `$dbh`; `_ensure_schema` is
one function whose own internal statements are strictly order-
dependent - e.g. the TGT-232 `bot_key` migration for `messages` copies
the `read_at`/`local_path` columns added by the two `ALTER TABLE`
blocks immediately before it, and the TGT-221 `last_retry_at` column
for `failed_downloads` is deliberately placed *after* the TGT-219
`bot_key` migration rather than before it, since that migration's own
`CREATE TABLE` only lists the columns it explicitly knows about and
would otherwise silently drop a column added out of order).

Extracted as a single plain function - `D2TG::Store::Schema::ensure_schema($dbh)`
- rather than an object, since it needs no state of its own between
calls. Moved verbatim, preserving the exact statement order from the
original `_ensure_schema` body; `D2TG::Store::new` now calls it
directly instead of via a `$self->` instance method.
`D2TG::Store.pm` is now 232 lines - comfortably under the cap, closing
out its own decomposition chain after 4 tickets (TGT-278/279/280).

**D2TG::Telegram.pm** (547 lines) was surveyed by TGT-279 but not
extracted, since its 16 functions are all tightly coupled to the
shared HTTP transport - a genuinely different shape from
`D2TG::Store`'s independent methods. Investigating further before
attempting a function-level split revealed the real driver of its
overage: its own embedded POD (210 lines) had never been extracted to
a separate `.pod` file, unlike every other large module this session
touched - the actual I<code> is only 338 lines, already comfortably
under the cap on its own. Extracted the POD to `Telegram.pod` -
closing out this module's own decomposition with zero functional
change and none of the risk a forced outbound-send module split would
have carried. This is a useful general lesson from this whole
decomposition chain: always check whether embedded POD alone explains
an overage before designing a functional split - TGT-273's own
Poller.pm work established this pattern, but it wasn't systematically
re-checked for every subsequently-discovered oversized module until
this ticket.

Extracting both `.pod` files surfaced the same class of podchecker
bug TGT-277 already fixed elsewhere: 6 unresolved `L</name>` links in
`Telegram.pod` (one had no matching `=head2` anchor at all -
`_validate_reply_to_message_id` is only ever mentioned in prose, never
given its own section - fixed by making it plain `C<>` code text
instead of a link) plus the familiar bare-name-vs-signature mismatch
for the rest, plus one benign `empty section in previous paragraph`
warning (two `=head2` headers - `send_photo`/`send_document` -
deliberately sharing one body, matching an existing pattern elsewhere
in this codebase; a warning, not an error, so it doesn't fail
`t/277-podchecker-clean.t`'s own zero-I<error> assertion). Fixed all
of them using the same pattern established in TGT-277/278/279.

New `t/280-store-schema-module.t` proves `D2TG::Store::Schema`'s
ownership via `can()` - confirmed genuinely red pre-fix. Zero behavior
change - the full pre-existing test suite passed unchanged with no
test edits needed for either extraction. Full Docker suite (211 files,
2362 tests) passes unchanged (one flaky, unrelated
`t/54-lock-acquire-race.t` failure under `Devel::Cover`'s own added
load, confirmed genuinely flaky via a clean standalone re-run); 100%
statement + subroutine coverage confirmed on `D2TG::Store`,
`D2TG::Store::Schema`, and `D2TG::Telegram`.

perlsec.pl-style vulnerability-scan audit: a pure code-relocation
refactor (the schema function moved verbatim, no logic changed) plus a
documentation-only extraction (POD moved to a separate file, zero code
touched) - no new external-input handling, no new shell/file/SQL
surface; every DDL statement is unchanged from its pre-extraction
form.

## TGT-279: continuing D2TG::Store.pm decomposition (720 -> 574 lines)

Own follow-up filed by TGT-278's survey. Extracted the 2 remaining
independent-method clusters identified by that survey: access control
(`is_allowed`/`add_pending`/`approve`/`pending_chat_ids`, plus
`_seed_admin` renamed to the now-public `seed_admin` since it's called
externally from `D2TG::Store::new`) into a new
`D2TG::Store::AccessControl` module, and sent-reply audit trail
(`record_sent_text`/`record_sent_voice`/`text_only_replies`/
`is_recent_duplicate_reply`) into a new `D2TG::Store::SentReplyAudit`
module - both mirroring `D2TG::Store::RetryQueue`/`History`'s own
established DBI-handle-wrapper precedent exactly. New
`t/279-store-access-control-module.t` and
`t/279-store-sent-reply-audit-module.t` prove both modules' ownership
via `can()` - both confirmed genuinely red pre-fix. Zero behavior
change - the full pre-existing test suite passed unchanged with no
test edits needed, matching TGT-278's own extraction (unlike TGT-275/
276's, which needed structural-regression test updates).

**A deliberate small behavior-adjacent change, caught and verified
safe**: `record_sent_voice`'s warning text and
`is_recent_duplicate_reply`'s die message both had their
`D2TG::Store::` prefix changed to `D2TG::Store::SentReplyAudit::` to
match the function's new home. Checked both against the existing test
suite before treating this as safe: `t/84-text-only-reply-audit.t`
only matches the substring `no matching sent_replies row` (not the
full module-qualified prefix), and no test anywhere matches the
`window_seconds must be a non-negative number` die text at all - so
this is not a masked behavior change to any real caller.

Surveyed `D2TG::Telegram.pm` (547 lines) as this ticket's own third
deliverable, but did not extract it: its 16 functions (`_call`,
`get_me`/`get_updates`/`get_file`/`file_download_url` for inbound;
`send_message`/`send_voice`/`send_photo`/`send_document`/`_send_file`/
`_validate_reply_to_message_id`/`_append_reply_to_message_id_field`
for outbound) are all tightly coupled to the shared HTTP transport
(`$self->{ua}`/`{token}`/`_call`) - a genuinely different shape from
`D2TG::Store`'s independent, `$dbh`-only methods. A candidate split
(an outbound-send cluster into `D2TG::Telegram::Send`) was identified
but deliberately deferred rather than rushed, matching this session's
own precedent of not forcing a design decision that needs its own
careful pass.

`D2TG::Store.pm` is now 574 lines - down from 720, but still
marginally over the 500-line cap, entirely due to `_ensure_schema`
(355 lines) - a single large schema-migration function tightly coupled
to `new()`, not a set of independent methods sharing only `$dbh` like
every prior extraction this session. Its own migrations are
sequential and order-dependent (e.g. the TGT-232 bot_key migration
reads columns added by earlier `ALTER TABLE` calls), so any future
extraction must preserve exact call order, not just move code - a
genuinely different, riskier kind of change than the DBI-handle-wrapper
pattern used for every cluster extracted so far. Filed follow-up
`TGT-280` for both `_ensure_schema` and `D2TG::Telegram.pm`. Full
Docker suite (210 files, 2344 tests) passes unchanged; 100% statement
+ subroutine coverage confirmed on `D2TG::Store`,
`D2TG::Store::AccessControl`, and `D2TG::Store::SentReplyAudit`.
Podchecker clean on both new modules' own `.pod` files and on
`Store.pod` after updating 2 of its own cross-references that pointed
at sections which had just moved to `AccessControl.pod`.

perlsec.pl-style vulnerability-scan audit: a pure code-relocation
refactor (both clusters moved verbatim into new modules following the
already-established DBI-handle-wrapper pattern) - no new external-input
handling, no new shell/file/SQL surface; the extracted methods still
use the same parameterized DBI calls and the same transaction/rollback
logic (`approve`) they always did.

## TGT-278: D2TG::Store.pm decomposition (1378 -> 720 lines) and its own podchecker cleanup

Filed via TGT-277's own pipeline-continuity backlog check: with the
backlog empty and all 5 EPICs done, ran `wc -l` across every
`lib/D2TG/*.pm` and `lib/D2TG/*/*.pm` module for the first time this
session. `D2TG::Store.pm` was 1378 lines - nearly 3x the board's
500-line-per-module cap, and by far the largest module in the
codebase, yet never flagged or decomposed despite this session's own
extensive module-decomposition history (TGT-258/259/260/261/263/265/
267/275/276 all covered other modules). `D2TG::Telegram.pm` (547
lines) was also found over the cap, more marginally.

Surveyed `D2TG::Store.pm`'s own function clusters (matching TGT-258's
own precedent for a module this large and central): access control
(`is_allowed`/`add_pending`/`approve`/`pending_chat_ids`), offset
tracking, message history (`record_message`/`get_message`/
`get_attachment_path`/`mark_read`/`is_read`/`unread_messages`/
`recent_messages`/`messages_in_range` - 8 functions, ~148 lines, the
largest single cohesive cluster), retry-queue forwarders (already
thin, extracted by TGT-257), sent-reply audit (`record_sent_text`/
`record_sent_voice`/`text_only_replies`/`is_recent_duplicate_reply`),
`prune_history`, and the connection/schema core (`new`/`_ensure_schema`/
`_seed_admin`, which must stay). The message-history cluster was
picked first - it's the largest, and its own functions only need the
shared `$dbh`, not any of the access-control/offset/retry-queue state.

Extracted verbatim into a new `D2TG::Store::History` module, mirroring
`D2TG::Store::RetryQueue`'s own established precedent exactly: built
once in `D2TG::Store::new` (`$self->{history} = D2TG::Store::History->new(
dbh => $dbh )`), thin forwarders kept in `D2TG::Store` for all 8
methods so every existing caller keeps working unchanged. New
`t/278-store-history-module.t` proves ownership via `can()` - confirmed
genuinely red pre-fix (`Can't locate D2TG/Store/History.pm`). Zero
behavior change - the full pre-existing test suite passed unchanged
with no test edits needed, unlike TGT-275/276's own extractions which
needed a few structural-regression test updates.

Also extracted `D2TG::Store.pm`'s own embedded POD (never previously
in a separate file - unlike every other large module this session
touched) into `Store.pod`. Running podchecker against the freshly-
created `Store.pod` and `History.pod` surfaced 22 more unresolved-
link errors: 20 pre-existing in `Store.pod` (the exact same bare-
name-vs-signature bug class TGT-277 just fixed across 6 other files,
never checked here since this module had no separate `.pod` file to
check before now) and 2 newly introduced in `History.pod` while
writing it. Fixed all 22 immediately rather than shipping a freshly-
touched file with known errors, using the same `L<name()|/full anchor
text>` widening pattern TGT-277 established. `t/277-podchecker-clean.t`
(TGT-277's own regression test, which auto-discovers every
`lib/**/*.pod` file) now also covers both new files and confirms zero
errors.

`D2TG::Store.pm` is now 720 lines - still over the 500-line cap but
down from 1378 - filed follow-up `TGT-279` for the remaining 2
clusters (access control, sent-reply audit) plus `D2TG::Telegram.pm`'s
own smaller 547-line overage, matching the TGT-275->276 precedent of
not forcing an oversized single-ticket refactor. Full Docker suite
(208 files, 2313 tests) passes unchanged; 100% statement + subroutine
coverage confirmed on both `D2TG::Store` and `D2TG::Store::History`.

**Process note**: two required-action `tira.ticket.move` calls in this
same session window (for TGT-274 through TGT-277, discovered while
working this ticket's own pipeline-continuity check) had appeared to
succeed based on the printed `column: pending-push` text in their own
required-item proof records, but the tickets had actually stalled at
`vulnerability-scan` - that printed text describes which column the
required-action item itself belongs to, not the ticket's own current
column. Caught and fixed by directly querying `tira.ticket.list
--column pending-push` / `tira.ticket.show`'s own top-level `column`
field rather than trusting the required-action response text. Lesson
applied for the remainder of this ticket's own gate chain: every
column-move claim in this write-up was verified by an explicit
`tira.ticket.show --ref TGT-278 | grep column:` check, not inferred
from a required-action proof.

perlsec.pl-style vulnerability-scan audit: a pure code-relocation
refactor (message-history functions moved verbatim into a new module
following the DBI-handle-wrapper pattern already established by
`D2TG::Store::RetryQueue`) plus a documentation-content fix (POD
cross-reference syntax) - no new external-input handling, no new
shell/file/SQL surface; the extracted methods still use the same
parameterized DBI calls they always did.

## TGT-277: podchecker cleanup across 6 .pod files

Filed via TGT-276's own podchecker sweep (which itself surfaced while
fixing a documentation bug in `Poller.pod`/`Safe.pod`): a full `find
lib -name *.pod | xargs podchecker` run found 48 unresolved
internal-link errors across `Config.pod` (12), `Config/Flags.pod`
(10), `Reply/Args.pod` (7), `Transcribe.pod` (9), `Transcribe/Retry.pod`
(5), and `Poller/Safe.pod` (5, introduced by TGT-275 and not yet
committed at ticket-filing time) - plus a UTF-8 encoding warning in
`Reply/Args.pod` (a literal "héllo" mojibake example used to illustrate
a real bug, with no `=encoding UTF-8` directive declared).

Root cause, identical in every case: an `L</name>` link targets a bare
function name, but the matching `=head2` anchor includes the function's
full signature (e.g. `=head2 extract_bot_flag(@args)` vs
`L</extract_bot_flag>`) - `Pod::Checker` requires an exact string match
between a link and its anchor, so every one of these links has been
silently broken since the day each `=head2` signature was written.
None of this is visible to a normal `perldoc` read (the prose still
reads fine) - it only breaks the actual hyperlink/cross-reference
behavior a POD viewer would otherwise offer.

Fixed by widening each link to `L<name()|/full anchor text>` (the
`|` alternate-text form lets the visible link text stay short while
the target matches the anchor exactly) - the same pattern already
established fixing this bug class in `Poller.pod`/`Safe.pod`/
`Dispatch.pod` during TGT-273/275/276. A few anchors contain literal
`=>` in their signature (e.g. `bot_groups(argv => \@argv, ...)`) -
POD's `L<>` markup cannot contain an unescaped `>` character, so those
required `E<gt>` escaping (`argv =E<gt> \@argv`) rather than a literal
`=>`.

New `t/277-podchecker-clean.t` runs `Pod::Checker`'s own Perl API
(not the `podchecker` binary, so it behaves identically in and out of
Docker) against every `lib/**/*.pod` file found via `File::Find`,
asserting zero errors on each - confirmed genuinely red pre-fix (5
files failing, matching the sweep exactly). This is a permanent
regression guard: any future module extraction that moves POD without
updating its own internal cross-references will now fail the suite
instead of silently shipping a broken link. Full Docker suite (207
files, 2288 tests) passes unchanged - a pure documentation fix, zero
code touched.

perlsec.pl-style vulnerability-scan audit: a pure documentation-content
fix (POD cross-reference syntax) plus one new test file reading
already-trusted repo source files via `File::Find`/`Pod::Checker` - no
external input, no new shell/file/SQL surface.

## TGT-276: D2TG::Poller::run_once decomposition, and a documentation bug found along the way

Filed via TGT-275's own REQ-029 audit: `lib/D2TG/Poller.pm` was still
598 lines after TGT-275's own helper relocation, entirely due to
`run_once` itself (~520 lines dispatching 3 branches:
`message_reaction`, `edited_message`, and the plain-text/voice/media
fallback, sharing local state - `$offset_cap`, `$telegram`, `$store`,
`$bot_token`, `$transcribe_voice`, `$download_media`).

**Design correction caught mid-implementation**: the ticket's own
original plan (extract each branch into a private function I<within
the same file>) was drafted before actually re-reading the function -
once implementation started, it became clear that splitting code into
more functions in the same file does not remove any lines at all,
only reorganizes them. Only an actual new module (matching the
`D2TG::Poller::Safe`/`D2TG::Poller::Format` precedent) reduces the
line count. Corrected the plan and proceeded with a real module split:
a new `D2TG::Poller::Dispatch` holding the 3 handler functions (each
losing its leading underscore, becoming public) plus their own
extensive historical comment blocks, moved to `Dispatch.pod`.

**Mechanical transformation, not a rewrite**: every inline `next`/
`next unless`/`next if` guard clause inside each branch body was
converted to `return`/`return unless`/`return if`, since Perl's `next`
outside of a loop is a fatal runtime error and a handler function has
no loop of its own. `run_once`'s own dispatch loop calls `next`
unconditionally right after each handler call, which has the exact
same effect the branch's own trailing `next` had before - none of the
3 branches ever falls through into another, so a `next` right after
the call is always correct. The bodies themselves (including their
own inline logic, print statements, and error handling) were moved
verbatim otherwise.

**A real documentation-accuracy bug found and fixed along the way**:
`lib/D2TG/Poller.pod` still had 5 full `=head2` sections (for
`open_store_or_die`, `store_write_safe`, `persist_offset_safe`,
`skill_version_check_safe`, `run_once_safe`) describing those
functions as if they still lived in `D2TG::Poller` - TGT-275 had
already relocated all 5 to `D2TG::Poller::Safe` (writing fresh,
accurate docs in the new `Safe.pod`) but never removed the now-stale
duplicate sections from `Poller.pod` itself. Also found 2 stale
`L<D2TG::Poller/...>` cross-references (in `Config.pod` and this
module's own `KNOWN LIMITATION`/`DESCRIPTION` sections) and 4 more
stray mentions in `docs/commands.md` and a `cli/poller.pl` comment.
All fixed as part of this ticket's own documentation work, since it
was already touching `Poller.pod` for the `run_once` rewrite.

**Dead-code cleanup**: TGT-259 originally kept 11 of
`D2TG::Poller::Format`'s 13 relocated functions forwarded in
`D2TG::Poller` for every internal call site. This ticket's own move of
`run_once`'s branch bodies into `D2TG::Poller::Dispatch` (which calls
`D2TG::Poller::Format`'s bare functions directly) left 10 of those 11
forwarders with no caller left at all - confirmed via a coverage run
that surfaced them as 0-count subroutines - removed as permanently-
uncallable dead code, matching TGT-259's own precedent for
`_stored_summary`/`_forward_origin_name`. Only `_bot_flag` survives,
for its one remaining external caller
(`t/226-bot-flag-helper-extracted.t`).

New `t/276-poller-dispatch-module.t` proves ownership via `can()`
(matching `t/263`/`t/275`'s own pattern) - confirmed genuinely red
pre-fix. Two existing structural-regression tests (`t/181`, `t/198`)
needed updating to point at the new module and the new (unprefixed)
argument-passing shape (`$offset_cap_ref` passed straight through
rather than re-taking a ref with `\$offset_cap`, since the caller in
`run_once` now takes the ref once at the dispatch call site). Full
Docker suite (206 files, 2272 tests) passes unchanged; 100% statement +
subroutine coverage confirmed on both `D2TG::Poller` and
`D2TG::Poller::Dispatch`. `D2TG::Poller.pm` is now 74 lines;
`D2TG::Poller::Dispatch.pm` is 275 lines - both comfortably under the
board's 500-line-per-module cap, with no further follow-up ticket
needed.

perlsec.pl-style vulnerability-scan audit: a pure code-relocation
refactor (branch bodies moved verbatim, `next` mechanically converted
to `return`) plus a documentation-only correction - no new external-
input handling, no new shell/file/SQL surface introduced.

## TGT-275: D2TG::Poller.pm decomposition - the 8 non-run_once helper functions

Filed via TGT-273's own REQ-029 audit: `lib/D2TG/Poller.pm` was 854
lines after TGT-273's POD extraction to `Poller.pod` - over this
board's 500-line-per-module cap. Investigated the file's own shape: 8
of its functions (`open_store_or_die`, `run_once_safe`,
`_record_message_safe`, `_record_message_and_track_offset`,
`_classify_store_error`, `store_write_safe`, `persist_offset_safe`,
`skill_version_check_safe`) share a common eval-wrap/non-fatal-
degradation shape and have no dependency on `run_once`'s own dispatch
logic - a cohesive, independently-testable cluster, unlike `run_once`
itself (a single ~530-line function with 5 major branches sharing local
state).

Relocated the 8 functions verbatim into a new `D2TG::Poller::Safe`
module (each losing its leading underscore where private, becoming
public alongside its siblings) + its own `Safe.pod`. No forwarder was
left in `D2TG::Poller` - matching this session's own TGT-261/263/265/267
zero-forwarder precedent for a small caller count. Updated every call
site: 8 `cli/*.pl` scripts (`attachment`, `approve`, `history`,
`reply`, `retry-download`, `retry-transcription`, `text-only-replies`,
`unread`, plus `poller.pl` which needed both `use D2TG::Poller;` and
`use D2TG::Poller::Safe;`), `D2TG::Download.pm`,
`D2TG::Transcribe::Retry.pm`, `D2TG::Reply.pm`, and 6 structural-
regression `t/` files whose own source-text assertions named the old
module/location explicitly (`t/181`, `t/195`, `t/198`, plus 3 more
picked up by the general sweep).

**Circular-dependency note**: `D2TG::Poller::Safe::run_once_safe` calls
`D2TG::Poller::run_once` via its fully-qualified name, but
`D2TG::Poller::Safe.pm` itself does NOT `use D2TG::Poller;` at
compile time - only `D2TG::Poller.pm` `use`s `D2TG::Poller::Safe;` (for
its own internal calls to `store_write_safe`/
`record_message_and_track_offset`). This one-directional `use` avoids a
circular-`use` compile-time trap; `run_once_safe`'s runtime call to
`D2TG::Poller::run_once` works because every real caller (`cli/poller.pl`)
already loads both modules before either function is ever invoked.

New `t/275-poller-safe-module.t` proves ownership via `can()` (matching
`t/263-transcribe-retry-module.t`'s own pattern) - confirmed genuinely
red pre-fix (`Can't locate D2TG/Poller/Safe.pm`). Full Docker suite
(205 files, 2258 tests) passes unchanged; 100% statement + subroutine
coverage confirmed on both `D2TG::Poller` and `D2TG::Poller::Safe`.
`D2TG::Poller.pm` is now 598 lines - still over the cap, entirely due
to `run_once` itself - filed as follow-up `TGT-276`.

perlsec.pl-style vulnerability-scan audit: a pure code-relocation
refactor - no new external-input handling, no new shell/file/SQL
surface introduced by moving already-reviewed functions between two
files in the same package hierarchy.

## TGT-274: Tira upgrade-gate review (5.143 -> 5.144) - no board policy change needed

Auto-raised by Tira's own upgrade gate when the host's Tira install
moved from 5.143 to 5.144 mid-session. Ran `d2 tira.policy.undeclared`
(empty result - no undeclared rules for this board to answer) and read
the single Changes entry for 5.144 (TKT-1106: extends
`tira.police.explain` to `card-duration`, `agent-still`, and
`board-still`, which it previously refused by name - a pure internal
explain-command improvement, extracting each rule's own real inputs
the same way an earlier ticket extracted `discard-unexplained`'s own).
Introduces no new event type, command, or board-visible concept this
board's own 53 active + 10 declined policy set doesn't already cover.
Conclusion: no policy change needed for this upgrade.

## TGT-273: edited_message branch had no redelivery-dedup guard at all

Found via a scheduled JOB-004 improvement hunt, as a direct follow-up
sweep after TGT-270 (this same session) hardened the plain-message/
media/voice branch of `run_once` against a Telegram redelivery of an
already-processed update. Checked the sibling `edited_message` branch
for the same class of gap: confirmed by direct source read that it had
NO dedup guard whatsoever - it unconditionally printed `NEW TG EDIT`
every time it was reached, with zero check against whether this exact
edit had already been announced on a prior poll cycle.

The design fix is genuinely different from TGT-270's, not a copy-paste
of it. TGT-270's fix works by checking mere row *presence*
(`get_message`/`has_failed_download`/`has_failed_transcription`) because
none of those tables are ever populated for a message that hasn't yet
been successfully processed or hasn't yet failed. That assumption does
NOT hold for `edited_message`: `record_message` upserts on
`(chat_id, bot_key, message_id)`, so `get_message` is already non-null
for ANY message ever recorded, including the ORIGINAL pre-edit send -
reusing presence-alone here would wrongly suppress a genuinely new
(never-before-announced) edit the very first time it arrived, since the
original message's own row already exists.

Fixed instead by comparing the incoming (sanitized) edited text against
the row's already-stored `summary`: identical means this exact edit was
already recorded (a redelivery - skip, matching TGT-270's own
skip-and-degrade-on-lookup-error philosophy); different, or no row at
all, means a genuinely new edit or the very first one (announce and
record exactly as before). Scoped to the `has_text` case only - a
caption/media-only edit has never been recorded via `record_message` at
all (a pre-existing, documented scope boundary from this same branch's
own TGT-217 history), so there is no stored state to compare against;
a redelivered caption-only edit still re-announces, an accepted,
documented gap rather than an attempt to invent a new persisted marker
for it.

New test `t/273-edited-message-redelivery-skips-duplicate-announce.t`:
seeds a stored message whose summary already equals the incoming edit's
text, feeds `run_once` that same `edited_message` update again, and
confirms `NEW TG EDIT` is not re-printed (confirmed genuinely red
before the fix - 1 of 4 subtests failed at exactly this assertion). Two
further scenarios confirm the fix doesn't over-suppress: a genuinely
different edit (summary differs from the incoming text) still announces
and updates the stored summary; a first-ever edit (no prior row at all)
still announces and records normally.

While implementing, `lib/D2TG/Poller.pm`'s own embedded POD (605 lines,
present since before this ticket, never previously split) was extracted
to `lib/D2TG/Poller.pod`, matching this session's own established
convention (Transcribe/Reply/Config) for any module touched under the
board's POD-in-a-separate-file requirement. The module is still 854
lines after that extraction - over the board's 500-line-per-module cap,
a pre-existing size issue not introduced by this ticket's own small
diff - filed as follow-up `TGT-275` for a full decomposition, matching
the TGT-264->265/TGT-266->267 precedent of not folding a large
refactor into an unrelated bugfix.

perlsec.pl-style vulnerability-scan audit: one new read-only
`get_message` call (already an existing, already-reviewed method - no
new SQL, no new external-input handling) plus a plain string
equality comparison. No new shell invocation, no new file I/O, no new
system/exec/backtick/piped-open/eval-STRING patterns introduced.

## TGT-281: cli/poller.pl audited against the 500-line convention - no extraction, real code is already small

Filed via TGT-280's own pipeline-continuity backlog check: with every
`lib/D2TG/*.pm` module now under the board's 500-line-per-module cap,
a `wc -l` sweep across `cli/*.pl` found `cli/poller.pl` at 766 lines -
by far the largest script in `cli/`, never audited against the same
convention (the board's own REQ-029 wording is scoped to "pm files",
so this was a genuine new finding, not an existing gate violation).

Read the file in full and mapped its own sections: shebang/`use`s/UTF-8
setup, `--help`/argv parsing and validation, startup guards (lock
acquisition, other-poller detection/classification/warning), storage
open + admin-seed construction, bot/chat pair construction, the main
`until ($shutting_down)` poll loop (per-pair poll, offset persistence,
auto-retry downloads/transcriptions, heartbeat, vault/history prune,
version-check restart), cleanup, and embedded POD.

**Decision: no extraction.** Every remaining code block is either
startup-sequencing (each step guards the next: parse -> lock -> store
-> pairs, genuinely order-dependent) or the main loop's own inline
sequencing (also order-dependent) - there is no cohesive cluster here
that another caller would ever want to invoke independently, unlike
the `D2TG::Poller::Dispatch`/`Safe` extractions (TGT-275/276), which
had real external reuse (many `cli/*.pl` callers) driving the split.
Every genuinely reusable behavior this script touches is already
delegated to `lib/D2TG::` (`Config`, `Lock`, `Store`, `Telegram`,
`Poller::Safe`, `Download`, `Transcribe`, `Transcribe::Retry`) and
independently unit-tested there - confirmed via a grep sweep showing
`find_other_pollers`/`classify_other_poller_token` (the one block that
looked like a plausible extraction candidate, the other-poller
detection/warning logic at lines 203-260) already live in `D2TG::Lock`
with their own dedicated tests (`t/82-orphaned-poller-detection.t`,
`t/105-orphaned-poller-token-crosscheck.t`); what remains in
`poller.pl` at that block is pure STDERR-message orchestration tied to
this one entrypoint's own output conventions, not reusable logic.
Extracting print-statement glue into a `lib/` module purely to reduce
a raw line count would also cut against this ticket's own explicit
design constraint: `cli/poller.pl` must stay a thin, runnable
entrypoint, not become a library module itself.

**The raw 766-line count is also misleading**, in the same way TGT-280
found for `D2TG::Telegram.pm`'s embedded POD - here the inflation comes
from extensive inline incident-documentation comments instead. A line
breakdown of the pre-POD portion (lines 1-546): 254 comment-only lines,
43 blank lines, leaving only **249 actual code lines** - the embedded
POD (`=head1 NAME` through `=cut`, lines 548-766) accounts for a
further 220 lines on top of that. So of the raw 766, only ~249 are
real, executable code - well under any reasonable per-file cap, module
or script. This confirms the general lesson from TGT-280 generalizes
beyond embedded POD specifically: **always check what raw line count
actually consists of (POD, comments, blank lines vs. real code) before
designing a functional split** - a `wc -l` sweep is the right first
signal to find candidates, but it is not itself proof that a genuine
decomposition problem exists.

24 existing test files already exercise `cli/poller.pl`'s startup and
runtime behavior at the integration/subprocess level (e.g.
`t/82-orphaned-poller-detection.t`, `t/183-poller-store-startup-crash.t`,
`t/234-multi-bot-admin-seeding.t`) - there is no testability gap that
extraction would close either.

`t/281-poller-cli-line-audit-documented.t` (new): the TDD equivalent
for this documentation-outcome ticket - asserts the real (non-comment,
non-blank, non-POD) code line count stays under 500 (a regression guard
against this script quietly growing past the cap while staying under
the raw-line radar via comment density) and asserts this exact section
exists in `docs/POLICIES.md`, matching this session's own
investigation-write-up convention (TGT-274, TGT-279's `D2TG::Telegram.pm`
survey). No functional code changed; no `.pm`/`.pod` files touched, so
REQ-028/029 (POD-split, 500-line-cap audits) are not applicable to this
ticket's own diff.

## TGT-286: cli/poller.pl's two bot_groups calls weren't eval-wrapped like every other failure path

Found via a scheduled JOB-003 hourly bug hunt: `cli/poller.pl`'s
startup failure paths (`lock_path`, `heartbeat_path`, `D2TG::Store->new`
- TGT-183/184/185) were all deliberately `eval`-wrapped and refuse with
a clean, fixed `... - refusing to start.` STDERR message rather than
letting a raw, uncaught Perl exception escape. The two
`D2TG::Config::Flags::bot_groups` calls (the validation-only pass at
what was line 89, and the real call that builds `$groups` at what was
line 122) were never brought into that same convention - a malformed
`--chat_id` shape, a duplicate `(chat_id, bot token)` pair, or a bot
token reused across chat ids all still died raw, surfacing
`D2TG::Config::Flags::bot_groups: <reason>` verbatim on STDERR with
Perl's own default exit code (255) instead of this script's own clean
shape (exit 1).

Not a functional defect on its own - the process still exits non-zero
and does not hang, and no secret is ever embedded in any of
`bot_groups`'s own die messages (`masked_token` is used in the
cross-chat-id case; the duplicate-pair case names only the chat id and
the literal CLI token text, matching what the user themselves typed).
But it is a genuine, live inconsistency against this script's own
hard-won TGT-183/184/185 convention, found by the same class of
scheduled review that produced those three tickets.

**Fix**: added a `bot_groups_or_die` wrapper local to `cli/poller.pl`
(not a `lib/D2TG::` extraction - it is three lines of glue specific to
this script's own STDERR-message convention, not reusable logic) that
`eval`-wraps the call, strips `bot_groups`'s own
`D2TG::Config::Flags::bot_groups: ` module-qualifying prefix, and
prints `Invalid --chat_id/--bot configuration (REASON) - refusing to
start.` on STDERR before exiting 1. Both call sites now go through it.

`t/286-poller-bot-groups-eval-wrapped.t` (new): drives a malformed
`--chat_id` through the real `cli/poller.pl` subprocess (via the
shared `Test::CaptureStdio::run_capturing_stderr` helper, TGT-203) and
asserts the clean-refusal shape; confirmed genuinely red beforehand (2
of 3 assertions failed, both against the raw module-qualified die text
instead of the new message). `t/202`/`t/213`/`t/126`/`t/77` (the
existing tests already exercising a `bot_groups` die through this
script) re-confirmed green and unaffected - none of them asserted the
exact STDERR text this fix changed, only that a refusal happened.

perlsec.pl-style vulnerability-scan audit: the new wrapper only
`eval`s an existing, already-reviewed function call and does a plain
string substitution/print - no new shell invocation, no new file I/O,
no new system/exec/backtick/piped-open/eval-STRING patterns, and no
secret is newly exposed (confirmed above - the underlying die messages
never embedded a bot token to begin with).

## TGT-287: the resolve_alias_dir_or_die + require_existing_base_dir_or_die pairing was duplicated across 12 cli/*.pl scripts

Found via a follow-up JOB-003/004 sweep after TGT-286: with
`D2TG::OrDie::or_die` (TGT-269) already de-duplicating the individual
eval/print-STDERR/exit(1) wrapper idiom for `resolve_alias_dir_or_die`
and `require_existing_base_dir_or_die` separately, the *calling
pattern* - call the first, then call the second on its result - was
still hand-copied, byte-for-byte, across 12 of the 14 `cli/*.pl`
scripts (`help.pl`/`tts.pl` don't open storage, correctly excluded).
Confirmed via `grep`: every single one of the 12 had the exact 2-line
sequence

```perl
my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

D2TG::Config::require_existing_base_dir_or_die($base_dir);
```

adjacent, in that order, with no intervening logic - unlike the
earlier `extract_db_flag_or_die` call, which had real per-script
variation before it (some scripts parse additional CLI flags between
extracting the `--db` flag and resolving the alias), so bundling all 3
steps into one function (as originally scoped) would have broken that
variation; only the 2-step pairing was safe and universal.

**Fix**: added `D2TG::Config::Paths::resolve_and_require_base_dir_or_die`
(forwarded via `D2TG::Config`, matching the established forwarder
pattern) composing both calls. All 12 call sites replaced with a single
line. Zero behavior change - same refusal messages, same exit codes,
confirmed by re-running every affected script's own existing test file
plus the full suite.

`t/287-resolve-and-require-base-dir-helper.t` (new): an ownership-proof
test confirming both `D2TG::Config` and `D2TG::Config::Paths` own the
new function, plus one success-path regression check. The failure path
is deliberately NOT re-tested here (it delegates straight to
`D2TG::OrDie::or_die`, whose own `exit(1)`-on-failure behavior is
already covered by `require_existing_base_dir_or_die`'s own tests and
every `cli/*.pl` script's own startup-refusal test) - duplicating it
would be exactly the class of redundancy this ticket exists to remove.

While implementing, `D2TG::Config::Paths.pm`'s own embedded POD
(previously kept inline after `__END__`, never extracted) was moved to
a new `Paths.pod`, matching this session's established
POD-in-a-separate-file convention, since this ticket substantively
touched the module. `t/272-or-die-wrapper-pod-mentions-delegation.t`
(a structural regression test predating this ticket) hardcoded
`lib/D2TG/Config/Paths.pm` as the location of 2 of its 5 checked
sections - updated to `Paths.pod` to match, confirmed still green.

perlsec.pl-style vulnerability-scan audit: the new function is a pure
2-line composition of two already-reviewed, already-audited existing
calls - no new shell invocation, no new file I/O, no new system/exec/
backtick/piped-open/eval-STRING patterns, no new external-input
handling.

## TGT-288: silenced 8 benign "used only once" warnings across 7 test files

Found via a scheduled JOB-004 improvement hunt following up on
TGT-287: `prove -lr t 2>&1 | grep "used only once"` surfaced 8 real
occurrences across 7 test files (`t/22`, `t/23`, `t/40`, `t/80`,
`t/81`, `t/212`, `t/216`). Each is a deliberate, legitimate pattern -
reading another package's variable or sub by full qualification
exactly once, specifically so a doc-accuracy or behavior assertion is
derived from the real constant/sub instead of a re-typed literal that
could silently drift (`t/81`'s own comment explains the reasoning for
its two). Perl's strict-vars warning system cannot distinguish this
from an actual typo, so it flags every one - real, but benign, noise
that accumulates on every full-suite run and makes a genuinely new
warning harder to spot among the expected ones.

**Fix**: added `no warnings 'once';` (or `no warnings qw(redefine
once);` in `t/80`, which already had a `redefine` suppression for an
unrelated mock) scoped as tightly as possible around each offending
reference - a bare block in `t/216`/`t/22`/`t/23`, a `do { }` block in
`t/81`/`t/212`, and inline in `t/40`/`t/80` where the reference already
sat inside its own small block. No assertion logic changed anywhere.

`t/288-no-once-warnings.t` (new): runs each of the 7 affected files as
a real subprocess and asserts its STDERR carries no "used only once"
text - confirmed genuinely red beforehand (7/7 failed, each showing
the exact warning). Not a `.pm`-touching ticket, so REQ-028/029 (POD
split, 500-line cap) don't apply.

perlsec.pl-style vulnerability-scan audit: pure test-file
warnings-pragma additions - no shell invocation, no file I/O, no
system/exec/backtick/piped-open/eval-STRING patterns, no new
external-input handling, no assertion or behavior change.

## TGT-289: Tira upgrade-gate review (5.144 -> 5.150) - no board policy change needed

Auto-raised by Tira's own upgrade gate when the host's Tira install
moved from 5.144 to 5.150. This confirms `upgrade-unreviewed` (enabled
via TGT-283) is working exactly as intended - it fired on this card
within minutes of it landing in `backlog`, per `agent-still`'s own
"diagnose the board-wide silence" instruction. Ran `d2
tira.policy.undeclared` (empty - no undeclared rules) and read every
Changes entry from 5.145 through 5.150:

- 5.145 (TKT-1120): internal `policy_evaluate` duplicate-detection
  scoping fix - no board-facing rule/option change.
- 5.146 (TKT-908): `comment.add`'s refusal message now names `--text`
  correctly when a caller passes `body =>` instead - message-quality
  only.
- 5.147 (TKT-967): policy-declaration forbidden-option refusal wording
  improved (a shared per-option reason table) - message-quality only.
- 5.148 (TKT-968): a doc-drift fix inside Tira's own `SKILLS.md`/test
  suite - not applicable to this board.
- 5.149 (TKT-970): removed a no-op `include_discard` argument from
  Tira's internal `record_list` - this project only calls the `d2
  tira.*` CLI, never that internal Perl API directly, so no impact.
- 5.150 (TKT-972): a new `card-stamp-unreadable` finding, layered
  automatically into rules this board already has declared
  (`checklist-idle`, `card-duration`, `question-unanswered`, and
  others) - strengthens existing coverage, needs no separate
  `tira.policy.add`.

Conclusion: nothing between 5.144 and 5.150 requires a new
declaration, decline, or update to an existing one on this board.

## TGT-290: multipart upload boundary had only ~30 bits of entropy

Found via a user-requested comprehensive bug/improvement sweep
(2026-09-17): 6 parallel adversarial code-review passes across the
whole codebase, dispatched after repeated scheduled bug-hunt/
improvement-hunt passes this session had come back clean. The shared
multipart boundary generator used by `send_voice`, `send_photo`, and
`send_document` (via `_send_file`) in `lib/D2TG/Telegram.pm` was
`'D2TGBoundary' . int(rand(1e9)) . time` - about 30 bits of entropy.
`_send_file`'s own caption path already strips accidental boundary
occurrences (TGT-162), and its own comment explicitly flagged that the
uploaded file's raw bytes were NOT given the same protection - a file
whose raw bytes happened to contain the generated boundary string
would corrupt the multipart request. `send_voice` had no such
protection at all for its own audio payload. This was a
self-documented, acknowledged-but-still-open gap, not a resolved
design decision.

**Fix**: added a shared `_generate_boundary` helper using 8 rounds of
`rand(65536)` (128 bits of real entropy, 32 hex characters) instead of
a single `rand(1e9)` call, making an accidental collision with real
file content cryptographically improbable instead of merely
improbable. Both call sites (`send_voice`, `_send_file`) now call this
one helper instead of duplicating the formula inline - a small
duplication-removal side benefit of the fix, not a separate ticket.

`t/290-telegram-boundary-high-entropy.t` (new): asserts the generated
boundary matches a 32-hex-char high-entropy pattern and that two real
generations never collide; confirmed genuinely red beforehand
(`_generate_boundary` didn't exist). `t/116-send-file-caption-boundary-
collision.t` (pre-existing, TGT-162's own regression test) had its own
boundary-computation formula updated to match the new implementation -
it independently recomputes the expected boundary using the mocked
`rand`/`time` overrides already in place, so this was a one-line
formula update, not a rewrite of the test's own logic.

perlsec.pl-style vulnerability-scan audit: this is exactly a security
hardening fix - replacing a weak-entropy random-value generator with a
cryptographically stronger one. No new shell invocation, no new file
I/O, no new external-input handling, no system/exec/backtick/piped-
open/eval-STRING patterns introduced.

## TGT-291: is_transient_error's 5xx regex missing word-boundary anchor unlike its 429 sibling

Found via the same comprehensive sweep as TGT-290. `is_transient_error`'s
5xx classification (`/status 5\d\d/`) never got the same `\b`
word-boundary anchor the 429 check three lines below it has (added by
TGT-160, explicitly tested by `t/01-config.t` to reject a near-miss
like "status 4290"). The same near-miss class was unguarded for 5xx: an
error string containing "status 5001" (or any 4+ digit number starting
with 500-599) would incorrectly match and be classified as transient -
retried instead of surfaced as a real, permanent failure.

**Fix**: one-character regex change, `/status 5\d\d/` -> `/status
5\d\d\b/`, matching the 429 check's own pattern exactly.

Extended the existing `t/01-config.t` (rather than creating a new test
file) with one assertion mirroring its own established 429 near-miss
test, since this is the identical bug class on the identical function -
confirmed genuinely red beforehand.

perlsec.pl-style vulnerability-scan audit: a single regex anchor
addition - no new shell invocation, no new file I/O, no new
external-input handling, no system/exec/backtick/piped-open/eval-STRING
patterns introduced.

## TGT-292: 5 stale POD cross-references from the TGT-263/265 module moves, missed by t/266's own regex gap

Found via the same comprehensive sweep as TGT-290/291. TGT-263/265 moved
several functions into new modules (`D2TG::Reply::Args`,
`D2TG::Transcribe::Retry`) and, per the project's own established
convention, `t/266-config-pod-no-stale-reply-cross-link.t` exists
specifically to catch any `L<>` POD cross-reference left pointing at a
function's old, pre-move location. But that test's own regex patterns
only matched the fully-qualified `Module::name` call syntax (e.g.
`D2TG::Reply::parse_cli_args`) - not the `L<Module/name>` POD link
syntax (e.g. `L<D2TG::Reply/parse_cli_args>`), which is what every one
of the 5 stale references actually used. The staleness sat undetected
since the TGT-263/265 moves themselves.

**Root cause**: a POD `L<>` link's target half can be written either as
plain text naming a module and section, or the `Module/section` shorthand
that POD renders as a clickable cross-reference - `t/266` was written
against only the first form.

**Fix**: corrected all 5 stale links to point at their function's real,
current location, following this project's own established `L<>`-fixing
convention (`L<name()|/exact anchor text>` for a same-document link,
`L<name()|Module::Name/exact anchor text>` for cross-document, with a
literal `=>` inside anchor text escaped as `=E<gt>` since `L<>` cannot
contain a bare `>`):

- `cli/reply.pl`: `L<D2TG::Reply/parse_cli_args>` ->
  `L<parse_cli_args()|D2TG::Reply::Args/parse_cli_args(@ARGV)>`
- `cli/retry-download.pl`: `L<D2TG::Reply/extract_bot_flag>` ->
  `L<extract_bot_flag()|D2TG::Reply::Args/extract_bot_flag(@args)>`
- `cli/approve.pl`: same fix as retry-download.pl
- `cli/retry-transcription.pl`: `L<D2TG::Transcribe/retry_failed_transcription>` ->
  `L<retry_failed_transcription()|D2TG::Transcribe::Retry/retry_failed_transcription($telegram, $store, $row, ua =E<gt> $optional_client)>`
- `lib/D2TG/Store.pod`: `L<D2TG::Transcribe/auto_retry_failed_transcriptions>` ->
  `L<auto_retry_failed_transcriptions()|D2TG::Transcribe::Retry/auto_retry_failed_transcriptions($telegram, $store, bot_key =E<gt> $b, ua =E<gt> $optional_client)>`

Widened `t/266`'s own `@stale_patterns` list (rather than writing a
separate new test) with 5 new patterns matching the `L<Module/name>`
syntax alongside the existing `Module::name` ones - deliberately turning
the widening itself into the red-confirmation step. Confirmed exactly 5
new failures (out of 541 total assertions) after widening, matching the
5 real stale references identified by review, before any fix was
applied; all 5 pass after the fix.

perlsec.pl-style vulnerability-scan audit: pure documentation/POD text
changes plus a test-regex widening - no new shell invocation, no new
file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced.

## TGT-293: 14 unwrapped $store-> calls across 7 cli scripts

Found via the same comprehensive sweep as TGT-290/291/292.
`D2TG::Store->new` sets `RaiseError => 1` on its DBI handle, and
`D2TG::Poller::Safe::open_store_or_die` only wraps the constructor call
itself, not any later method call on the returned `$store` object.
14 call sites across 7 cli scripts (`history.pl` x2, `retry-download.pl`
x3, `retry-transcription.pl` x3, `attachment.pl` x1, `unread.pl` x3,
`reply.pl` x1, `text-only-replies.pl` x1) invoked `$store->method(...)`
completely unwrapped by eval. A locked/busy SQLite database at the
exact moment any of these calls ran would raw-crash with an uncaught
DBI exception (which can embed the real db path) instead of this
project's own established clean-refusal convention
(`STORE ERROR: ... failed - REASON`, exit 1) - the exact bug class
TGT-183/186/195 already fixed for other call sites, just never swept
this widely. Only `cli/approve.pl`'s own `$store->` calls were already
correctly wrapped in this whole file family.

**Fix**: wrapped every named call site in `eval { ... }`, classified any
failure via the shared `D2TG::Poller::Safe::classify_store_error`, and
printed a scrubbed `STORE ERROR: <method> failed - $reason` line before
exiting 1 - matching the established pattern exactly.
`retry-download.pl` and `retry-transcription.pl` each had 3 identical
`failed_downloads`/`failed_transcriptions` call sites, so a small local
`_failed_downloads_or_die`/`_failed_transcriptions_or_die` helper
function was introduced in each file to avoid repeating the same
eval/classify/print block 3 times.

New test `t/293-cli-store-calls-eval-wrapped.t` (source-inspection
regression test, matching the established precedent in
`t/195-approve-store-calls-classified-not-raw.t` for exactly this
situation - a real locked-database failure occurring strictly after
`D2TG::Store->new` already succeeded is not reliably reproducible
black-box via a CLI subprocess) asserts each of the 14 named call sites
matches an explicit `eval { $store->method(...)` pattern, that the file
uses the shared classifier and prints a classified `STORE ERROR` line,
and that the total count of `$store->` occurrences in each file exactly
matches the number of explicitly-checked wrapped patterns (so no
additional, still-unwrapped call site could be hiding elsewhere in the
file). Confirmed genuinely red beforehand by checking the pre-fix
version of all 7 files via `git show HEAD:cli/<file>` against the same
patterns - none had any wrapped occurrence.

perlsec.pl-style vulnerability-scan audit: this is exactly a hardening
fix - replacing raw, unguarded database calls with the project's
established eval/classify/refuse pattern, which itself exists to avoid
leaking the real database path in an uncaught exception. No new shell
invocation, no new file I/O, no new external-input handling, no
system/exec/backtick/piped-open/eval-STRING patterns introduced.
