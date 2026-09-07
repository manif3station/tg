use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

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
    for my $i ( 1 .. 15 ) {
        record_at( $store, $i, sprintf( '2026-09-%02dT00:00:00', $i ) );
    }

    my @recent = $store->recent_messages(10);

    is( scalar @recent, 10, 'recent_messages(10) returns exactly 10 rows' );
    is( $recent[0]{message_id}, 15, 'newest message is first' );
    is( $recent[9]{message_id}, 6, 'the 10th row is the 10th-most-recent message' );
}

{
    my $store = new_store();
    for my $i ( 1 .. 5 ) {
        record_at( $store, $i, sprintf( '2026-09-%02dT00:00:00', $i ) );
    }

    my @recent = $store->recent_messages(10);

    is( scalar @recent, 5, 'recent_messages(10) with only 5 stored returns all 5, no crash' );
}

{
    my $store = new_store();
    for my $i ( 1 .. 10 ) {
        record_at( $store, $i, sprintf( '2026-09-%02dT00:00:00', $i ) );
    }

    my @ranged = $store->messages_in_range( since => '2026-09-03T00:00:00', until => '2026-09-06T23:59:59' );

    is( scalar @ranged, 4, 'messages_in_range with since+until returns only messages within that window' );
    my %ids = map { $_->{message_id} => 1 } @ranged;
    ok( $ids{3} && $ids{4} && $ids{5} && $ids{6}, 'exactly messages 3-6 are in range' );
    ok( !$ids{2} && !$ids{7}, 'messages outside the range are excluded' );
}

{
    my $store = new_store();
    for my $i ( 1 .. 5 ) {
        record_at( $store, $i, sprintf( '2026-09-%02dT00:00:00', $i ) );
    }

    my @since_only = $store->messages_in_range( since => '2026-09-03T00:00:00' );
    is( scalar @since_only, 3, 'messages_in_range with only since returns everything from then onward' );

    my @until_only = $store->messages_in_range( until => '2026-09-03T00:00:00' );
    is( scalar @until_only, 3, 'messages_in_range with only until returns everything up to then' );
}

done_testing();
