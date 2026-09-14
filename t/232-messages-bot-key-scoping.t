use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;

require D2TG::Store;

# TGT-232 (found via a scheduled JOB-004 improvement hunt): every other
# per-chat D2TG::Store table (allow_list/pending TGT-098,
# pending_chat_ids TGT-215, failed_downloads TGT-219/225) was migrated
# to bot_key-scoping during the multi-bot rollout - the messages table
# was the one gap. Telegram's own message_id is a per-bot counter
# (TGT-063), so two different bots sharing a chat_id can legitimately
# produce colliding (chat_id, message_id) pairs; record_message's own
# unscoped ON CONFLICT(chat_id, message_id) silently overwrote one
# bot's row with another's.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();

    $store->record_message( 111, 55, 'ada', 'hello from bot A', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hello from bot B', bot_key => 'botB' );

    my $row_a = $store->get_message( 111, 55, bot_key => 'botA' );
    my $row_b = $store->get_message( 111, 55, bot_key => 'botB' );

    is( $row_a->{sender}, 'ada', "bot A's own row survives independently, not overwritten by bot B" );
    is( $row_b->{sender}, 'bob', "bot B's own row survives independently, not overwritten by bot A" );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB' );

    is( $store->is_read( 111, 55, bot_key => 'botA' ), 0, 'botA row starts unread' );
    $store->mark_read( 111, 55, bot_key => 'botA' );
    is( $store->is_read( 111, 55, bot_key => 'botA' ), 1, 'marking botA read only affects botA' );
    is( $store->is_read( 111, 55, bot_key => 'botB' ), 0, "botB's own row is unaffected by botA's mark_read" );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB' );

    my @unread_a = $store->unread_messages( bot_key => 'botA' );
    is( scalar @unread_a, 1, 'unread_messages(bot_key=>botA) returns only botA\'s own row' );
    is( $unread_a[0]{sender}, 'ada', 'the correct row is returned' );

    my @unread_all = $store->unread_messages;
    is( scalar @unread_all, 2, 'unread_messages with no bot_key still lists every bot\'s own entries, matching failed_downloads\'s own convention' );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA', local_path => '/tmp/a.jpg' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB', local_path => '/tmp/b.jpg' );

    is( $store->get_attachment_path( 111, 55, bot_key => 'botA' ), '/tmp/a.jpg', "botA's own attachment path is independent" );
    is( $store->get_attachment_path( 111, 55, bot_key => 'botB' ), '/tmp/b.jpg', "botB's own attachment path is independent" );
}

# Regression: single-bot mode (no bot_key ever passed) behaves exactly
# as before - one row per (chat_id, message_id), unscoped listing/
# lookup still works, matching every existing pre-TGT-232 test's usage.
{
    my $store = new_store();
    $store->record_message( 222, 77, 'ada', 'first' );
    $store->record_message( 222, 77, 'ada', 'second' );

    my $row = $store->get_message( 222, 77 );
    is( $row->{summary}, 'second', 're-recording under the default (unscoped) bot_key still upserts the same row as before' );

    is( $store->is_read( 222, 77 ), 0, 'default bot_key is_read still works unscoped' );
    $store->mark_read( 222, 77 );
    is( $store->is_read( 222, 77 ), 1, 'default bot_key mark_read still works unscoped' );

    my @unread = $store->unread_messages;
    is( scalar @unread, 0, 'default bot_key unread_messages still works unscoped' );

    my @recent = $store->recent_messages(5);
    is( scalar @recent, 1, 'default bot_key recent_messages still works unscoped' );

    my @ranged = $store->messages_in_range;
    is( scalar @ranged, 1, 'default bot_key messages_in_range still works unscoped' );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA' );
    $store->record_message( 111, 56, 'ada', 'again', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB' );

    my @recent_a = $store->recent_messages( 10, bot_key => 'botA' );
    is( scalar @recent_a, 2, 'recent_messages(bot_key=>botA) only considers botA\'s own entries' );

    my @recent_all = $store->recent_messages(10);
    is( scalar @recent_all, 3, 'recent_messages with no bot_key still considers every bot\'s own entries' );

    my @ranged_a = $store->messages_in_range( bot_key => 'botA' );
    is( scalar @ranged_a, 2, 'messages_in_range(bot_key=>botA) only considers botA\'s own entries' );

    my @ranged_all = $store->messages_in_range;
    is( scalar @ranged_all, 3, 'messages_in_range with no bot_key still considers every bot\'s own entries' );
}

{
    # The migration is wrapped in a transaction (SQLite DDL is
    # transactional) so a failure mid-migration can never leave the old
    # data orphaned in a renamed-aside table while a fresh, empty
    # new-shape table silently appears on the next run instead of being
    # noticed. Simulated here by making the INSERT (the data-copy step)
    # fail, matching t/75's own established mid-migration-failure
    # regression pattern.
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, AutoCommit => 1 } );
    $dbh->do(
        'CREATE TABLE messages (
             chat_id    INTEGER NOT NULL,
             message_id INTEGER NOT NULL,
             sender     TEXT,
             summary    TEXT,
             created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             read_at    TEXT,
             local_path TEXT,
             PRIMARY KEY (chat_id, message_id)
         )'
    );
    $dbh->do( "INSERT INTO messages (chat_id, message_id, sender, summary) VALUES (999, 1, 'ada', 'pre-existing')" );
    $dbh->disconnect;

    my $real_do = \&DBI::db::do;
    my $error;
    {
        no warnings 'redefine';
        local *DBI::db::do = sub {
            my ( $self, $sql, @rest ) = @_;
            die "simulated failure mid-migration\n"
              if $sql =~ /INSERT INTO messages \(chat_id, bot_key, message_id/;
            return $real_do->( $self, $sql, @rest );
        };

        eval { D2TG::Store->new( db_path => $db ) };
        $error = $@;
    }

    like( $error, qr/simulated failure mid-migration/, 'a mid-migration failure propagates loudly (dies) rather than silently continuing' );

    my $store = D2TG::Store->new( db_path => $db );
    my $row = $store->get_message( 999, 1 );
    is( $row->{summary}, 'pre-existing', 'after the simulated failure, a real re-open still migrates successfully and the original row survives' );
}

done_testing();
