# tg

**Status: early implementation (v1.56).** CONSISTENCY FIX (TGT-193,
found via a scheduled JOB-004 improvement hunt): `D2TG::Poller::run_once`'s
4 STORE ERROR print blocks (`is_allowed` x3, `add_pending` x1) printed
the raw DBI/SQLite exception text verbatim to STDERR, instead of
classifying it via the already-established shared `_classify_store_error`
helper - every other `D2TG::Store` error path in this codebase already
does this (`is_allowed` is a read, not a write, but is still a
`D2TG::Store` call this classification pattern applies to). These 4
call sites predate `_classify_store_error`
(TGT-165, before TGT-167 extracted the shared helper) and were simply
never revisited. A raw DBI/SQLite error can embed the database file's
own real path - the same disclosure risk TGT-133 established as this
project's standard to avoid.

RELIABILITY FIX (TGT-192,
found via a scheduled JOB-003 hourly bug hunt, the same class of
issue TGT-191 just fixed): `D2TG::Reply::send_reply`/`resend_voice`'s
own `record_sent_text`/`record_sent_voice`/`mark_read` calls were the
one `D2TG::Store` write call site in this codebase never wrapped in
`eval`. `record_sent_text` runs against a `RaiseError=>1` handle, so a
locked/busy database died raw AFTER `send_message` had already
succeeded - aborting the rest of `send_reply` entirely (skipping voice
synthesis, which runs unconditionally afterward) and reporting a hard
failure that could even suggest retrying, risking a duplicate text
delivery. All 5 call sites now go through a shared `_store_write_safe`
helper - `eval`-wrapped, classified via
`D2TG::Poller::_classify_store_error`, logged non-fatally. Voice
synthesis/send naturally still runs afterward (the die no longer
aborts the sub), and a store-write failure specifically can no longer
turn an otherwise-successful `send_reply` call into a reported hard
failure - synthesis/`send_voice` themselves still fail loudly exactly
as before (TGT-083's own text-first tradeoff is unchanged; only the
local audit-trail write's own failure is now non-fatal). A malformed
voice-send result (not a hashref - e.g. `send_voice` returning `undef`)
is never misclassified as a store-write failure: `ref($voice_result) eq
'HASH'` is checked explicitly, and a non-hashref result dies for real -
but only when a `store` was actually given (a caller that never passes
`store` is unaffected either way, same as before this ticket). A
well-formed hashref simply missing a `message_id` key (a legitimate
shape some callers' `telegram` doubles use) still quietly skips just
the store write, with no error at all - four further Codex QA-stage
review rounds were needed to land on this: an `eval`-guarded
dereference alone can't tell the two shapes apart, since dereferencing
a hash key off `undef` never actually raises an exception in Perl
(round 3); `resend_voice`'s own `mark_read` originally ran BEFORE this
check, so a malformed result died only after the message was already
marked read, defeating the retry/recovery state `resend_voice` exists
to preserve (round 5); and the check itself was originally gated on
`store && text_message_id` while `mark_read` is gated on the broader
`store && reply_to_message_id`, letting a malformed result slip past
whenever `text_message_id` was omitted (round 6, fixed in both
functions by checking whenever `store` is given at all).
RELIABILITY FIX (TGT-191,
live production incident via the budget project: 2 real Telegram
messages permanently lost): `cli/poller.pl`'s main loop advanced its
in-memory poll offset unconditionally after each cycle, regardless of
whether `D2TG::Poller::persist_offset_safe` actually durably saved it.
Telegram's own `getUpdates` offset parameter is a confirmation
mechanism, not just a cursor - it forgets/never redelivers an update
once a LATER offset is sent, so a still-running process using the
advanced-but-unpersisted offset on its next `getUpdates` call would
confirm that batch to Telegram; a crash for any reason before a later
persist caught up then lost that batch forever - structurally
identical to the live incident. `persist_offset_safe` now returns a
true/false success flag (previously always void); the main loop only
advances the in-memory offset on a true return, so a failed persist
reuses the same offset next cycle and Telegram redelivers the batch
instead of discarding it (deduplicated locally via `record_message`'s
own upsert and `run_once`'s own already-recorded check, TGT-178).
RELIABILITY FIX (TGT-190,
filed from TGT-187's own investigation): `D2TG::Config::changes_summary`
silently returned `undef` with zero diagnostic whenever no entry could
be matched for the requested version against an otherwise-readable
`Changes` file - not only a genuine wrong-version mismatch, but also a
header line whose version matches but whose own shape is malformed.
Now prints a non-fatal STDERR diagnostic naming the requested version
and, if the file has one, a recognizable header found elsewhere in it
- or says explicitly that none was found, if it doesn't (two Codex
QA-stage review rounds: the diagnostic searches for the first
strictly-shaped header anywhere in the file, so it can skip a
malformed earlier one and isn't necessarily "the" file's own literal
top header; and a file with no strictly-shaped header at all names
none, rather than always naming one) before returning
`undef` unchanged - matching this project's established non-fatal-
degradation pattern (`skill_version_check_safe`/`persist_offset_safe`).
A genuinely missing/unreadable `Changes` file still returns `undef`
silently, with no diagnostic - only a readable file with no matching
entry is covered.
INVESTIGATE (TGT-187): a
live user report (budget project) observed a version-bump restart
notice missing TGT-112's own Changes-line summary. Traced
`Developer::Dashboard::SkillDispatcher`'s own `_skill_env`/`dispatch`/
`exec_command` (a real `d2 tg.<command>` dispatch sets
`DEVELOPER_DASHBOARD_SKILL_ROOT` before launching the skill command -
`dispatch` via `local %ENV = (%ENV, %env)` scoped to the block that
runs its own `system()` call; `exec_command` via a non-local
`%ENV = (%ENV, %env)`
right before its own final `exec` - both persist for the whole
resulting process's lifetime, including a later `exec()`-based
self-restart, which inherits the calling process's environment by
default) and confirmed
`changes_summary` correctly returns the summary when `.env`'s
`VERSION` and the `Changes` file's own header entry match exactly -
confirmed both in a `developer-dashboard:latest` container and
independently on this host's own real, running installed poller (its
1.43->1.49 restart notice included the summary correctly).
`changes_summary` DOES silently return `undef` with zero
diagnostic on any mismatch (a missing entry, or even a trivial format
difference like a trailing `.0`) - a real, confirmable fragility, but
not independently reproducible against the current codebase for the
original report's own specific incident (version range 0.70-1.03 is
many versions and fixes behind). Closed a real, independently-found
test gap instead - `changes_summary`'s env-var-priority code path
had no test coverage at all until now. The silent-`undef`-on-any-
mismatch fragility itself was filed separately as **TGT-190** to add
a diagnostic, not fixed here.
BUG FIX (TGT-186, found via
a scheduled JOB-003 hourly bug hunt, reproduced live against
`cli/history.pl`): 7 more `cli/*.pl` scripts (`attachment`,
`text-only-replies`, `approve`, `retry-download`, `history`, `reply`,
`unread`) shared TGT-183's identical unwrapped `D2TG::Store->new`
crash - each constructed the store directly, so a storage-open failure
crashed the script raw, leaking the real db path. All 8 call sites
(these 7 plus `cli/poller.pl`'s own) built the same `db_path` shape and
the same overall eval/classify/refuse pattern - `cli/poller.pl` passes
`admin_chat_id` as an arrayref of every configured group's chat_id,
these 7 pass a plain scalar, not byte-identical args - so extracted
into a shared `D2TG::Poller::open_store_or_die` helper rather than
patching each one separately, matching this project's established
TGT-167/170/171/172/177 duplication-removal precedent.
`cli/poller.pl`'s own already-fixed inline version is deliberately
left untouched - its TGT-185 lock-release logic is intertwined with
that specific call site, not required scope.
BUG FIX (TGT-185, filed
from a Codex QA-stage review on TGT-184): `cli/poller.pl`'s
`D2TG::Store->new` failure exit (TGT-183) ran before releasing the
startup lock file, leaking it on that failure - fixed by releasing
the lock first, the same way TGT-184 already fixed the identical gap
on `heartbeat_path`'s own exit. The ticket's other originally-scoped
scenario (a "no groups configured" exit leaking the lock) turned out
to be unreachable dead code - two earlier startup guards already
refuse before that check can ever see an empty groups list - proven
and documented in the new test rather than faked. A second Codex
QA-stage review round on this fix then found two MORE reachable
exits sharing the same leak (a "no bot tokens configured" exit, and
an `exec()`-restart-failure `die`) - rather than patching a fourth
site individually, `cli/poller.pl` now has a single `END` block
right after `D2TG::Lock::acquire` succeeds that releases the lock on
every Perl-managed `exit`/uncaught `die` past that point - standard
Perl `END`-block behavior, it does NOT run if the process terminates
on an untrapped signal (`SIGKILL` always, or any signal this script
has not installed a handler for at that moment) - no claim is made
about exactly when `SIGTERM`/`SIGINT` become safe, only that an
untrapped signal bypasses `END`. `D2TG::Lock`'s own staleness/eviction
logic (TGT-084) is what recovers a lock left behind that way, on the
next poller start, not automatic eviction.
RELIABILITY FIX (TGT-184,
follow-up to TGT-183): `cli/poller.pl`'s `lock_path`/`heartbeat_path`
startup calls shared the identical unwrapped-`make_path` risk TGT-183
just fixed for `D2TG::Store->new` - both now wrapped and scrubbed the
same way. `lock_path`'s own failure is reproduced live and tested;
`heartbeat_path` is wrapped identically - its own failure isn't
independently exercised by the current test's static filesystem setup
(it succeeds once `lock_path` has already created `.tira`, though an
external filesystem change between the two calls could still make it
fail), not because it's impossible to test, just not covered by this
pass. A Codex QA-stage review on this ticket also caught that the
`heartbeat_path` failure branch exited before releasing the
just-acquired startup lock file - fixed by releasing it before that
exit. `D2TG::Store->new`'s own TGT-183 failure branch was found to
share the same lock-leak gap in the same review, filed separately as
**TGT-185**, not fixed here (TGT-185, shipped in 1.50, fixed it - see
above). A third exit path (no `--chat_id`/`--bot` groups configured)
was suspected of sharing the gap too at the time this entry was
written, but TGT-185's own investigation found it unreachable dead
code - it never runs with the lock held, so there was nothing to fix
there.
RELIABILITY FIX (TGT-183,
found via a scheduled hourly bug hunt, reproduced live): `cli/poller.pl`'s
`D2TG::Store->new(...)` startup call was unwrapped - a storage-open
failure at that specific step (e.g. a colliding db-file path, a
read-only mount) crashed the poller with a raw, uncaught Perl
exception that could embed the real db path, instead of the clean,
scrubbed refusal `require_existing_base_dir`/`D2TG::Lock::acquire`
already produce for their own failures. Now wrapped and classified,
matching TGT-133's own established scrubbing precedent. Two earlier
startup steps (`lock_path`/`heartbeat_path`) shared the same unwrapped-
`make_path` risk - fixed subsequently as TGT-184 (see above), not
fixed by this entry itself.
REFACTOR (TGT-182, found via
a scheduled improvement hunt): `send_voice` and `_send_file` (backing
`send_photo`/`send_document`) duplicated the identical 5-line multipart
`reply_to_message_id` field-construction block - extracted into a new
`_append_reply_to_message_id_field` helper. No behavior change -
existing tests (`t/32-message-id-and-reply-threading.t`,
`t/79-outbound-media-send.t`, `t/49-send-message-validates-reply-id.t`)
all pass unchanged.
REFACTOR (TGT-181, found via
a scheduled improvement hunt): `run_once`'s 2-line
`_record_message_safe` + `$offset_cap` bookkeeping pattern (introduced
by TGT-178) was duplicated identically at all 5 call sites - extracted
into a new `_record_message_and_track_offset` helper. No behavior
change - `t/178-offset-cap-on-record-failure.t` and
`t/100-poller-record-message-eval.t` both pass unchanged.
REFACTOR (TGT-177, found via
a scheduled improvement hunt): 10 `cli/*.pl` scripts each duplicated
the identical `eval { extract_db_flag } / print STDERR $@ / exit 1`
boilerplate - extracted into `D2TG::Config::extract_db_flag_or_die`,
matching the existing `resolve_alias_dir_or_die` convention. No
behavior change - same exit code, same STDERR text, same return shape
for every caller.
RELIABILITY FIX (TGT-179,
found via a scheduled hourly bug hunt, reproduced live via a stalled
FIFO): `D2TG::Transcribe::_probe_duration`'s `ffprobe` call had no
timeout at all - a hang there blocked the ENTIRE single-threaded
poller indefinitely for every chat. Now guarded by a `waitpid`-poll
timeout matching this module's own established pattern for whisper,
rather than a plain `alarm()`-around-a-blocking-readline (which does
NOT reliably interrupt a buffered pipe read). A timed-out probe falls
back to 0 duration exactly like every other probe failure mode already
did.
RELIABILITY FIX (TGT-178,
implementing Michael's own Q-011 ruling on the TGT-176 message-loss
investigation): a local `record_message` write failure used to let the
poller's offset advance past that update anyway, and Telegram never
redelivers an update once the offset has moved past it - a genuine
store write failure (locked/busy/readonly database) permanently and
silently lost that message's local history. The offset is now capped
at the failing update so Telegram redelivers it (and everything after
it in the same batch) next cycle, with a dedupe check so an
already-recorded update isn't re-announced on redelivery.
RELIABILITY FIX (TGT-175,
live production incident reported via the budget project): the
poller's main-loop version-change check crashed the ENTIRE process if
`.env` was transiently missing/unreadable during the skill's own
self-update - killed the owner's Telegram channel for about a minute.
Now non-fatal, matching `persist_offset_safe`'s own degradation
pattern; the poller's startup version check is unaffected and still
refuses to start loudly.
DOC FIX (TGT-174, found via a
scheduled doc-accuracy hunt immediately after TGT-173 shipped):
`D2TG::Download`'s POD still linked to its own now-removed
`_with_hard_timeout` instead of `D2TG::Config`'s - fixed. Doc-only, no
code/behavior change.
REFACTOR (TGT-173, found via
a scheduled improvement hunt): `D2TG::Telegram` and `D2TG::Download`
each independently implemented the identical SIGALRM-based
`_with_hard_timeout` wrapper - extracted into a shared helper in
`D2TG::Config`, each call site passing its own exact die-message prefix
so wording is unchanged. No behavioral change (verified via a
before/after full-suite diff and 100% statement+subroutine coverage on
all 3 touched modules).
REFACTOR (TGT-172, found via
a scheduled improvement hunt): 11 of the 13 `cli/*.pl` scripts each
duplicated the same 4-line error-handling block after calling
`D2TG::Config::resolve_alias_dir` - extracted into a shared
`resolve_alias_dir_or_die` helper, no behavioral change (verified via a
before/after full-suite diff and 100% statement+subroutine coverage on
`D2TG::Config.pm`, including a new dedicated test to close a coverage
gap left by subprocess-run cli scripts).
REFACTOR (TGT-171, found via
a scheduled improvement hunt): `D2TG::Telegram`'s `reply_to_message_id`
numeric-validation block was triplicated across `send_message`,
`send_voice`, and `_send_file` (only the method name in the die
message differed) - extracted into a shared
`_validate_reply_to_message_id` helper, no behavioral change (verified
via a before/after full-suite diff with no behavioral test changes -
Files=130, Tests=1254 both times - and 100% statement+subroutine
coverage on `D2TG::Telegram.pm`).
REFACTOR (TGT-170, found via
a scheduled improvement hunt): `D2TG::Poller`'s forward-attribution
formatting (from TGT-142) was the same four-line logic duplicated at
two call sites (the main message branch and `_reply_context_suffix`'s
replied-to-message handling - only the variable name differed) -
extracted into a shared `_format_forwarded_sender` helper, no
behavioral change (verified via a before/after full-suite diff with no
behavioral test changes - Files=130, Tests=1254 both times - and 100%
coverage on `D2TG::Poller.pm`).
FEATURE (TGT-169, live
Telegram question from Michael): message EDITS are now detected and
announced (`NEW TG EDIT`; a text edit's new content also updates
`d2 tg.history`, a caption/media-only edit is announced but not
recorded) - Telegram sends a distinct `edited_message` update for
this. Message DELETIONS of an ordinary chat message remain impossible
to detect - a hard Bot API limitation, not a gap here.
REFACTOR (TGT-167, found via
a scheduled improvement hunt): `_record_message_safe` and TGT-166's new
`persist_offset_safe` duplicated the identical store-error
classification ternary - extracted into a shared `_classify_store_error`
helper, no behavior change (verified via a before/after full-suite
diff with zero assertion changes).
BUG FIX (TGT-166, found via
a direct follow-up sweep after TGT-165): `cli/poller.pl`'s persistent
main loop called `set_offset` unwrapped - a locked database used to
crash the entire poller process, not just one poll cycle, since this
call sits outside `run_once_safe`'s own protection. Extracted into a
new, directly unit-tested `D2TG::Poller::persist_offset_safe` that
catches the error and keeps the poller running instead.
BUG FIX (TGT-165, found via
a scheduled hourly bug hunt): `run_once`'s `is_allowed`/`add_pending`
calls had no eval wrapper, unlike every `record_message` call site
(TGT-132) - a locked SQLite database could die there, aborting the
whole poll batch and causing it to be redelivered and reprinted
verbatim on the next cycle. Both call sites now catch the error and
skip that one update non-fatally instead.
BUG FIX (TGT-164, found via
a scheduled bug hunt): D2TG_CHAT_ID's canonical-shape validation
(TGT-155) was silently bypassed whenever the CLI also declared its own
`--chat_id` group (TGT-049's multi-bot support) - a malformed env
value became a broken extra poll group instead of being refused. Now
validated in that branch too, whenever D2TG_CHAT_ID is actually set.
TEST COVERAGE (TGT-163,
found via a scheduled improvement hunt): 9 of the 12 `cli/*.pl` scripts
with a Usage string had no test guarding it against their own POD SYNOPSIS -
the same drift class caught 3 times before (TGT-119/157/159). New
parity tests added for all 9; writing them caught a real drift in
`cli/history.pl`'s POD (missing the `-d` shorthand), now fixed.
SECURITY HARDENING (TGT-162,
found via a scheduled hourly bug hunt): `D2TG::Telegram::_send_file`'s
caption field was spliced into the multipart body with no sanitization,
unlike the adjacent filename field which got hardening for TGT-125 - a
caption embedding the exact per-call multipart boundary string in
delimiter syntax could have prematurely terminated the body. The
boundary substring is now conservatively stripped from the caption
before insertion, closing that gap.
BUG FIX (TGT-161, found via a
scheduled hourly bug hunt): a video message (no plain text, no
recognized media kind) was previously silently dropped by the poller -
not printed, not queued pending, not recorded - `_media_kind` now also
recognizes `video`, so it is announced and recorded exactly like an
undownloaded photo/document already is. Video download support itself,
and the same failure class for video_note/audio/animation/sticker,
remain out of scope, deliberately deferred.
RELIABILITY FIX (TGT-160,
found via a scheduled hourly bug hunt): a routine Telegram `429` rate-
limit response was previously logged as a genuine `POLL ERROR` on the
monitored stream instead of being silently retried like a 5xx/timeout
already is - `is_transient_error` now classifies it the same way.
DOC/CONSISTENCY FIX (TGT-159,
found via a scheduled improvement hunt, a systematic `cli/*.pl` sweep
after TGT-157 found the same pattern once already): `cli/approve.pl`'s
own STDERR Usage string was missing `--bot <token>` - correctly
documented in the same file's own POD SYNOPSIS but drifted apart; a new
POD-parity test now guards it the same way an existing one already
guards `cli/reply.pl`. Every other `cli/*.pl` script was checked in the
same sweep and found already correct. Test refactor (TGT-158, found
via a scheduled improvement hunt): `D2TG::Reply::send_reply` and
`resend_voice` no longer duplicate the same synthesize/send/cleanup
sequence - extracted into a shared `_synthesize_and_send_voice` helper,
each caller's own distinct post-success ordering left untouched. Zero
behavior change - the full existing D2TG::Reply behavioral test suite
passes with no assertion changed. DOC/CONSISTENCY FIX (TGT-157,
found via a scheduled improvement hunt): `cli/reply.pl`'s own STDERR
Usage string was missing `--db`/`-d`, `--bot`, and `--voice-only` -
correctly documented in the same file's own POD SYNOPSIS but drifted
apart over time; a new POD-parity test now guards this the same way an
existing one already guards `cli/poller.pl`. SECURITY/RELIABILITY FIX
(TGT-155, found via a scheduled hourly bug hunt): a non-canonical
`D2TG_CHAT_ID` - whitespace-only, or leading/trailing whitespace around
an otherwise-valid id (a copy-paste error, a shell quoting mistake) -
previously passed the startup guard and let the poller start, silently
seeding that mangled value as the admin's chat id; Telegram's real
numeric chat id can never string-eq match it, so the real owner was
permanently locked out with zero warning. The guard now validates the
full expected shape (bare digits, or a leading `-` for a
group/supergroup/channel) rather than merely excluding known-bad
shapes. BUG FIX (TGT-154, found via a
scheduled hourly bug hunt): an anonymous channel/chat reaction (Telegram
omits `MessageReactionUpdated`'s `user` field entirely and supplies
`actor_chat` instead) previously printed `sender: unknown` even though
Telegram had supplied the channel's real name - the sender resolution
now reads `actor_chat.title`/`.username` when present, same failure
class TGT-142 already fixed once for forwarded messages. Test-only
refactor (TGT-153,
found via a scheduled improvement hunt): a shared `t/lib/Fake/UA.pm`
test double now replaces 5 independently-reinvented copies of the same
outbound-HTTP test fake across 5 test files (md5sum identified two
exact-duplicate clusters before extraction, the remaining difference
inspected by hand) - a sixth pair of files sharing the same package name
was found to be a genuinely different, unrelated fake and deliberately
left untouched rather than forced into the same module. No
user-facing behavior change, zero production code touched. SECURITY FIX (TGT-151, found
via a scheduled hourly bug hunt): message reactions (see TGT-143 below)
now go through the same `is_allowed` access-control gate every other
inbound event uses - previously an unapproved, non-pending chat_id's
reaction was printed unconditionally, leaking its chat_id/username onto
the monitored stream and letting an unapproved party interact with the
bot in a way the rest of this codebase explicitly designs against.
`d2 tg.unread` now refuses on
an unrecognized flag or leftover argument (TGT-149, found via a
scheduled bug hunt) instead of silently ignoring it, matching every
sibling command in this project's own established convention
(`d2 tg.status`, `d2 tg.history`, `d2 tg.whoami`,
`d2 tg.text-only-replies`). Doc fix (TGT-148, found via a
scheduled doc-accuracy hunt): `D2TG::Config::heartbeat_age`'s own POD
still claimed the old fixed 1200s staleness threshold TGT-147 (below)
replaced - the one doc location that ticket's own documentation gate
missed, now corrected. `d2 tg.status`'s staleness
threshold no longer falsely flags a healthy, still-transcribing poller
(TGT-147, a real regression found via a scheduled bug hunt - this
session's own earlier TGT-140 changed the transcription timeout it
depended on, up to 3 hours worst case, without updating the 20-minute
threshold that assumed the old, much shorter bound) - now derived
directly from `D2TG::Transcribe`'s own constants instead of a re-typed
literal. Internal refactor (TGT-144,
found via a scheduled improvement hunt): the duplicated subprocess-
launch preambles `D2TG::TTS::_run` and `D2TG::Transcribe::_run` had
each independently accumulated are now one shared, tested
implementation (`D2TG::Subprocess`) - no user-facing behavior change,
all pre-existing tests pass unchanged. One narrow, never-observed
internal detail was reconciled rather than literally preserved per
caller: `D2TG::Transcribe::_run` previously exited 127 for both a
devnull-redirect failure and an exec failure, while `D2TG::TTS::_run`
distinguished them (126 vs 127) - the shared helper now uses TTS's
richer distinction for both callers, since neither module's own exit
code is ever inspected beyond "did it fail" by anything in this
project. Message reactions (emoji
likes) are now detected and printed (TGT-143, answering a live question
from Michael) - `NEW TG REACTION [chat_id] sender: <emoji> on message
<id>` for an add, `REACTION REMOVED ...` for a removal, diffed by
emoji so a same-update swap (one emoji replaced by another) reports
both correctly. Detection only, no reply action taken on a reaction. A forwarded message now names
its original sender alongside the forwarder (TGT-142, answering a live
question from Michael) - reads Telegram's own `forward_origin` field,
already reaching the poller untouched but never read before, covering
all 4 origin types (a real user, a privacy-restricted user, a chat, or
a channel). The orphaned-poller warning
now cross-checks a flagged process's own bot token before sounding
urgent (TGT-141, an external review finding live-reproduced by a
sibling project) - a same-token match still gets the urgent framing, a
different or unreadable token gets a reassuring note naming a sibling
project's own poller as the likely explanation instead, closing a
routine false alarm on any host running several projects from this
skill. `d2 tg.retry-download`'s own
`RETRY OK` success line no longer prints a retried download's real local
filesystem path (TGT-146, a TGT-133 regression found via a scheduled bug
hunt) - names the `d2 tg.attachment` fetch command instead, matching
every other successful-download line's own never-expose-the-real-path
convention. `D2TG::Config::write_heartbeat`
no longer leaks its staging temp file when `rename()` fails (TGT-139) -
previously a failed heartbeat write left `$path.tmp.$$` behind, and every
subsequent failed attempt added another orphaned file to the state
directory. Voice-note transcription's hard
timeout now scales with the same duration signal that already picks the
Whisper model (TGT-140, external review finding confirmed live by
Michael) - previously it stayed a flat 300s constant even after
duration-tiered model selection shipped, so a clip on its own tier's real
throughput could still be killed purely for taking longer than 300s
wall-clock (measured: a 102.48s clip took 571s on `medium`, already past
the old ceiling). The scaled budget is never smaller than the flat
default and is capped at 3600s (or the flat default itself, whichever is
larger - a caller-configured default is never undercut by the cap
either); an explicitly-passed model keeps the flat default unchanged.
`D2TG::Config::masked_token`'s
short-token fallback (<8 chars) no longer returns the raw value - a
fixed, non-revealing placeholder instead (TGT-138). docs/commands.md now has a
worked example of the NEW TG MEDIA + GET ATTACHMENT WITH flow (TGT-136)
instead of only separate prose. SKILLS.md's onboarding
overview now names `d2 tg.attachment` explicitly (TGT-135) - previously
only the later step-by-step walkthrough mentioned it. `d2 tg.attachment`'s refusal
for a missing stored file now names `prune_vault`'s own byte-cap
eviction as the likely cause (TGT-134, self-review after TGT-133) -
fetching an attachment is only reliable while it's still within the
vault's retained set, not a permanent guarantee, now documented
explicitly. `D2TG::Poller::run_once`'s 4
`record_message` calls are now eval-wrapped (TGT-132, found via an
ad-hoc bug-hunt) - a store write failure mid-batch (SQLite contention
outlasting TGT-129's own busy_timeout) no longer aborts the rest of
the poll batch, which previously caused it to be entirely redelivered
and reprinted next cycle, risking a duplicate reply from the watching
agent. A downloaded attachment's real
local filesystem path is never exposed anywhere agent-facing any more
(TGT-133, live Telegram request) - matching this project's own Tira
board convention (`tira.attachment.get` writes raw content to stdout,
never a path). New `d2 tg.attachment <chat_id> <message_id>` command
writes a stored attachment's raw bytes to stdout (reads the whole file into memory first, then prints it once - fine at Telegram's own 20MB getFile cap, not true chunked streaming); the poller and
`d2 tg.history`/`d2 tg.unread` now advise that command instead of ever
printing the real path, one instruction per attachment.
`D2TG::Transcribe::kill_current`
now signals the whole process group, not just the direct pid (TGT-131,
found via an ad-hoc bug-hunt) - a clean poller shutdown mid-
transcription now reaches any child the whisper process itself spawned,
matching the process-group protection `_run`'s own timeout path already had (TGT-128).
SKILLS.md's `cli/*.pl` file
list is current again (TGT-130, found via an ad-hoc bug-hunt) -
`cli/tts.pl` had been missing since it shipped after TGT-123's own fix
to this same list; a new regression test now guards against this
recurring silently a third time. `D2TG::Store` now sets SQLite's
`PRAGMA busy_timeout`/`journal_mode = WAL` on every connection (TGT-129,
found via an ad-hoc bug-hunt) - previously a concurrent writer (the
poller vs. an independently-invoked `d2 tg.*` command against the same
database) could fail immediately with a locked-database error instead
of briefly waiting, the concurrency robustness this project's own
research notes on the original Python blueprint had flagged as worth
keeping. `D2TG::Transcribe::_run`'s
whisper subprocess now has the same process-group protection (TGT-128,
found via an ad-hoc bug-hunt immediately after TGT-127) - a timeout
signals the whole process group, not just the immediate whisper
process, so any child process whisper itself spawns (e.g. for audio
decoding) is terminated too, not left orphaned. `D2TG::TTS::_run`'s gtts-cli/
ffmpeg calls (used by every outbound voice reply) are now protected by a
SIGALRM hard timeout too (TGT-127, found via an ad-hoc bug-hunt
immediately after TGT-126) - a hung external command now dies with a
clear timeout message and has its whole process group killed, instead of
wedging the reply path forever with no bound at all (a bare `system()`
call had even less protection than the LWP-based paths already fixed).
`D2TG::Download::download_file`'s
HTTP GET (fetches inbound photo/document/voice bytes) is now protected
by the same SIGALRM-based hard timeout `D2TG::Telegram`'s Bot API calls
already use (TGT-126, found via an ad-hoc bug-hunt - the same failure
class as a real prior incident, TGT-044, where a connection stuck in
TCP `connect()` wedged the poller indefinitely, immune even to
`SIGTERM`) - a hung download now dies with a clear timeout message
instead of blocking the whole poll cycle forever. `d2 tg.send`'s outbound photo/
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
