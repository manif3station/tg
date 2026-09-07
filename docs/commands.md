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
- `NEW TG MEDIA [chat_id] sender: <photo|document> <local_path>` — an
  allowed sender's photo/document message, downloaded to `local_path`.
  For a photo, the largest available resolution is downloaded.
- `NEW TG VOICE [chat_id] sender: <transcript>` — an allowed sender's
  voice message, downloaded and transcribed via a local Whisper install
  (the downloaded audio itself is not kept, only its transcript).
- `TRANSCRIBE ERROR [chat_id] sender: <message>` (stderr) — a voice
  message's download or transcription failed; the poller keeps running.
- `MEDIA DOWNLOAD ERROR [chat_id] sender: <message>` (stderr) — a
  photo/document message's download failed; the poller keeps running.
- `NEW TG PENDING [chat_id] awaiting approval` — printed once, the first
  time a non-allow-listed chat id sends anything.
- `REPLY WITH: d2 tg.reply <chat_id> "..."` — printed immediately after
  every content line above (text/voice-transcript/media, never after the
  pending notification or an error line): a ready-to-run reply command
  template with the chat id already filled in, per Q-004. This is only
  ever a template — the poller never sends a reply itself.

Requires a local `whisper` install (a multilingual, non `.en` model) for
voice transcription. No extra dependency is needed for photo/document
download - it reuses the same `D2TG::Download` module.

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

## Module reference

Full behavior/signature detail lives in each module's own POD
(`perldoc lib/D2TG/<Name>.pm`); this is a one-line-each map of what's
implemented and where:

| Module | What it does |
| --- | --- |
| `D2TG::Config` | Reads `D2TG_TOKEN`/`D2TG_CHAT_ID`; startup guard; resolves `state/store.sqlite`'s path. |
| `D2TG::Telegram` | Raw HTTP Bot API client (`HTTP::Tiny`, no SDK): `get_me`, `get_updates`, `get_file`, `file_download_url`, `send_message` (auto-split), `send_voice` (multipart). |
| `D2TG::Poller` | `run_once` — one poll cycle: access-control gate, text/voice/media event lines, the `REPLY WITH` template, non-fatal error handling for voice/media. |
| `D2TG::Store` | SQLite-backed allow-list/pending/offset persistence; `approve` is atomic and rolls back cleanly on any failure. |
| `D2TG::TTS` | `synthesize` — text → gTTS → ffmpeg → Ogg/Opus, fatal on failure. |
| `D2TG::Reply` | `send_reply` — voice sent first, text only after voice succeeds; never text-only. |
| `D2TG::Download` | `download_file` — any Telegram `file_id` → local temp file. |
| `D2TG::Transcribe` | `transcribe` — local `whisper` CLI, refuses `*.en` models. |

`cli/poller`, `cli/approve`, `cli/reply` are the thin `d2 tg.*`
entrypoints described above; each just wires the relevant modules
together.

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
