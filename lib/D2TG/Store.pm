package D2TG::Store;

use strict;
use warnings;
use DBI;
use Digest::SHA qw(sha256_hex);

# TGT-101: the single-bot/unscoped sentinel for allow_list/pending's
# bot_key column (TGT-098) - named once here rather than repeated as a
# bare '' literal at every call site.
use constant DEFAULT_BOT_KEY => '';

# TGT-235: the default age cap for prune_history, mirroring
# D2TG::Download::prune_vault's own named-constant-default pattern.
use constant DEFAULT_RETENTION_DAYS => 90;

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

sub record_message {
    my ( $self, $chat_id, $message_id, $sender, $summary, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    $self->{dbh}->do(
        'INSERT INTO messages (chat_id, bot_key, message_id, sender, summary, local_path) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(chat_id, bot_key, message_id) DO UPDATE SET sender = excluded.sender, summary = excluded.summary, local_path = COALESCE(excluded.local_path, messages.local_path)',
        undef, $chat_id, $bot_key, $message_id, $sender, $summary, $args{local_path},
    );

    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT sender, summary FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row;
}

sub get_attachment_path {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT local_path FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row ? $row->{local_path} : undef;
}

sub mark_read {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    $self->{dbh}->do(
        'UPDATE messages SET read_at = CURRENT_TIMESTAMP WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return;
}

sub is_read {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my ($read_at) = $self->{dbh}->selectrow_array(
        'SELECT read_at FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return defined $read_at ? 1 : 0;
}

sub unread_messages {
    my ( $self, %args ) = @_;

    my $sql  = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages WHERE read_at IS NULL';
    my @bind;
    if ( defined $args{bot_key} ) {
        $sql .= ' AND bot_key = ?';
        push @bind, $args{bot_key};
    }
    $sql .= ' ORDER BY created_at, message_id';

    my $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );

    return @$rows;
}

sub recent_messages {
    my ( $self, $limit, %args ) = @_;
    $limit //= 10;

    my $sql = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages';
    my @bind;
    if ( defined $args{bot_key} ) {
        $sql .= ' WHERE bot_key = ?';
        push @bind, $args{bot_key};
    }
    $sql .= ' ORDER BY created_at DESC, message_id DESC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );

    return @$rows;
}

sub messages_in_range {
    my ( $self, %args ) = @_;

    my @where;
    my @bind;

    if ( defined $args{bot_key} ) {
        push @where, 'bot_key = ?';
        push @bind,  $args{bot_key};
    }

    # TGT-214 (found via a scheduled JOB-003 hourly bug hunt, live-
    # verified): a plain string comparison against the raw --since/
    # --until value used to silently exclude same-day messages -
    # created_at is stored SQLite-CURRENT_TIMESTAMP-style, space-
    # separated ('2026-09-01 08:00:00'), but cli/history.pl's own
    # documented/TGT-209-validated form uses a 'T' separator
    # ('2026-09-01T00:00:00'); since 'T' (0x54) sorts after a space
    # (0x20), a since value with a time component compared greater
    # than every same-day row regardless of actual time-of-day.
    # SQLite's own datetime() normalizes any of its several accepted
    # input formats (date-only, space-separated, T-separated) to one
    # canonical form before comparing, so wrapping both sides in it
    # compares by real chronological value instead of raw string
    # ordering - deliberately applied to both the column and the bound
    # value, not just one side, so a canonical date-only value (which
    # datetime() expands to midnight) still compares correctly against
    # a full timestamp on either side of the comparison.
    if ( defined $args{since} ) {
        push @where, 'datetime(created_at) >= datetime(?)';
        push @bind,  $args{since};
    }
    if ( defined $args{until} ) {
        push @where, 'datetime(created_at) <= datetime(?)';
        push @bind,  $args{until};
    }

    my $sql = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages';
    $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
    $sql .= ' ORDER BY created_at, message_id';

    my $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );

    return @$rows;
}

sub record_failed_download {
    my ( $self, $chat_id, $message_id, $file_id, %args ) = @_;

    my ( $sender, $media_kind, $caption_note, $error ) =
      @args{qw(sender media_kind caption_note error)};
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    # ON CONFLICT (chat_id, bot_key, message_id) - TGT-219 added bot_key
    # to this key so the same message_id failing under two different
    # bots in a multi-bot config queues two independent rows, not one
    # collapsed into the other. Telegram's own at-least-once delivery
    # can still reprocess the same update under the SAME bot (e.g. the
    # poller crashes after this call but before its offset advances) -
    # that case still refreshes the existing row's file_id/error/
    # timestamp instead of inserting a second queue entry.
    $self->{dbh}->do(
        'INSERT INTO failed_downloads (chat_id, bot_key, message_id, file_id, sender, media_kind, caption_note, error)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(chat_id, bot_key, message_id) DO UPDATE SET
             file_id = excluded.file_id, sender = excluded.sender,
             media_kind = excluded.media_kind, caption_note = excluded.caption_note,
             error = excluded.error, created_at = CURRENT_TIMESTAMP',
        undef, $chat_id, $bot_key, $message_id, $file_id, $sender, $media_kind, $caption_note, $error,
    );

    # TGT-225 (found via a scheduled JOB-003 hourly bug hunt): this
    # id-lookup was never updated for TGT-219's own bot_key-scoped
    # UNIQUE constraint above - with two rows sharing (chat_id,
    # message_id) but different bot_key, an unscoped SELECT could
    # return either row's id at random (in practice, SQLite's own
    # insertion order), not necessarily the one just written here.
    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT id FROM failed_downloads WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row->{id};
}

sub failed_downloads {
    my ( $self, %args ) = @_;

    # TGT-219: optional bot_key filter, matching pending_chat_ids' own
    # established pattern - the unscoped case keeps its existing shape
    # (now also naming each row's own bot_key, so a caller can tell
    # which bot queued it even without filtering).
    if ( defined $args{bot_key} ) {
        return $self->{dbh}->selectall_arrayref(
            'SELECT id, chat_id, bot_key, message_id, file_id, sender, media_kind, caption_note, error, created_at, local_path
             FROM failed_downloads WHERE bot_key = ? ORDER BY id',
            { Slice => {} }, $args{bot_key},
        );
    }

    return $self->{dbh}->selectall_arrayref(
        'SELECT id, chat_id, bot_key, message_id, file_id, sender, media_kind, caption_note, error, created_at, local_path
         FROM failed_downloads ORDER BY id',
        { Slice => {} }
    );
}

sub remove_failed_download {
    my ( $self, $id ) = @_;

    $self->{dbh}->do( 'DELETE FROM failed_downloads WHERE id = ?', undef, $id );

    return;
}

# TGT-196: persists a queued row's own successfully-downloaded local
# path once download_file has already succeeded, so a future retry
# (D2TG::Download::retry_failed_download) can see it via failed_downloads
# and skip download_file entirely - retrying only the record_message
# write that's actually still failing, instead of re-fetching the same
# file from Telegram on every pass.
sub mark_failed_download_downloaded {
    my ( $self, $id, $local_path ) = @_;

    $self->{dbh}->do( 'UPDATE failed_downloads SET local_path = ? WHERE id = ?', undef, $local_path, $id );

    return;
}

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

    return;
}

sub disconnect {
    my ($self) = @_;

    $self->{dbh}->disconnect;

    return;
}

1;

=head1 NAME

D2TG::Store - allow-list / pending-approval storage for the tg skill

=head1 SYNOPSIS

    my $store = D2TG::Store->new( db_path => $path, admin_chat_id => $id );
    $store->is_allowed($chat_id);
    $store->add_pending($chat_id);
    $store->pending_chat_ids;

=head1 DESCRIPTION

SQLite-backed (via L<DBI>/L<DBD::SQLite>) allow-list and pending-approval
tables. Unlike the C<~/skills/tg> blueprint, there is no secret-phrase
owner bootstrap - C<admin_chat_id> (from C<D2TG_CHAT_ID>) is auto-seeded
into C<allow_list> on every C<new>, idempotently.

=head1 METHODS

=head2 new(db_path => $path, admin_chat_id => $id_or_arrayref)

Opens (creating if needed) the SQLite database at C<db_path>, ensures the
schema exists, and seeds C<admin_chat_id> into the allow-list if given.
C<admin_chat_id> may be a single scalar (unchanged from before) or an
arrayref of chat ids (TGT-049, for multi-group polling) - every id in
the arrayref is seeded allowed. As of TGT-234, an arrayref element may
also be a hashref C<{ chat_id => $id, bot_key => $token }> - each is
seeded under that specific C<bot_key> rather than the default sentinel,
which is what C<cli/poller.pl>'s own real multi-bot startup now does
(see L</_seed_admin> and L</is_allowed>) so the admin is auto-approved
under every bot it's actually configured to poll with, not only under
the single-bot default.

Every connection sets C<PRAGMA busy_timeout = 5000> and
C<PRAGMA journal_mode = WAL> immediately after connecting (TGT-129,
found via an ad-hoc bug-hunt): C<DBD::SQLite>'s default busy timeout is
C<0>, so a concurrent writer - the long-running poller writes on every
inbound message while other independently-invoked C<d2 tg.*> commands
(C<reply>, C<approve>, C<retry-download>) also write against the same
C<db_path> - previously got an immediate "database is locked" error
instead of a brief, usually-successful wait. WAL lets readers and a
writer proceed without blocking each other at all in the common case;
C<busy_timeout> bounds the remaining writer-vs-writer contention window
to a wait rather than an instant failure.

WAL mode creates C<db_path-wal>/C<db_path-shm> sidecar files alongside
C<db_path> while connections are active - any manual backup or copy of
the database file must include these too (a copy of C<db_path> alone can
miss recently-committed data still sitting in the WAL file, not yet
checkpointed back into the main file). WAL is appropriate for this
skill's single-host, local-filesystem usage; it is not suitable for a
database file shared over a network filesystem between hosts.

Ensuring the schema re-runs the C<messages> table's C<read_at> column
migration (TGT-046) on every call, which is expected to fail with
C<duplicate column name> on any database that's already been migrated -
that specific, already-handled case never reaches C<STDERR> (TGT-053,
C<PrintError> suppressed just for that one statement); a genuinely
different, unexpected failure still propagates via C<die> as before.
It also re-runs C<allow_list>/C<pending>'s C<bot_key> migration
(TGT-098) on every call, via C<PRAGMA table_info> detection rather than
a bare C<ALTER TABLE ... ADD COLUMN> - a C<PRIMARY KEY> change can't be
done that way in SQLite, so a pre-migration table (detected once, no
C<bot_key> column) is rebuilt: renamed aside, replaced with the new
composite-C<(chat_id, bot_key)>-PK shape, every row copied across with
C<bot_key=DEFAULT_BOT_KEY> (TGT-101 - a single named constant, still C<''>,
replacing 8 bare-literal occurrences that used to exist across this file -
the 2 CREATE TABLE DDL strings above, the migration block's own CREATE
TABLE/INSERT strings below, and 4 "unless defined" guards),
old table dropped, the whole sequence wrapped in one
transaction so a failure partway through rolls back to the untouched
original state (a genuine, testable concern for a rename/create/copy/drop
sequence, unlike the single-statement C<ADD COLUMN> migration above) -
re-opening after a failed attempt migrates cleanly from scratch rather
than working against a half-migrated table. Already-migrated databases
are a no-op (the C<PRAGMA> check finds C<bot_key> already present).

=head2 is_allowed($chat_id, $bot_key)

True if C<$chat_id> is in the allow-list under C<$bot_key> (TGT-098,
default C<DEFAULT_BOT_KEY> - the single-bot/unscoped sentinel, so every
existing caller that never passes C<$bot_key> is unaffected). A Telegram
group shared by more than one of this skill's configured bots has the same
C<$chat_id> for each - passing the actual bot's own key here is what
stops an approval granted under one bot from silently applying to
another.

=head2 add_pending($chat_id, $bot_key)

Records C<$chat_id> as pending approval under C<$bot_key> (TGT-098,
default C<DEFAULT_BOT_KEY>). Idempotent. Returns true the first time a
given C<($chat_id, $bot_key)> pair is recorded, false on every subsequent
call for the same pair (already pending) - this is what lets a caller
notify only once per new sender per bot.

=head2 approve($chat_id, $bot_key)

Moves C<($chat_id, $bot_key)> (TGT-098, default C<DEFAULT_BOT_KEY>) from
C<pending> to C<allow_list>, atomically. Returns true if it was genuinely pending
under that C<$bot_key> and is now approved; returns false (without
error) if it was not pending under that C<$bot_key> - already approved
under it, or never seen under it (a chat pending under a *different*
bot_key doesn't count). If anything inside the transaction throws (a
transient DB error), the transaction is always rolled back before the
error is re-thrown, so the Store's connection is never left in a
dangling open-transaction state - a subsequent C<approve> call on the
same object still works normally.

=head2 pending_chat_ids(bot_key => $bot_key)

Returns the list of chat ids currently pending, ordered. C<bot_key> is
optional (TGT-215, found via a scheduled improvement hunt, matching the
same optional-C<bot_key>-filter pattern every sibling accessor on this
table already uses) - when given, only that bot's pending chat ids are
returned. Omitting it returns every pending chat id regardless of bot,
C<DISTINCT> (a chat_id pending under more than one bot - the exact
scenario the C<pending> table's own composite C<PRIMARY KEY (chat_id,
bot_key)> exists to allow, TGT-098 - is listed exactly once, not once
per bot); this keeps the return shape unchanged from before this fix,
which only added C<DISTINCT> to close a genuine duplicate-row bug for
that case.

=head2 get_offset($bot_key)

Returns the persisted Telegram update offset, or C<undef> if none has
been saved yet. C<$bot_key> is optional (TGT-049, for multi-bot
polling, where each bot token has its own independent Telegram update
sequence) - typically the bot's own token. It is never stored in
plaintext: internally hashed (SHA256) into the storage key, so the live
credential never lands in the SQLite C<meta> table. Omitting it (single-
bot usage) is unchanged from before this ticket.

=head2 set_offset($offset, $bot_key)

Persists C<$offset>, overwriting any previously saved value for that
C<$bot_key> (see C<get_offset> above; omitting it is unchanged from
before TGT-049).

=head2 record_message($chat_id, $message_id, $sender, $summary, local_path => $optional_path, bot_key => $optional_bot_key)

Records a short summary of a processed message (TGT-038) against its own
C<chat_id>+C<message_id> - the message's own text for a text message, its
transcript for voice, or C<"<kind>"> (optionally C<"- caption: ...">) for
an already-downloaded photo/document. C<summary> must never itself
contain a real local filesystem path (TGT-133) - C<local_path> is stored
in a separate column instead, reachable only via L</get_attachment_path>,
so nothing that displays C<summary> (this module's own callers,
C<cli/history.pl>, C<cli/unread.pl>) can ever leak it. Idempotent:
recording the same C<chat_id>+C<bot_key>+C<message_id> again overwrites
the previous C<sender>/C<summary>; omitting C<local_path> on a re-record
preserves whichever one (if any) was already stored, rather than wiping
it - only an explicitly-given C<local_path> ever replaces the existing
one. C<bot_key> (TGT-232, found via a scheduled JOB-004 improvement
hunt) defaults to the single-bot sentinel, matching every sibling
per-chat table's own established pattern - Telegram's own C<message_id>
is a per-bot counter (TGT-063), so two bots sharing a C<chat_id> can
legitimately produce colliding C<(chat_id, message_id)> pairs; without
this, one bot's row could silently overwrite another's.

=head2 get_message($chat_id, $message_id, bot_key => $optional_bot_key)

Returns C<{ sender => ..., summary => ... }> for a previously recorded
message, or C<undef> if nothing was ever recorded for that
C<chat_id>+C<bot_key>+C<message_id>. Deliberately never includes
C<local_path> - see L</get_attachment_path>. C<bot_key> (TGT-232)
defaults to the single-bot sentinel.

=head2 get_attachment_path($chat_id, $message_id, bot_key => $optional_bot_key)

TGT-133: the only accessor that ever returns a downloaded attachment's
real local filesystem path - C<undef> if nothing was ever recorded, or
if it was recorded without one (a text/voice message, or a photo/
document recorded before this feature existed). Backs
C<cli/attachment.pl> exclusively; no other code path in this skill
should call it. C<bot_key> (TGT-232) defaults to the single-bot
sentinel.

=head2 mark_read($chat_id, $message_id, bot_key => $optional_bot_key)

Marks a previously recorded message read (TGT-046, stamps a
C<read_at> timestamp). A no-op (no error) if no row exists yet for that
C<chat_id>+C<bot_key>+C<message_id> - it simply updates zero rows.
C<bot_key> (TGT-232) defaults to the single-bot sentinel.

=head2 is_read($chat_id, $message_id, bot_key => $optional_bot_key)

Returns true if C<mark_read> has been called for that C<chat_id>+
C<bot_key>+C<message_id>, false otherwise - including when no row was
ever recorded for it at all (never dies on an unknown message).
C<bot_key> (TGT-232) defaults to the single-bot sentinel.

=head2 unread_messages(bot_key => $optional_bot_key)

Returns the list of all stored messages (TGT-047) not yet marked read
(C<mark_read>), as a list of hashrefs C<{ chat_id, message_id, sender,
summary, created_at }>, ordered oldest first - ties on C<created_at>
(two or more messages landing within the same second) are broken by
C<message_id> ascending (TGT-075, same reasoning C<recent_messages>
already applies in the opposite direction), so a same-second burst
never returns in SQLite's undefined tie-break order. Empty list if
there are none - never dies on an empty store. C<bot_key> (TGT-232) is
optional - omitting it lists every bot's own entries (matching
C<failed_downloads>'s own established convention), while passing one
scopes to that bot only.

=head2 recent_messages($limit = 10, bot_key => $optional_bot_key)

Returns the C<$limit> most recently recorded messages (TGT-048), newest
first, as a list of hashrefs C<{ chat_id, message_id, sender, summary,
created_at }>. Returns fewer than C<$limit> (down to none) without
error if the store has fewer rows than that. C<bot_key> (TGT-232) is
optional - omitting it considers every bot's own entries, matching
C<unread_messages>'s own convention.

=head2 messages_in_range(since => $iso8601, until => $iso8601, bot_key => $optional_bot_key)

Returns every stored message (TGT-048) with C<created_at> between
C<since> and C<until> inclusive, oldest first - same C<message_id>
same-second tiebreaker as L</unread_messages> (TGT-075). Either bound
may be omitted (an open-ended range on that side); omitting both
returns every stored message, oldest first. C<bot_key> (TGT-232) is
optional - omitting it considers every bot's own entries, matching
C<unread_messages>'s own convention.

The comparison wraps both C<created_at> and the bound value in SQLite's
own C<datetime()> function (TGT-214, found via a scheduled hourly bug
hunt, live-verified) - C<created_at> is stored space-separated
(SQLite's C<CURRENT_TIMESTAMP> default, e.g. C<"2026-09-01 08:00:00">)
while C<cli/history.pl>'s own documented/validated C<--since>/C<--until>
form uses a C<'T'> separator (e.g. C<"2026-09-01T00:00:00">); a plain
string comparison previously sorted the C<'T'> form after every
same-day space-separated row (C<'T'> is C<0x54>, a space is C<0x20>),
silently excluding messages from the same calendar day as C<since>
regardless of their actual time. C<datetime()> normalizes any of its
accepted input shapes (bare date, space-separated, C<'T'>-separated) to
one canonical form before comparing, so the result reflects true
chronological order. A date-only C<until> value is normalized to
midnight of that date (C<datetime()>'s own expansion of a bare date) -
it does not include the rest of that same day; this narrower behavior
predates this fix and is unchanged by it, a separate question from the
separator mismatch this fix addresses.

=head2 record_failed_download($chat_id, $message_id, $file_id, sender => $s, media_kind => $k, caption_note => $c, error => $e, bot_key => $b)

Persists a failed inbound photo/document download for later retry
(TGT-104) - C<D2TG::Poller> calls this when C<download_media> dies and a
store is present, instead of only printing the error and forgetting it.
C<bot_key> is optional (TGT-219, found via a scheduled improvement hunt,
matching every sibling per-chat table's own established pattern -
defaults to the single-bot sentinel). Upserts on C<(chat_id, bot_key,
message_id)> - Telegram's own at-least-once delivery can reprocess the
same update under the SAME bot, and a second call for the same triple
refreshes the existing row's C<file_id>/C<sender>/C<media_kind>/
C<caption_note>/C<error>/timestamp rather than inserting a duplicate (a
Codex review finding); the same C<message_id> failing under two
DIFFERENT bots in a multi-bot config now queues two independent rows
instead of colliding into one - Telegram's own C<file_id> values are
bot-token-scoped, so retrying under the wrong bot's token could never
have succeeded anyway. Returns the row's id (new or existing) - the
id-lookup itself is scoped by C<(chat_id, bot_key, message_id)> too
(TGT-225, found via a scheduled JOB-003 hourly bug hunt; previously
scoped only by C<(chat_id, message_id)>, so two rows sharing that pair
under different C<bot_key>s could make it return the wrong row's id).
The
C<UPDATE SET> clause deliberately does not assign C<local_path> (TGT-196)
- a redelivery of the same failed-download event must not clobber a
C<local_path> already persisted by L</mark_failed_download_downloaded>
back to C<NULL>.

=head2 failed_downloads(bot_key => $b)

Returns queued failed downloads (TGT-104), ordered by C<id> (not
C<created_at>, whose second precision isn't a reliable tiebreaker - a
Codex review finding) - each a hashref of C<id>, C<chat_id>,
C<bot_key> (TGT-219), C<message_id>, C<file_id>, C<sender>,
C<media_kind>, C<caption_note>, C<error>, C<created_at>, C<local_path>
(TGT-196, C<undef> until a retry's own C<record_message> fails after a
successful download - see L</mark_failed_download_downloaded>).
C<bot_key> is optional - when given, only that bot's own queued
entries are returned; omitting it lists every bot's, each row naming
its own C<bot_key> (matching L</pending_chat_ids>' own established
optional-C<bot_key>-filter pattern). C<cli/retry-download.pl> lists and
acts on this.

=head2 mark_failed_download_downloaded($id, $local_path)

Persists C<$local_path> onto a queued row (TGT-196), without removing
it from the C<failed_downloads> queue. C<D2TG::Download::retry_failed_download>
calls this when a retry's download succeeds but the following
C<record_message> history write still fails - so the next retry attempt
sees C<local_path> already set and skips C<download_file> entirely,
retrying only the still-failing history write instead of re-downloading
an already-fetched file from Telegram on every pass.

=head2 remove_failed_download($id)

Removes one row from the C<failed_downloads> queue by its own C<id>
(TGT-104) - a harmless no-op if that id doesn't exist. Called by
C<D2TG::Download::retry_failed_download> only after a retry actually
succeeds; a failed retry leaves the row untouched.

=head2 record_sent_text($chat_id, $text_message_id, bot_key => $key, text => $text)

Records that a text reply was sent (TGT-105) - C<D2TG::Reply::send_reply>
calls this immediately after C<send_message> succeeds, before synthesis
or C<send_voice> can fail. C<INSERT OR IGNORE>: a redundant re-record of
the same C<(chat_id, bot_key, text_message_id)> never clobbers a
C<voice_message_id> already recorded for it back to C<NULL>. C<bot_key>
defaults to C<DEFAULT_BOT_KEY> (the single-bot sentinel) when omitted -
a Codex review finding, mirroring TGT-098's own C<allow_list>/C<pending>
scoping, since a Telegram group shared by more than one configured bot
means C<chat_id> alone isn't unique across bots. C<text> (TGT-114) is
the reply's own text, stored so L</is_recent_duplicate_reply> can check
it later.

=head2 record_sent_voice($chat_id, $text_message_id, $voice_message_id, bot_key => $key)

Fills in the C<voice_message_id> for an existing C<sent_replies> row
(TGT-105) - a row whose C<voice_message_id> is still C<NULL> IS the
text-only condition C<text_only_replies> reports, so this is what
clears that flag once the voice half actually succeeds. Called by both
C<D2TG::Reply::send_reply> (the normal path) and C<resend_voice>
(TGT-109's own recovery path, clearing a flag left by an earlier failed
attempt). Warns on STDERR (non-fatal - the voice send itself already
succeeded and must not be treated as a failure) if no matching row
exists for the given C<(chat_id, bot_key, text_message_id)> - a Codex
review finding: this used to be a silent no-op, which could hide the
narrow-window persistence gap documented on C<text_only_replies> below.

=head2 text_only_replies(bot_key => $key)

Returns every reply whose text was sent but whose voice was never
confirmed sent (TGT-105) - each a hashref of C<chat_id>, C<bot_key>,
C<text_message_id>, C<created_at>. Without C<bot_key>, lists every
configured bot's flagged replies (each row naming its own C<bot_key>) -
for a human operator auditing the whole board, via C<cli/text-only-replies.pl>.
With C<bot_key>, scopes to exactly that bot - C<cli/reply.pl>'s
C<--voice-only> uses this so it can never select and clear a
I<different> bot's still-genuinely-text-only flag for a chat_id shared
across bots (a Codex review finding, the same TGT-098 lesson).

B<Known limitation> (accepted, not solved, per a Codex review):
recording the text send and Telegram's own C<sendMessage> succeeding
are two separate, non-atomic steps - a process kill or a database error
in that narrow window leaves a genuinely-sent text message with no row
at all, invisible here if its voice half then also fails. This mirrors
TGT-104's own accepted best-effort tradeoff for its queue write; it is
a substantial improvement over no record at all, not a guarantee.

=head2 is_recent_duplicate_reply($chat_id, $text, bot_key => $key, window_seconds => $n)

Returns true if the exact same C<$text> was already sent to C<$chat_id>
under C<$bot_key> (default C<DEFAULT_BOT_KEY>) within the last
C<window_seconds> (default 10, must be a non-negative number - a
Codex review finding, a negative value would otherwise build a
nonsensical SQLite date modifier) (TGT-114). C<D2TG::Reply::send_reply>
checks this before calling C<send_message> at all, and refuses (dies)
rather than delivering an identical message twice - closing a real gap
where an agent accidentally re-running the same C<d2 tg.reply> command,
or a caller retrying after a synthesis/C<send_voice> failure (the
message TGT-083 already reports loudly), had no way to avoid sending
the same text twice. Scoped by C<bot_key> for the same reason
C<text_only_replies> is: a Telegram group shared by more than one
configured bot must never let one bot's own recent send be mistaken for
a duplicate of a different bot's identical text to the same C<chat_id>.

Known, accepted limitations (Codex review findings):

=over 4

=item * This does not protect against a C<send_message> call whose own
request errors or times out ambiguously - if Telegram actually
delivered the text but the response never reached this process,
C<record_sent_text> never runs, so a subsequent retry sees no recorded
match and sends again. Only a I<confirmed> prior success is ever
checked against; an ambiguous prior failure is a different, unprotected
case, not something this feature claims to solve.

=item * This is a best-effort, sequential check, not an atomic claim -
two truly concurrent C<send_reply> calls for the same text could both
pass the check before either records its own send. Acceptable for this
skill's actual usage pattern (a human-paced CLI tool, one operator
issuing one command at a time), not a guarantee under real concurrency.

=item * C<created_at>/the window comparison are both second-granular
(SQLite's C<CURRENT_TIMESTAMP> and C<datetime()> discard fractional
seconds), so the true elapsed time between a check and the original
send can exceed the stated C<window_seconds> by up to slightly under a
second. Not corrected for, since sub-second precision isn't meaningful
for this feature's actual purpose (catching an operator-paced retry
seconds later, not a strict timing guarantee).

=back

=head2 prune_history(retention_days => $days = 90)

TGT-235: deletes rows older than the retention window from C<messages>
and C<sent_replies> - neither table had any retention/eviction policy
before this, unlike L<D2TG::Download/prune_vault> which already caps
the attachments vault's own disk usage by byte count. Mirrors
C<prune_vault>'s own pattern: a sane hardcoded default
(C<DEFAULT_RETENTION_DAYS>, currently 90), an optional
C<retention_days> override, and a silent no-op when nothing is past
the window. Called from C<cli/poller.pl>'s per-cycle loop right after
the existing C<prune_vault> call, C<eval>-wrapped there so a
locked/busy database can't turn this housekeeping into a poll-cycle
failure - a failed prune simply retries next cycle.

No foreign-key relationship exists between C<messages>/C<sent_replies>
and C<failed_downloads>/C<text_only_replies> (confirmed by reading the
schema, not assumed), so pruning an aged-out C<messages> row cannot
orphan a still-relevant C<failed_downloads> row.

=head2 disconnect

Disconnects the underlying DBI handle (TGT-036). C<cli/poller.pl> calls
this immediately before re-execing itself on a detected version change,
so the SQLite connection is closed cleanly rather than left open across
the C<exec> call.

=cut
