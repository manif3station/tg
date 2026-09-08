# tg

**Status: early implementation (v0.67).** `d2 tg.poller` runs for real —
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
is downloaded to a local file and its path printed. Either kind of
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
