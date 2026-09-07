package D2TG::Store;

use strict;
use warnings;
use DBI;
use Digest::SHA qw(sha256_hex);

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
        'CREATE TABLE IF NOT EXISTS allow_list (chat_id INTEGER PRIMARY KEY)'
    );
    $self->{dbh}->do(
        'CREATE TABLE IF NOT EXISTS pending (chat_id INTEGER PRIMARY KEY)'
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

    return;
}

sub _seed_admin {
    my ( $self, $admin_chat_id ) = @_;

    $self->{dbh}->do(
        'INSERT OR IGNORE INTO allow_list (chat_id) VALUES (?)',
        undef, $admin_chat_id,
    );

    return;
}

sub is_allowed {
    my ( $self, $chat_id ) = @_;

    my ($found) = $self->{dbh}->selectrow_array(
        'SELECT 1 FROM allow_list WHERE chat_id = ?', undef, $chat_id,
    );

    return $found ? 1 : 0;
}

sub add_pending {
    my ( $self, $chat_id ) = @_;

    my $inserted = $self->{dbh}->do(
        'INSERT OR IGNORE INTO pending (chat_id) VALUES (?)',
        undef, $chat_id,
    );

    return $inserted && $inserted ne '0E0' ? 1 : 0;
}

sub approve {
    my ( $self, $chat_id ) = @_;

    my $dbh = $self->{dbh};

    $dbh->begin_work;

    my $result = eval {
        my $deleted = $dbh->do(
            'DELETE FROM pending WHERE chat_id = ?', undef, $chat_id,
        );

        if ( $deleted == 0 ) {
            $dbh->rollback;
            return 0;
        }

        $dbh->do(
            'INSERT OR IGNORE INTO allow_list (chat_id) VALUES (?)',
            undef, $chat_id,
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
         FROM messages WHERE read_at IS NULL ORDER BY created_at',
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
    $sql .= ' ORDER BY created_at';

    my $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );

    return @$rows;
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

=head2 is_allowed($chat_id)

True if C<$chat_id> is in the allow-list.

=head2 add_pending($chat_id)

Records C<$chat_id> as pending approval. Idempotent. Returns true the
first time a given C<$chat_id> is recorded, false on every subsequent
call for the same id (already pending) - this is what lets a caller
notify only once per new sender.

=head2 approve($chat_id)

Moves C<$chat_id> from C<pending> to C<allow_list>, atomically. Returns
true if it was genuinely pending and is now approved; returns false
(without error) if it was not pending - already approved, or never seen.
If anything inside the transaction throws (a transient DB error), the
transaction is always rolled back before the error is re-thrown, so the
Store's connection is never left in a dangling open-transaction state -
a subsequent C<approve> call on the same object still works normally.

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
summary, created_at }>, ordered oldest first. Empty list if there are
none - never dies on an empty store.

=head2 recent_messages($limit = 10)

Returns the C<$limit> most recently recorded messages (TGT-048), newest
first, as a list of hashrefs C<{ chat_id, message_id, sender, summary,
created_at }>. Returns fewer than C<$limit> (down to none) without
error if the store has fewer rows than that.

=head2 messages_in_range(since => $iso8601, until => $iso8601)

Returns every stored message (TGT-048) with C<created_at> between
C<since> and C<until> inclusive, oldest first. Either bound may be
omitted (an open-ended range on that side); omitting both returns every
stored message, oldest first.

=head2 disconnect

Disconnects the underlying DBI handle (TGT-036). C<cli/poller> calls
this immediately before re-execing itself on a detected version change,
so the SQLite connection is closed cleanly rather than left open across
the C<exec> call.

=cut
