# tg — onboarding runbook

**Status: early implementation (v0.92).** This file is a procedure to
follow, start to finish, when installing this skill for a new user - not
a changelog. For the full command/event reference (once running), see
`docs/commands.md`; for the operational rules it follows, see
`docs/POLICIES.md`; for ticket-level status, see this project's Tira
board ("D2 TG Skill"), not markdown files in `tickets/`.

## 1. What this skill is

`tg` is a Telegram bridge for a Developer Dashboard project. Once
running, it long-polls a Telegram bot, gates every sender through an
allow-list, and prints new messages (text, voice - transcribed, photo/
document - downloaded) to stdout with a ready-to-run reply command
alongside each one. Registered as a Tira monitor job, that stream
reaches the project's `tira.policy.bridge`, so the agent watching that
board sees new Telegram messages as board notifications and can reply
via `d2 tg.reply <chat_id> "..."` - a real text message plus a spoken
voice note, always both. The text is sent first, then the voice note is
synthesized and sent (TGT-083); a synthesis/send failure after that point
is still reported loudly (non-zero exit) but can no longer un-send the
text half. If just the voice half fails, `d2 tg.reply --voice-only
<chat_id> "..."` (TGT-109) resends only the voice note - it never calls
`send_message`, so it can't duplicate the text that already went out.
`d2 tg.send <chat_id> <file_path>` (TGT-103) pushes a local file back as
a photo or document, the outbound counterpart to inbound media (which
already worked fully). `d2 tg.status` (TGT-111) reports the installed
version and whether the poller is currently alive, without reaching into
Tira job metadata from outside - and also its heartbeat age, flagged
stale past 20 minutes (TGT-116), since "alive" and "still genuinely
cycling" turned out to be different questions after a real 80+ minute
silent-message-loss incident. `d2 tg.poller` also warns on stderr if it
detects another live process whose command line looks like a poller
instance (TGT-113) - a real incident where a poller
crashed mid-restart, left an orphaned second instance running under a
different PID, and nothing noticed it was still competing for the same
bot token's `getUpdates` queue. This is a report, not a kill - a cmdline
pattern match alone isn't strong enough evidence for this skill to act
on unprompted. A failed inbound photo/document download is now queued
for retry (TGT-104, an attempt to persist, not a guarantee - a
database-write failure at queue time is itself non-fatal and simply
leaves that one download unqueued) instead of just printed and
forgotten - `d2 tg.retry-download` lists and retries it later using the
same Telegram `file_id` to request a fresh download; a retry Telegram
itself reports as permanently gone (not merely a transient hiccup) gets
a distinguishable `RETRY EXPIRED` message rather than the same generic
failure text an ordinary, still-retryable failure gets. A reply that
went out text-only - TGT-083's own send-text-then-voice ordering means a
late voice failure can leave one behind, always reported loudly at the
time but easy to miss - is now flagged for later discovery too (TGT-105)
via `d2 tg.text-only-replies`, scoped per configured bot the same way
access control already is. `d2 tg.reply` now also refuses to send the
exact same text to the same chat twice within a short window (TGT-114)
- an accidentally re-run reply command, or a retry after a confirmed
prior success whose voice half then failed, no longer delivers the same
message a second time. `d2 tg.whoami` (TGT-115) prints the masked
token, chat_id, and resolved storage location for a quick sanity check
- no network call, safe to run at any time, useful with multiple
projects on one host each running their own installed copy of this
skill.

## 2. Prep before install

Collect these before starting:

1. **A Telegram bot token.** Message `@BotFather` on Telegram, run
   `/newbot`, follow its prompts. It returns a token that looks like
   `123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA`. This becomes
   `D2TG_TOKEN`.
2. **The admin chat id.** The Telegram user id of the person this bot
   should treat as its owner/admin (auto-allow-listed, never queued for
   approval). If unknown, message the new bot anything once and check
   `dashboard tg.poller`'s stdout the first time it runs (unset
   `D2TG_CHAT_ID` first - see step 4 below) - or ask the user directly
   for their Telegram numeric user id (e.g. via `@userinfobot`). This
   becomes `D2TG_CHAT_ID`.
3. **`ffmpeg`** — installs automatically (`aptfile`) as part of step 3
   below on Debian-like hosts. Check with `which ffmpeg` if unsure.
4. **`gtts-cli`** (`pip install --user gTTS`, or `--break-system-packages`
   on PEP-668-enforced hosts like current Debian/Ubuntu) — required for
   the voice half of every `d2 tg.reply`. Not yet automatic (TGT-025):
   `dashboard`'s own `requirements.txt` installer aborts the whole skill
   install on PEP-668 hosts, so this stays a manual step for now. Check
   with `which gtts-cli`.
5. **A local `whisper` install** (`pip install --user openai-whisper`,
   same PEP-668 caveat) with a multilingual (non `*.en`) model, if
   inbound voice-note transcription is wanted. Check with `which
   whisper`. Not required for text-only inbound traffic.

## 3. Install

```
dashboard skills install tg
```

Once installed, `d2 tg.help` prints this file and the full command
reference (`docs/commands.md`) - useful any time an agent needs to
re-learn how this skill works without re-reading this repo directly.

## 4. Config the agent must collect before first use

After install, the skill has no working config yet. Before running
`d2 tg.poller` for real, the agent must have obtained from the user (or
directly from step 2 above) and exported:

```
export D2TG_TOKEN="<the bot token from step 2.1>"
export D2TG_CHAT_ID="<the admin chat id from step 2.2>"
export D2TG_DB="<a Developer Dashboard path alias - run 'd2 paths' to see the choices>"
export D2TG_OWNER="<optional: a friendly display name for the admin, e.g. 'Michael'>"
```

`D2TG_OWNER` is optional (TGT-079) - when set, the poller shows this
name instead of the admin's raw Telegram username, for messages from
`D2TG_CHAT_ID` only. Purely cosmetic; leave it unset to see the
Telegram username as before.

Without `D2TG_CHAT_ID` set, `d2 tg.poller` refuses to start and prints a
warning to stderr - this is a deliberate hard guard, not a bug. If the
admin chat id is not yet known, run the poller once with `D2TG_TOKEN`
set and `D2TG_CHAT_ID` unset/empty; it will still refuse to start, but
the guard's own warning confirms the token itself is wired correctly.
To actually discover an unknown chat id, message the bot from the
intended admin's Telegram account and read the id off the Bot API's
`getUpdates` response (or `@userinfobot`) before setting `D2TG_CHAT_ID`
and restarting.

Without `D2TG_DB` (or `--db <alias>`/`-d <alias>` passed to any `d2
tg.*` command instead) set, every `d2 tg.*` command refuses to start the
same way, printing which flag/env var is missing and pointing at `d2
paths` (TGT-059) - this is deliberate and mandatory, not an optional
convenience: it names which Developer Dashboard path alias (the left
column of `d2 paths`) the skill's SQLite state and downloaded
attachments live under, so a fresh install is never left silently
writing state into the skill's own install directory. If `TIRA_HOME` is
set, it's used as this base directory instead of refusing (TGT-081) -
only when none of `--db`/`-d`/`D2TG_DB` was given at all - and is itself
resolved as a `d2 paths` alias first (TGT-091: e.g. `TIRA_HOME=tira-zen`
resolves via whatever `tira-zen` names in `d2 paths`), falling back to
using its value as a literal filesystem path only if it matches no
alias. Whichever directory is resolved, state and attachments live
under a `.tira/` subdirectory of it: `.tira/telegram.messages.db` and
`.tira/attachments/` (TGT-081). That resolved base directory must
already exist - it is purely looked up, never created (TGT-090); if it
doesn't exist, every `d2 tg.*` command refuses to start rather than
`mkdir`-ing it into existence.

## 5. End-to-end onboarding test (agent ↔ user ↔ Telegram)

Do this for real, not as a described-but-unrun procedure - each step
names what to do and exactly what confirms it worked.

1. **Start the poller.** With all three env vars set, run `d2 tg.poller` in a
   terminal you can watch (foreground, or `d2 exec` if this session
   drives it). Expect: `d2tg poller starting up (token: <first
   4>...<last 4>) (chat_id: <chat_id>)` (TGT-045) on stdout - confirm the
   masked token and chat_id match what you expect, not a stale value
   from another terminal/project - then nothing further until a message
   arrives.
2. **Ask the user to send a real Telegram message** to the bot from
   their own phone/account (the one matching `D2TG_CHAT_ID`) - plain
   text is enough for the first pass, e.g. "hello from onboarding test".
3. **Confirm it arrives.** Expect two new stdout lines within the
   poller's poll cycle:
   ```
   [<timestamp>] NEW TG [<chat_id>] <username>: hello from onboarding test (msg #<message_id>)
   REPLY WITH: d2 tg.reply <chat_id> "..." --reply-to-message-id <message_id>
   ```
   `[<timestamp>]` (TGT-061) is Telegram's own received-time, not local
   wall-clock time. `(msg #<message_id>)` and `--reply-to-message-id
   <message_id>` (TGT-040) are always present - Telegram always assigns
   every message an id. If
   nothing appears within ~30s, check `D2TG_TOKEN` is the right bot's
   token and that the user actually messaged that bot (not a different
   one).
4. **Send a reply.** Compose real text and run (in a second terminal,
   the poller keeps running) - copy the exact `REPLY WITH` line printed
   in step 3 and fill in your own text, or send a fresh unthreaded reply
   by omitting `--reply-to-message-id`:
   ```
   d2 tg.reply <chat_id> "onboarding test received, reply is working" --reply-to-message-id <message_id>
   ```
   Expect: `Replied to <chat_id>` and exit 0.
5. **Confirm the user received it.** Ask the user to check Telegram:
   they should see BOTH a text message and a voice note reading the
   same text, in that order. If only text arrived, or nothing arrived,
   `d2 tg.reply` would have already exited non-zero with an error - this
   is not a silent-failure design (see `docs/POLICIES.md`).
6. **Optional: exercise voice and media.** Ask the user to send a voice
   note and a photo. Expect `NEW TG VOICE [...]: <transcript> (msg
   #<message_id>)` (needs local `whisper`, step 2.5) and `NEW TG MEDIA
   [...]: photo <local_path> (msg #<message_id>)` respectively, each
   followed by its own `REPLY WITH` line (with `--reply-to-message-id`
   filled in).
7. **Stop the test poller** (`Ctrl-C` / `SIGTERM`) once steps 3-5 have
   both been confirmed by the user. **Onboarding is successful once
   this whole loop - real message in, real reply out, user confirms
   both - has actually happened once, not merely been read.**

## 6. Register as a Tira monitor job

Once onboarding (section 5) has succeeded, stop running the poller by
hand and register it as a Tira monitor job on the **user's own project
board** (not necessarily this skill's own dev board) so it runs
continuously and its output reaches that board's bridge:

```
d2 tira.policy.add --rule monitor-output --action bridge-reminder   # once per board, skip if already declared
d2 tira.job.add --schedule monitor --command "d2 tg.poller"
d2 tira.job.start --id JOB-NNN   # use the id tira.job.add just printed
```

Have the user note the printed `JOB-NNN` id - it's needed for
`tira.job.stop`/`tira.job.list` later. What to expect once started:

- `dashboard tira.job.list -o json` shows that job with a `pid` and
  `last_output_at` once at least one message has been processed.
- New Telegram messages appear as `monitor-output` events on
  `dashboard tira.policy.bridge` - the same `NEW TG .../REPLY WITH`
  lines from section 5, now flowing through the board instead of a
  terminal.
- No systemd unit, no crontab entry is created or needed anywhere - this
  is deliberate (Q-003).
- If the monitor job restarts `d2 tg.poller` while a previous instance is
  still alive, the new instance takes over automatically (TGT-084 -
  "last one wins": it kills the still-live previous instance rather than
  failing to acquire the lock and looping on
  `D2TG::Lock: could not acquire ... - contended for too long`).
- The poller's own version-triggered self-restart re-acquires its own
  lock without ever briefly dropping it (TGT-102, found via a scheduled
  bug-hunt) - closing a narrow window where an independently-started
  second poller could otherwise mistake the mid-restart lock churn for a
  genuine conflict and kill the legitimately restarting instance.
- `d2 tg.poller --help`/`-h` prints usage and exits, and any other
  unrecognized flag refuses with a clear error naming it - both checked
  before the lock is ever touched (TGT-107, a live-experienced incident:
  a `--help` typo used to be silently accepted and start a real second
  poller, which the "last one wins" rule above then let kill the
  legitimate one).

This exact wiring was verified live in a `developer-dashboard:latest`
container (TGT-015).

## Implementation reference

Module-by-module and per-ticket implementation detail (which file
implements what, exact function signatures) lives in the POD of each
`lib/D2TG/*.pm` module and in `docs/commands.md`'s command/event
reference - not here. This file stays a procedure, not a changelog.

The poller's own automatic version-change restart (see section 6) is now
resilient to an install renaming its own entrypoint file mid-run
(TGT-094, live production incident) - it re-resolves its current
`poller.pl` path fresh at restart time rather than trusting a path
captured at launch.

Every `cli/*` entrypoint file carries a `.pl` extension internally
(`cli/poller.pl`, `cli/reply.pl`, `cli/approve.pl`, `cli/unread.pl`,
`cli/history.pl`, `cli/help.pl` - TGT-093). This is purely a source-tree
naming convention and does not change how you run the skill: `d2
tg.<command>` (e.g. `d2 tg.poller`) dispatches exactly as documented
above, because Developer Dashboard's `SkillDispatcher` already tries a
`.pl` fallback for an extensionless command name, confirmed empirically
in a `tira:latest` container before the rename shipped.
