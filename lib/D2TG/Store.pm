package D2TG::Store;

use strict;
use warnings;
use DBI;
use Digest::SHA qw(sha256_hex);
use D2TG::Store::RetryQueue;
use D2TG::Store::History;

# TGT-101: the single-bot/unscoped sentinel for allow_list/pending's
# bot_key column (TGT-098) - named once here rather than repeated as a
# bare '' literal at every call site.
use constant DEFAULT_BOT_KEY => '';

# TGT-235: the default age cap for prune_history, mirroring
# D2TG::Download::prune_vault's own named-constant-default pattern.
use constant DEFAULT_RETENTION_DAYS => 90;

# TGT-238: a separate, shorter default for failed_downloads/
# failed_transcriptions - these are retry queues, not history, so a
# permanently-unretryable row (an expired file_id, say) should stop
# cluttering d2 tg.unread's own listing well before a legitimate
# message would age out of history.
use constant DEFAULT_FAILED_QUEUE_RETENTION_DAYS => 30;

sub new {
    my ( $class, %args ) = @_;

    my $db_path = $args{db_path} or die "D2TG::Store->new requires db_path\n";

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path", '', '',
        { RaiseError => 1, AutoCommit => 1, sqlite_use_immediate_transaction => 1 }
    );

    # TGT-129: without these, DBD::SQLite's default busy timeout is 0 -
    # a concurrent writer (the long-running poller vs. an independently
    # invoked d2 tg.reply/approve/retry-download etc. against the same
    # db_path) gets an immediate "database is locked" error instead of
    # a brief, usually-successful wait. WAL also lets readers and a
    # writer proceed without blocking each other at all in the common
    # case; busy_timeout covers the remaining writer-vs-writer window.
    $dbh->do('PRAGMA busy_timeout = 5000');
    $dbh->do('PRAGMA journal_mode = WAL');

    my $self = bless { dbh => $dbh }, $class;
    $self->_ensure_schema;

    # TGT-257: failed_downloads/failed_transcriptions storage now lives
    # in D2TG::Store::RetryQueue - built once here and reused by every
    # forwarding method below, same $dbh, no behavior change for any
    # existing caller.
    $self->{retry_queue} = D2TG::Store::RetryQueue->new( dbh => $dbh );

    # TGT-278: message-history storage now lives in D2TG::Store::History
    # - built once here and reused by every forwarding method below,
    # same $dbh, no behavior change for any existing caller, mirroring
    # TGT-257's own retry_queue precedent above.
    $self->{history} = D2TG::Store::History->new( dbh => $dbh );

    if ( defined $args{admin_chat_id} ) {
        my @ids = ref $args{admin_chat_id} eq 'ARRAY' ? @{ $args{admin_chat_id} } : ( $args{admin_chat_id} );
        for my $id (@ids) {
            if ( ref $id eq 'HASH' ) {
                $self->_seed_admin( $id->{chat_id}, $id->{bot_key} );
            }
            else {
                $self->_seed_admin($id);
            }
        }
    }

    return $self;
}

sub _ensure_schema {
    my ($self) = @_;

    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS allow_list (
             chat_id INTEGER NOT NULL,
             bot_key TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
             PRIMARY KEY (chat_id, bot_key)
         )'
    );
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS pending (
             chat_id INTEGER NOT NULL,
             bot_key TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
             PRIMARY KEY (chat_id, bot_key)
         )'
    );
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)'
    );
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS messages (
             chat_id    INTEGER NOT NULL,
             message_id INTEGER NOT NULL,
             sender     TEXT,
             summary    TEXT,
             created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             PRIMARY KEY (chat_id, message_id)
         )'
    );


    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE messages ADD COLUMN read_at TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-133: the real on-disk path of a downloaded attachment lives
    # only here, never in `summary` (which is what cli/history.pl and
    # cli/unread.pl print verbatim) - kept separate so the path can
    # never leak through display output, only through
    # get_attachment_path's own deliberate, narrow accessor.
    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE messages ADD COLUMN local_path TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-232 (found via a scheduled JOB-004 improvement hunt): the
    # messages table was the one remaining per-chat table never given
    # the bot_key treatment TGT-098/219 already applied elsewhere -
    # keyed only on (chat_id, message_id). Telegram's own message_id is
    # a per-bot counter (TGT-063), so two different bots sharing a
    # chat_id can legitimately produce colliding (chat_id, message_id)
    # pairs, which record_message's own unscoped ON CONFLICT silently
    # collapsed into one row. Same rename/create/copy/drop migration
    # TGT-098/219 already established, run inside one transaction so a
    # crash mid-migration can never orphan the old data - runs AFTER
    # the read_at/local_path ALTER blocks above so an existing
    # installation's own already-added columns are preserved in the
    # copy (matching TGT-219's own precedent of copying local_path).
    # Existing rows migrate to bot_key='' (the single-bot/unscoped
    # sentinel).
    {
        my $cols = $self->{dbh}->selectall_arrayref( 'PRAGMA table_info(messages)', { Slice => {} } );
        if ( !grep { $_->{name} eq 'bot_key' } @$cols ) {
            $self->{dbh}->begin_work;
            eval {
                $self->{dbh}->do('ALTER TABLE messages RENAME TO messages_pre_tgt232');
                $self->{dbh}->do(
                    'CREATE TABLE messages (
                         chat_id    INTEGER NOT NULL,
                         bot_key    TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
                         message_id INTEGER NOT NULL,
                         sender     TEXT,
                         summary    TEXT,
                         created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                         read_at    TEXT,
                         local_path TEXT,
                         PRIMARY KEY (chat_id, bot_key, message_id)
                     )'
                );
                $self->{dbh}->do(
                    'INSERT INTO messages (chat_id, bot_key, message_id, sender, summary, created_at, read_at, local_path)
                     SELECT chat_id, \'' . DEFAULT_BOT_KEY . '\', message_id, sender, summary, created_at, read_at, local_path
                     FROM messages_pre_tgt232'
                );
                $self->{dbh}->do('DROP TABLE messages_pre_tgt232');
                $self->{dbh}->commit;
            };
            if ($@) {
                my $error = $@;
                eval { $self->{dbh}->rollback };
                die $error;
            }
        }
    }

    # TGT-104: a failed inbound photo/document download used to be
    # reported once (a MEDIA DOWNLOAD ERROR line) and forgotten - no way
    # to retry it later. This table persists what's needed to retry
    # (which message, which Telegram
    # file_id, why it failed) AND what's needed to fully restore the
    # message into history on a successful retry (sender, media_kind,
    # caption_note) - a Codex review caught that a retry success
    # originally only removed the queue row, leaving nothing in
    # D2TG::Store's own messages table the way a first-time success
    # already does via record_message.
    #
    # UNIQUE(chat_id, message_id): Telegram's own delivery is
    # at-least-once - if the poller crashes after recording a failure
    # but before its offset advances, the identical update is
    # reprocessed and would otherwise insert a duplicate queue row for
    # the same failed media (another Codex review finding). A single
    # INSERT ... ON CONFLICT DO UPDATE (record_failed_download below)
    # collapses redelivery into refreshing the existing row instead.
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS failed_downloads (
             id           INTEGER PRIMARY KEY AUTOINCREMENT,
             chat_id      INTEGER NOT NULL,
             message_id   INTEGER NOT NULL,
             file_id      TEXT NOT NULL,
             sender       TEXT,
             media_kind   TEXT,
             caption_note TEXT,
             error        TEXT,
             created_at   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             UNIQUE (chat_id, message_id)
         )'
    );

    # TGT-196 (Michael's own design choice, Q-013, answering a Codex
    # documentation-stage review finding on TGT-194): a persistently-
    # failing record_message used to re-download the same already-
    # fetched file on every retry pass, wasting bandwidth and Telegram
    # API calls forever with no escape hatch. NULL here means "not yet
    # downloaded" (today's ordinary queued state); once download_file
    # succeeds but the bookkeeping record_message write then fails,
    # retry_failed_download persists the path here - a future retry
    # sees it, skips download_file entirely, and retries only the
    # record_message write against the already-downloaded file.
    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE failed_downloads ADD COLUMN local_path TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-219 (found via a scheduled JOB-004 improvement hunt):
    # failed_downloads was the sole per-chat table never given the
    # bot_key treatment TGT-098 already applied to allow_list/pending -
    # keyed only on (chat_id, message_id), so the same message_id
    # failing under two different bots in a multi-bot config collapsed
    # into one row via record_failed_download's own ON CONFLICT clause,
    # and Telegram's own file_id values are bot-token-scoped, so a
    # retry using the wrong bot's token can never succeed. A UNIQUE
    # constraint change can't be done via ALTER TABLE in SQLite, so
    # this is the same rename/create/copy/drop migration TGT-098
    # already established for allow_list/pending, run inside one
    # transaction so a crash mid-migration can never orphan the old
    # data. Existing rows migrate to bot_key='' (the single-bot/
    # unscoped sentinel), matching every sibling table's own migration.
    {
        my $cols = $self->{dbh}->selectall_arrayref( 'PRAGMA table_info(failed_downloads)', { Slice => {} } );
        if ( !grep { $_->{name} eq 'bot_key' } @$cols ) {
            $self->{dbh}->begin_work;
            eval {
                $self->{dbh}->do('ALTER TABLE failed_downloads RENAME TO failed_downloads_pre_tgt219');
                $self->{dbh}->do(
                    'CREATE TABLE failed_downloads (
                         id           INTEGER PRIMARY KEY AUTOINCREMENT,
                         chat_id      INTEGER NOT NULL,
                         bot_key      TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
                         message_id   INTEGER NOT NULL,
                         file_id      TEXT NOT NULL,
                         sender       TEXT,
                         media_kind   TEXT,
                         caption_note TEXT,
                         error        TEXT,
                         created_at   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                         local_path   TEXT,
                         UNIQUE (chat_id, bot_key, message_id)
                     )'
                );
                $self->{dbh}->do(
                    'INSERT INTO failed_downloads
                         (id, chat_id, bot_key, message_id, file_id, sender, media_kind, caption_note, error, created_at, local_path)
                     SELECT id, chat_id, \'' . DEFAULT_BOT_KEY . '\', message_id, file_id, sender, media_kind, caption_note, error, created_at, local_path
                     FROM failed_downloads_pre_tgt219'
                );
                $self->{dbh}->do('DROP TABLE failed_downloads_pre_tgt219');
                $self->{dbh}->commit;
            };
            if ($@) {
                my $error = $@;
                eval { $self->{dbh}->rollback };
                die $error;
            }
        }
    }

    # TGT-221 (Q-015 answered by Michael: retry every 60s for up to 5
    # minutes total): NULL means "never auto-retried yet" - the same
    # duplicate-tolerant ALTER TABLE pattern local_path above already
    # established. Placed AFTER the TGT-219 migration block above (not
    # before, like local_path is) - that migration's own CREATE TABLE
    # only lists the columns it explicitly knows about, so an earlier
    # placement would have this column silently dropped by the
    # rename/create/copy/drop on every fresh database (caught before
    # this ticket shipped, not after). Set by
    # mark_failed_download_retried after each automatic retry attempt
    # (success or failure); read by failed_downloads_due_for_retry to
    # decide whether 60s have elapsed since the last attempt.
    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE failed_downloads ADD COLUMN last_retry_at TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-237: mirrors failed_downloads' own shape, but a fresh table
    # created with bot_key from the start (unlike failed_downloads,
    # which needed TGT-219's own rename/create/copy/drop migration to
    # retrofit it) - no local_path/caption_note equivalent, since a
    # transcription failure's transient download is always unlinked
    # immediately (never lands in the shared attachments vault) and
    # there is no caption for a voice message.
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS failed_transcriptions (
             id         INTEGER PRIMARY KEY AUTOINCREMENT,
             chat_id    INTEGER NOT NULL,
             bot_key    TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
             message_id INTEGER NOT NULL,
             file_id    TEXT NOT NULL,
             sender     TEXT,
             error      TEXT,
             created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             UNIQUE (chat_id, bot_key, message_id)
         )'
    );

    # TGT-246 (found via a scheduled JOB-003 hourly bug hunt): mirrors
    # failed_downloads' own last_retry_at column (added by TGT-221) -
    # NULL means "never auto-retried yet". Placed as a duplicate-
    # tolerant ALTER TABLE right after this fresh CREATE TABLE, the same
    # pattern local_path used for failed_downloads - failed_transcriptions
    # has no rename/create/copy/drop migration block of its own (unlike
    # failed_downloads' TGT-219 migration) to worry about ordering
    # against, so a plain trailing ALTER TABLE is safe here.
    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE failed_transcriptions ADD COLUMN last_retry_at TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-105: TGT-083 deliberately reordered D2TG::Reply::send_reply to
    # send text first, then synthesize+send voice - a synthesis/
    # send_voice failure after that point can leave a reply text-only,
    # always reported loudly (non-zero exit) AT SEND TIME. If that loud
    # failure is missed, nothing previously let a later check catch the
    # resulting text-only reply. voice_message_id starts NULL when the
    # text send is recorded and is filled in only once the voice send
    # also succeeds - a row with a still-NULL voice_message_id IS the
    # text-only flag, not a separate boolean to keep in sync.
    #
    # bot_key (Codex review finding): the same TGT-098/TGT-101 lesson
    # applies here - a Telegram group shared by more than one of this
    # skill's configured bots means chat_id alone isn't a unique key
    # across bots. Without this, one bot's --voice-only recovery could
    # select and clear a DIFFERENT bot's still-genuinely-text-only flag
    # for the same chat_id, and the flag would misreport across bots.
    # TGT-114: also stores the reply's own text (`text` column) so
    # D2TG::Store::is_recent_duplicate_reply can check whether the same
    # text was already sent to the same chat/bot within a short window -
    # closing a real gap where a retried or accidentally-re-run reply
    # command could deliver the identical message twice.
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS sent_replies (
             chat_id          INTEGER NOT NULL,
             bot_key          TEXT NOT NULL DEFAULT \'' . DEFAULT_BOT_KEY . '\',
             text_message_id  INTEGER NOT NULL,
             voice_message_id INTEGER,
             created_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             PRIMARY KEY (chat_id, bot_key, text_message_id)
         )'
    );

    # TGT-114, Codex review finding (also matches a bug-hunt observation
    # flagged earlier this session): CREATE TABLE IF NOT EXISTS above is
    # a no-op against a database that already has sent_replies from a
    # prior install of TGT-105 alone, without this column - the exact
    # same ALTER-with-duplicate-tolerance pattern messages.read_at
    # already uses above.
    {
        local $self->{dbh}{PrintError} = 0;
        eval { $self->{dbh}->do('ALTER TABLE sent_replies ADD COLUMN text TEXT') };
    }
    die $@ if $@ && $@ !~ /duplicate column name/;

    # TGT-098 (bug-hunt finding): allow_list/pending used to be keyed
    # only by chat_id (a single-column PRIMARY KEY), which silently let
    # an approval leak across bots for a Telegram group shared by more
    # than one of this skill's configured bots (a group's chat_id is
    # the same for every bot, unlike a private chat's). A PRIMARY KEY
    # change can't be done via ALTER TABLE in SQLite, so a
    # pre-migration table (no bot_key column, detected via PRAGMA
    # table_info - the CREATE TABLE IF NOT EXISTS above is a no-op
    # against an existing old-shape table) is rebuilt: renamed aside,
    # replaced with the new composite-PK shape, every existing row
    # copied across with bot_key='' (the single-bot/unscoped sentinel -
    # not SQL NULL, since SQLite's uniqueness checks don't treat two
    # NULLs as equal, which would silently defeat this exact PRIMARY
    # KEY), old table dropped - the whole rename/create/copy/drop
    # sequence wrapped in one transaction so a failure partway through
    # can never orphan the old data in a renamed-aside table while a
    # fresh, empty new-shape table silently appears on the next run
    # instead of the failure being noticed.
    for my $table (qw(allow_list pending)) {
        my $cols = $self->{dbh}->selectall_arrayref( "PRAGMA table_info($table)", { Slice => {} } );
        next if grep { $_->{name} eq 'bot_key' } @$cols;

        # Wrapped in a transaction (SQLite DDL is transactional) so a
        # crash mid-migration can never leave the old data orphaned in a
        # renamed-aside table while a fresh, empty new-shape table gets
        # silently created on the next run instead of being noticed.
        $self->{dbh}->begin_work;
        eval {
            $self->{dbh}->do("ALTER TABLE $table RENAME TO ${table}_pre_tgt098");
            $self->{dbh}->do(
                "CREATE TABLE $table (
                     chat_id INTEGER NOT NULL,
                     bot_key TEXT NOT NULL DEFAULT '" . DEFAULT_BOT_KEY . "',
                     PRIMARY KEY (chat_id, bot_key)
                 )"
            );
            $self->{dbh}->do( "INSERT INTO $table (chat_id, bot_key) SELECT chat_id, '"
                  . DEFAULT_BOT_KEY
                  . "' FROM ${table}_pre_tgt098" );
            $self->{dbh}->do("DROP TABLE ${table}_pre_tgt098");
            $self->{dbh}->commit;
        };
        if ($@) {
            my $error = $@;
            eval { $self->{dbh}->rollback };
            die $error;
        }
    }

    return;
}

sub _seed_admin {
    my ( $self, $admin_chat_id, $bot_key ) = @_;
    $bot_key = DEFAULT_BOT_KEY unless defined $bot_key;

    $self->{dbh}->do(
        'INSERT OR IGNORE INTO allow_list (chat_id, bot_key) VALUES (?, ?)',
        undef, $admin_chat_id, $bot_key,
    );

    return;
}

sub is_allowed {
    my ( $self, $chat_id, $bot_key ) = @_;
    $bot_key = DEFAULT_BOT_KEY unless defined $bot_key;

    my ($found) = $self->{dbh}->selectrow_array(
        'SELECT 1 FROM allow_list WHERE chat_id = ? AND bot_key = ?', undef, $chat_id, $bot_key,
    );

    return $found ? 1 : 0;
}

sub add_pending {
    my ( $self, $chat_id, $bot_key ) = @_;
    $bot_key = DEFAULT_BOT_KEY unless defined $bot_key;

    my $inserted = $self->{dbh}->do(
        'INSERT OR IGNORE INTO pending (chat_id, bot_key) VALUES (?, ?)',
        undef, $chat_id, $bot_key,
    );

    return $inserted && $inserted ne '0E0' ? 1 : 0;
}

sub approve {
    my ( $self, $chat_id, $bot_key ) = @_;
    $bot_key = DEFAULT_BOT_KEY unless defined $bot_key;

    my $dbh = $self->{dbh};

    $dbh->begin_work;

    my $result = eval {
        my $deleted = $dbh->do(
            'DELETE FROM pending WHERE chat_id = ? AND bot_key = ?', undef, $chat_id, $bot_key,
        );

        if ( $deleted == 0 ) {
            $dbh->rollback;
            return 0;
        }

        $dbh->do(
            'INSERT OR IGNORE INTO allow_list (chat_id, bot_key) VALUES (?, ?)',
            undef, $chat_id, $bot_key,
        );
        $dbh->commit;
        return 1;
    };
    my $error = $@;

    if ($error) {
        eval { $dbh->rollback };
        die $error;
    }

    return $result;
}

sub _offset_meta_key {
    my ($bot_key) = @_;
    return 'offset' unless defined $bot_key;
    return 'offset:' . sha256_hex($bot_key);
}

sub get_offset {
    my ( $self, $bot_key ) = @_;

    my ($value) = $self->{dbh}->selectrow_array(
        'SELECT value FROM meta WHERE key = ?', undef, _offset_meta_key($bot_key),
    );

    return defined $value ? $value : undef;
}

sub set_offset {
    my ( $self, $offset, $bot_key ) = @_;

    $self->{dbh}->do(
        'INSERT INTO meta (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        undef, _offset_meta_key($bot_key), $offset,
    );

    return;
}

sub pending_chat_ids {
    my ( $self, %args ) = @_;

    # TGT-215 (found via a scheduled JOB-004 improvement hunt): the sole
    # pending/allow_list accessor never updated for TGT-098's bot_key
    # migration - added an optional bot_key filter matching every
    # sibling accessor's own established pattern. The unscoped case
    # deliberately keeps its existing flat chat_id-list return shape
    # (t/05-access-control.t/t/06-approve.t/t/111-reaction-access-
    # control.t all depend on it) - only adding DISTINCT so a chat_id
    # pending under multiple bots is never listed more than once.
    if ( defined $args{bot_key} ) {
        my $rows = $self->{dbh}->selectcol_arrayref(
            'SELECT chat_id FROM pending WHERE bot_key = ? ORDER BY chat_id',
            undef, $args{bot_key},
        );
        return @$rows;
    }

    my $rows = $self->{dbh}->selectcol_arrayref(
        'SELECT DISTINCT chat_id FROM pending ORDER BY chat_id'
    );

    return @$rows;
}

# TGT-278: message-history storage moved into D2TG::Store::History
# (built once in new() above, sharing this same $dbh) - these eight
# methods are now thin forwarders so every existing caller keeps
# working unchanged via $store->method_name(...), mirroring TGT-257's
# own retry_queue forwarders below. See D2TG::Store::History's own POD
# for the full behavior each one documents.
sub record_message      { my $self = shift; return $self->{history}->record_message(@_) }
sub get_message          { my $self = shift; return $self->{history}->get_message(@_) }
sub get_attachment_path  { my $self = shift; return $self->{history}->get_attachment_path(@_) }
sub mark_read            { my $self = shift; return $self->{history}->mark_read(@_) }
sub is_read              { my $self = shift; return $self->{history}->is_read(@_) }
sub unread_messages      { my $self = shift; return $self->{history}->unread_messages(@_) }
sub recent_messages      { my $self = shift; return $self->{history}->recent_messages(@_) }
sub messages_in_range    { my $self = shift; return $self->{history}->messages_in_range(@_) }

# TGT-257: failed_downloads/failed_transcriptions storage moved into
# D2TG::Store::RetryQueue (built once in new() above, sharing this same
# $dbh) - these ten methods are now thin forwarders so every existing
# caller (cli/retry-download.pl, cli/unread.pl, cli/poller.pl,
# D2TG::Download, D2TG::Transcribe, and their tests) keeps working
# unchanged via $store->method_name(...). See D2TG::Store::RetryQueue's
# own POD for the full behavior each one documents.
sub record_failed_download          { my $self = shift; return $self->{retry_queue}->record_failed_download(@_) }
sub failed_downloads                { my $self = shift; return $self->{retry_queue}->failed_downloads(@_) }
sub failed_downloads_due_for_retry  { my $self = shift; return $self->{retry_queue}->failed_downloads_due_for_retry(@_) }
sub mark_failed_download_retried    { my $self = shift; return $self->{retry_queue}->mark_failed_download_retried(@_) }
sub remove_failed_download          { my $self = shift; return $self->{retry_queue}->remove_failed_download(@_) }
sub mark_failed_download_downloaded { my $self = shift; return $self->{retry_queue}->mark_failed_download_downloaded(@_) }
sub has_failed_download              { my $self = shift; return $self->{retry_queue}->has_failed_download(@_) }
sub record_failed_transcription         { my $self = shift; return $self->{retry_queue}->record_failed_transcription(@_) }
sub failed_transcriptions               { my $self = shift; return $self->{retry_queue}->failed_transcriptions(@_) }
sub remove_failed_transcription         { my $self = shift; return $self->{retry_queue}->remove_failed_transcription(@_) }
sub failed_transcriptions_due_for_retry { my $self = shift; return $self->{retry_queue}->failed_transcriptions_due_for_retry(@_) }
sub mark_failed_transcription_retried   { my $self = shift; return $self->{retry_queue}->mark_failed_transcription_retried(@_) }
sub has_failed_transcription            { my $self = shift; return $self->{retry_queue}->has_failed_transcription(@_) }

sub record_sent_text {
    my ( $self, $chat_id, $text_message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    # INSERT OR IGNORE: a redundant re-record of the same (chat_id,
    # bot_key, text_message_id) - e.g. a retried send_reply call after a
    # prior partial failure - must never clobber a voice_message_id
    # already recorded for it back to NULL.
    $self->{dbh}->do(
        'INSERT OR IGNORE INTO sent_replies (chat_id, bot_key, text_message_id, text) VALUES (?, ?, ?, ?)',
        undef, $chat_id, $bot_key, $text_message_id, $args{text},
    );

    return;
}

sub record_sent_voice {
    my ( $self, $chat_id, $text_message_id, $voice_message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $rows = $self->{dbh}->do(
        'UPDATE sent_replies SET voice_message_id = ? WHERE chat_id = ? AND bot_key = ? AND text_message_id = ?',
        undef, $voice_message_id, $chat_id, $bot_key, $text_message_id,
    );

    # Codex review finding: a matching text row not existing (a
    # bot_key mismatch, or the text row itself never got recorded -
    # e.g. a crash between send_message succeeding and record_sent_text
    # running) used to be a silent no-op, hiding exactly the kind of
    # persistence gap this feature exists to surface. Not fatal - the
    # voice send itself already succeeded and must not be undone or
    # treated as a failure - but worth a loud note rather than silence.
    warn "D2TG::Store::record_sent_voice: no matching sent_replies row for "
      . "chat_id=$chat_id bot_key='$bot_key' text_message_id=$text_message_id "
      . "- voice sent but the text-only audit trail could not be updated\n"
      if !$rows || $rows eq '0E0';

    return;
}

sub text_only_replies {
    my ( $self, %args ) = @_;

    # bot_key (Codex review finding): optional filter, so a caller that
    # needs to act on exactly one bot's own flags (cli/reply.pl
    # --voice-only, so it never selects and clears a DIFFERENT bot's
    # flag for the same chat_id) can scope the query; omitting it lists
    # every bot's flagged replies, each row naming its own bot_key, for
    # a human operator auditing the whole board.
    if ( defined $args{bot_key} ) {
        return $self->{dbh}->selectall_arrayref(
            'SELECT chat_id, bot_key, text_message_id, created_at FROM sent_replies
             WHERE voice_message_id IS NULL AND bot_key = ? ORDER BY chat_id, text_message_id',
            { Slice => {} }, $args{bot_key},
        );
    }

    return $self->{dbh}->selectall_arrayref(
        'SELECT chat_id, bot_key, text_message_id, created_at FROM sent_replies
         WHERE voice_message_id IS NULL ORDER BY chat_id, bot_key, text_message_id',
        { Slice => {} }
    );
}

sub is_recent_duplicate_reply {
    my ( $self, $chat_id, $text, %args ) = @_;
    my $bot_key        = $args{bot_key}        // DEFAULT_BOT_KEY;
    my $window_seconds = $args{window_seconds} // 10;

    # Codex review finding: a negative window_seconds silently builds a
    # nonsensical SQLite modifier ("--10 seconds") that would otherwise
    # make the comparison behave unpredictably rather than obviously
    # wrong. A non-numeric value is rejected the same way.
    die "D2TG::Store::is_recent_duplicate_reply: window_seconds must be a non-negative number\n"
      unless $window_seconds =~ /^\d+(?:\.\d+)?$/;

    my $row = $self->{dbh}->selectrow_hashref(
        "SELECT 1 FROM sent_replies
         WHERE chat_id = ? AND bot_key = ? AND text = ?
           AND created_at >= datetime('now', ?)
         LIMIT 1",
        undef, $chat_id, $bot_key, $text, "-$window_seconds seconds",
    );

    return $row ? 1 : 0;
}

# TGT-235: unlike D2TG::Download::prune_vault, which already caps the
# attachments vault's own disk usage by byte count, the messages and
# sent_replies tables had no retention/eviction policy at all - every
# row was kept forever. Mirrors prune_vault's own pattern: an
# age-based cap, silent no-op when nothing is past the window,
# configurable via an optional argument with a sane default.
sub prune_history {
    my ( $self, %args ) = @_;
    my $days = $args{retention_days} // DEFAULT_RETENTION_DAYS;

    $self->{dbh}->do(
        "DELETE FROM messages WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$days days",
    );
    $self->{dbh}->do(
        "DELETE FROM sent_replies WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$days days",
    );

    # TGT-238: failed_downloads/failed_transcriptions are pure retry
    # queues with no other eviction path - a row is removed only by a
    # successful retry, so a permanently-unretryable row (an expired
    # Telegram file_id, say) would otherwise sit forever. A separate
    # (shorter) default window from messages/sent_replies above, since
    # this is about not cluttering a retry queue, not history retention.
    my $failed_queue_days = $args{failed_queue_retention_days} // DEFAULT_FAILED_QUEUE_RETENTION_DAYS;

    $self->{dbh}->do(
        "DELETE FROM failed_downloads WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$failed_queue_days days",
    );
    $self->{dbh}->do(
        "DELETE FROM failed_transcriptions WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$failed_queue_days days",
    );

    return;
}

sub disconnect {
    my ($self) = @_;

    $self->{dbh}->disconnect;

    return;
}

1;
