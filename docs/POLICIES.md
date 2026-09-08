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

`D2TG::Transcribe::select_model($duration_seconds)` now tiers the model:
up to 5 minutes stays `medium` (today's quality, unchanged for the
common case), up to 15 minutes drops to `small`, longer uses `base` -
each step trading transcription accuracy for speed to stay within
`$TIMEOUT`. `transcribe()` measures the audio's actual duration via
`ffprobe` (a list-form pipe `open`, never a shell string, so the audio
path can never reach a shell) before choosing, unless the caller passes
an explicit `model` argument, which always wins - unchanged from before
this ticket.

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
