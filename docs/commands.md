# tg — command reference

All commands are dispatched via Developer Dashboard as `d2 tg.<name>`
(the `cli/<name>` script in this repo).

## `d2 tg.poller`

Starts the long-poll loop. Refuses to start (warning to STDERR, exit 1)
if `D2TG_CHAT_ID` is not set. Runs until `SIGTERM`/`SIGINT`. Prints one
line per event to **stdout** (`NEW TG ...`), one line per error to
**stderr** — no log file. Meant to run as a Tira monitor-kind job, not
under systemd or cron.

Events printed:

- `NEW TG [chat_id] sender: text` — an allowed sender's text message.
- `NEW TG MEDIA [chat_id] sender: <photo|document>` — an allowed
  sender's photo/document message (not yet downloaded).
- `NEW TG VOICE [chat_id] sender: <transcript>` — an allowed sender's
  voice message, downloaded and transcribed via a local Whisper install.
- `TRANSCRIBE ERROR [chat_id] sender: <message>` (stderr) — a voice
  message's download or transcription failed; the poller keeps running.
- `NEW TG PENDING [chat_id] awaiting approval` — printed once, the first
  time a non-allow-listed chat id sends anything.

Requires a local `whisper` install (a multilingual, non `.en` model) for
voice transcription.

## `d2 tg.approve <chat_id>`

Moves `chat_id` from pending into the allow-list. Prints `Approved N`
and exits 0 on success. Exits 1 (message on STDERR) if `chat_id` was
already allowed, or was never pending at all.

## `d2 tg.reply <chat_id> <text...>`

Sends `text` to `chat_id` as **both** a text message and a gTTS voice
note — never text-only. If speech synthesis (`gtts-cli` then `ffmpeg`)
fails for any reason, the command dies before sending anything at all;
there is no partial/degraded reply. Text longer than 4000 UTF-16 code
units is split across multiple `sendMessage` calls without ever breaking
a single character (a supplementary-plane character, which is a UTF-16
surrogate pair, is always kept in one chunk).

Requires `gtts-cli` and `ffmpeg` to be installed on the machine running
this command.

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
