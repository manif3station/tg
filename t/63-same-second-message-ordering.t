use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-075: unread_messages and messages_in_range both ORDER BY
# created_at alone - a second-resolution TEXT column with no secondary
# tiebreaker, unlike recent_messages which already adds ", message_id
# DESC". Whenever two or more messages land within the same second,
# SQLite's tie-break order for equal ORDER BY keys is not guaranteed to
# match insertion/chronological order - message_id (a per-bot
# monotonically increasing Telegram counter) is the correct tiebreaker.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

sub record_at {
    my ( $store, $message_id, $created_at ) = @_;
    $store->record_message( 999, $message_id, 'bob', "msg $message_id" );
    $store->{dbh}->do(
        'UPDATE messages SET created_at = ? WHERE chat_id = 999 AND message_id = ?',
        undef, $created_at, $message_id,
    );
    return;
}

{
    my $store = new_store();
    # Insert message_id 30 before message_id 10, but give both the
    # identical created_at timestamp - a realistic same-second burst.
    # Without a message_id tiebreaker, SQLite's tie-break order for two
    # equal ORDER BY keys depends on physical row order (insertion
    # order here: 30 then 10), which would return them in the wrong
    # (non-chronological) sequence.
    record_at( $store, 30, '2026-09-08T00:00:00' );
    record_at( $store, 10, '2026-09-08T00:00:00' );

    my @unread = $store->unread_messages;
    is_deeply(
        [ map { $_->{message_id} } @unread ],
        [ 10, 30 ],
        'unread_messages breaks a same-second tie by message_id ASC, not insertion order'
    );

    my @ranged = $store->messages_in_range( since => '2026-09-08T00:00:00', until => '2026-09-08T00:00:00' );
    is_deeply(
        [ map { $_->{message_id} } @ranged ],
        [ 10, 30 ],
        'messages_in_range breaks a same-second tie by message_id ASC, not insertion order'
    );
}

{
    # Regression: normal, distinct-second ordering is completely
    # unaffected by the tiebreaker.
    my $store = new_store();
    record_at( $store, 1, '2026-09-08T00:00:01' );
    record_at( $store, 2, '2026-09-08T00:00:02' );

    my @unread = $store->unread_messages;
    is_deeply( [ map { $_->{message_id} } @unread ], [ 1, 2 ], 'distinct-second unread_messages ordering unaffected' );

    my @ranged = $store->messages_in_range( since => '2026-09-08T00:00:00' );
    is_deeply( [ map { $_->{message_id} } @ranged ], [ 1, 2 ], 'distinct-second messages_in_range ordering unaffected' );
}

done_testing();
