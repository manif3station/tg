package D2TG::Store;

use strict;
use warnings;
use DBI;
use Digest::SHA qw(sha256_hex);

# TGT-101: the single-bot/unscoped sentinel for allow_list/pending's
# bot_key column (TGT-098) - named once here rather than repeated as a
# bare '' literal at every call site.
use constant DEFAULT_BOT_KEY => '';

sub new {
    my ( $class, %args ) = @_;

    my $db_path = $args{db_path} or die "D2TG::Store->new requires db_path\n";

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path", '', '',
        { RaiseError => 1, AutoCommit => 1, sqlite_use_immediate_transaction => 1 }
    );

    my $self = bless { dbh => $dbh }, $class;
    $self->_ensure_schema;

    if ( defined $args{admin_chat_id} ) {
        my @ids = ref $args{admin_chat_id} eq 'ARRAY' ? @{ $args{admin_chat_id} } : ( $args{admin_chat_id} );
        $self->_seed_admin($_) for @ids;
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

    # TGT-104: a failed inbound photo/document download used to be
    # reported once (a MEDIA DOWNLOAD ERROR line) and forgotten - no way
    # to retry it later, even though Telegram's own file_id stays valid
    # for a limited window after the message arrives. This table
    # persists what's needed to retry (which message, which Telegram
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
    my ($self) = @_;

    my $rows = $self->{dbh}->selectcol_arrayref(
        'SELECT chat_id FROM pending ORDER BY chat_id'
    );

    return @$rows;
}

sub record_message {
    my ( $self, $chat_id, $message_id, $sender, $summary ) = @_;

    $self->{dbh}->do(
        'INSERT INTO messages (chat_id, message_id, sender, summary) VALUES (?, ?, ?, ?)
         ON CONFLICT(chat_id, message_id) DO UPDATE SET sender = excluded.sender, summary = excluded.summary',
        undef, $chat_id, $message_id, $sender, $summary,
    );

    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id ) = @_;

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT sender, summary FROM messages WHERE chat_id = ? AND message_id = ?',
        undef, $chat_id, $message_id,
    );

    return $row;
}

sub mark_read {
    my ( $self, $chat_id, $message_id ) = @_;

    $self->{dbh}->do(
        'UPDATE messages SET read_at = CURRENT_TIMESTAMP WHERE chat_id = ? AND message_id = ?',
        undef, $chat_id, $message_id,
    );

    return;
}

sub is_read {
    my ( $self, $chat_id, $message_id ) = @_;

    my ($read_at) = $self->{dbh}->selectrow_array(
        'SELECT read_at FROM messages WHERE chat_id = ? AND message_id = ?',
        undef, $chat_id, $message_id,
    );

    return defined $read_at ? 1 : 0;
}

sub unread_messages {
    my ($self) = @_;

    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT chat_id, message_id, sender, summary, created_at
         FROM messages WHERE read_at IS NULL ORDER BY created_at, message_id',
        { Slice => {} },
    );

    return @$rows;
}

sub recent_messages {
    my ( $self, $limit ) = @_;
    $limit //= 10;

    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT chat_id, message_id, sender, summary, created_at
         FROM messages ORDER BY created_at DESC, message_id DESC LIMIT ?',
        { Slice => {} }, $limit,
    );

    return @$rows;
}

sub messages_in_range {
    my ( $self, %args ) = @_;

    my @where;
    my @bind;

    if ( defined $args{since} ) {
        push @where, 'created_at >= ?';
        push @bind,  $args{since};
    }
    if ( defined $args{until} ) {
        push @where, 'created_at <= ?';
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

    # ON CONFLICT (chat_id, message_id): Telegram's at-least-once
    # delivery can reprocess the same update (e.g. the poller crashes
    # after this call but before its offset advances) - refresh the
    # existing row's file_id/error/timestamp instead of inserting a
    # second queue entry for the same failed media.
    $self->{dbh}->do(
        'INSERT INTO failed_downloads (chat_id, message_id, file_id, sender, media_kind, caption_note, error)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(chat_id, message_id) DO UPDATE SET
             file_id = excluded.file_id, sender = excluded.sender,
             media_kind = excluded.media_kind, caption_note = excluded.caption_note,
             error = excluded.error, created_at = CURRENT_TIMESTAMP',
        undef, $chat_id, $message_id, $file_id, $sender, $media_kind, $caption_note, $error,
    );

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT id FROM failed_downloads WHERE chat_id = ? AND message_id = ?',
        undef, $chat_id, $message_id,
    );

    return $row->{id};
}

sub failed_downloads {
    my ($self) = @_;

    return $self->{dbh}->selectall_arrayref(
        'SELECT id, chat_id, message_id, file_id, sender, media_kind, caption_note, error, created_at
         FROM failed_downloads ORDER BY id',
        { Slice => {} }
    );
}

sub remove_failed_download {
    my ( $self, $id ) = @_;

    $self->{dbh}->do( 'DELETE FROM failed_downloads WHERE id = ?', undef, $id );

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
the arrayref is seeded allowed.

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

=head2 pending_chat_ids

Returns the list of chat ids currently pending, ordered.

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

=head2 record_message($chat_id, $message_id, $sender, $summary)

Records a short summary of a processed message (TGT-038) against its own
C<chat_id>+C<message_id> - the message's own text for a text message, its
transcript for voice, or C<"<kind> <local_path>"> for an already-
downloaded photo/document. Idempotent: recording the same C<chat_id>+
C<message_id> again overwrites the previous C<sender>/C<summary>.

=head2 get_message($chat_id, $message_id)

Returns C<{ sender => ..., summary => ... }> for a previously recorded
message, or C<undef> if nothing was ever recorded for that
C<chat_id>+C<message_id>.

=head2 mark_read($chat_id, $message_id)

Marks a previously recorded message read (TGT-046, stamps a
C<read_at> timestamp). A no-op (no error) if no row exists yet for that
C<chat_id>+C<message_id> - it simply updates zero rows.

=head2 is_read($chat_id, $message_id)

Returns true if C<mark_read> has been called for that C<chat_id>+
C<message_id>, false otherwise - including when no row was ever
recorded for it at all (never dies on an unknown message).

=head2 unread_messages

Returns the list of all stored messages (TGT-047) not yet marked read
(C<mark_read>), as a list of hashrefs C<{ chat_id, message_id, sender,
summary, created_at }>, ordered oldest first - ties on C<created_at>
(two or more messages landing within the same second) are broken by
C<message_id> ascending (TGT-075, same reasoning C<recent_messages>
already applies in the opposite direction), so a same-second burst
never returns in SQLite's undefined tie-break order. Empty list if
there are none - never dies on an empty store.

=head2 recent_messages($limit = 10)

Returns the C<$limit> most recently recorded messages (TGT-048), newest
first, as a list of hashrefs C<{ chat_id, message_id, sender, summary,
created_at }>. Returns fewer than C<$limit> (down to none) without
error if the store has fewer rows than that.

=head2 messages_in_range(since => $iso8601, until => $iso8601)

Returns every stored message (TGT-048) with C<created_at> between
C<since> and C<until> inclusive, oldest first - same C<message_id>
same-second tiebreaker as L</unread_messages> (TGT-075). Either bound
may be omitted (an open-ended range on that side); omitting both
returns every stored message, oldest first.

=head2 record_failed_download($chat_id, $message_id, $file_id, sender => $s, media_kind => $k, caption_note => $c, error => $e)

Persists a failed inbound photo/document download for later retry
(TGT-104) - C<D2TG::Poller> calls this when C<download_media> dies and a
store is present, instead of only printing the error and forgetting it.
Upserts on C<(chat_id, message_id)> - Telegram's own at-least-once
delivery can reprocess the same update, and a second call for the same
pair refreshes the existing row's C<file_id>/C<sender>/C<media_kind>/
C<caption_note>/C<error>/timestamp rather than inserting a duplicate (a
Codex review finding). Returns the row's id (new or existing).

=head2 failed_downloads

Returns every queued failed download (TGT-104), ordered by C<id> (not
C<created_at>, whose second precision isn't a reliable tiebreaker - a
Codex review finding) - each a hashref of C<id>, C<chat_id>,
C<message_id>, C<file_id>, C<sender>, C<media_kind>, C<caption_note>,
C<error>, C<created_at>. C<cli/retry-download.pl> lists and acts on
this.

=head2 remove_failed_download($id)

Removes one row from the C<failed_downloads> queue by its own C<id>
(TGT-104) - a harmless no-op if that id doesn't exist. Called by
C<D2TG::Download::retry_failed_download> only after a retry actually
succeeds; a failed retry leaves the row untouched.

=head2 disconnect

Disconnects the underlying DBI handle (TGT-036). C<cli/poller.pl> calls
this immediately before re-execing itself on a detected version change,
so the SQLite connection is closed cleanly rather than left open across
the C<exec> call.

=cut
