package D2TG::Store;

use strict;
use warnings;
use DBI;

sub new {
    my ( $class, %args ) = @_;

    my $db_path = $args{db_path} or die "D2TG::Store->new requires db_path\n";

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path", '', '',
        { RaiseError => 1, AutoCommit => 1, sqlite_use_immediate_transaction => 1 }
    );

    my $self = bless { dbh => $dbh }, $class;
    $self->_ensure_schema;
    $self->_seed_admin( $args{admin_chat_id} ) if defined $args{admin_chat_id};

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

sub get_offset {
    my ($self) = @_;

    my ($value) = $self->{dbh}->selectrow_array(
        "SELECT value FROM meta WHERE key = 'offset'"
    );

    return defined $value ? $value : undef;
}

sub set_offset {
    my ( $self, $offset ) = @_;

    $self->{dbh}->do(
        "INSERT INTO meta (key, value) VALUES ('offset', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        undef, $offset,
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

=head2 new(db_path => $path, admin_chat_id => $id)

Opens (creating if needed) the SQLite database at C<db_path>, ensures the
schema exists, and seeds C<admin_chat_id> into the allow-list if given.

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

=head2 get_offset

Returns the persisted Telegram update offset, or C<undef> if none has
been saved yet.

=head2 set_offset($offset)

Persists C<$offset>, overwriting any previously saved value.

=cut
