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
first. Confirmed genuinely red against the pre-fix code - the whole
test script crashed with an uncaught die (no TAP plan produced at all)
rather than merely failing an assertion, since the raw exception
propagated straight out
of `send_reply` with nothing to catch it; the malformed-result
regression block was separately confirmed red against the round-2
(`eval`-guarded dereference) code before landing on the `ref()`-check
version - the round-2 code returned success silently instead of dying,
which is exactly the failure this block exists to catch.
