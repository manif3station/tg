use strict;
use warnings;
use Test::More;
use DBI;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use D2TG::Store::Schema;

# TGT-298 (found via a user-requested comprehensive bug/improvement
# sweep): D2TG::Store::History's unread_messages (WHERE read_at IS
# NULL) and messages_in_range (a created_at range scan) can filter
# across every chat/bot with no bot_key given, and neither
# messages(read_at) nor messages(created_at) has a dedicated index
# beyond the (chat_id, bot_key, message_id) primary key - an unscoped
# unread_messages or a wide --since/--until history query does a full
# table scan. Added 2 additive, idempotent indexes.

# --- fresh database ---
{
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 } );
    D2TG::Store::Schema::ensure_schema($dbh);

    my $indexes = $dbh->selectcol_arrayref(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages'"
    );
    ok( ( grep { $_ eq 'idx_messages_read_at' } @$indexes ), 'idx_messages_read_at exists on a fresh database' );
    ok( ( grep { $_ eq 'idx_messages_created_at' } @$indexes ), 'idx_messages_created_at exists on a fresh database' );
}

# --- idempotent on a second ensure_schema call against the same db ---
{
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 } );
    D2TG::Store::Schema::ensure_schema($dbh);
    D2TG::Store::Schema::ensure_schema($dbh);

    my $indexes = $dbh->selectcol_arrayref(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages'"
    );
    is( scalar( grep { $_ eq 'idx_messages_read_at' } @$indexes ), 1, 'idx_messages_read_at is not duplicated on a second ensure_schema call' );
    is( scalar( grep { $_ eq 'idx_messages_created_at' } @$indexes ), 1, 'idx_messages_created_at is not duplicated on a second ensure_schema call' );
}

# --- pre-existing database (messages table created before this ticket, no bot_key column yet) ---
{
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 } );
    $dbh->do(
        'CREATE TABLE messages (
             chat_id    INTEGER NOT NULL,
             message_id INTEGER NOT NULL,
             sender     TEXT,
             summary    TEXT,
             created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             PRIMARY KEY (chat_id, message_id)
         )'
    );
    D2TG::Store::Schema::ensure_schema($dbh);

    my $indexes = $dbh->selectcol_arrayref(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages'"
    );
    ok( ( grep { $_ eq 'idx_messages_read_at' } @$indexes ), 'idx_messages_read_at is created on an existing pre-bot_key-migration database too' );
    ok( ( grep { $_ eq 'idx_messages_created_at' } @$indexes ), 'idx_messages_created_at is created on an existing pre-bot_key-migration database too' );
}

done_testing();
